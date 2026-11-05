function Invoke-HuduArticleLinkReplacement {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Articles,

        [AllowNull()]
        $ImageMap,

        [AllowNull()]
        [hashtable]$AttachmentUrlLookup,

        [ValidateRange(1, 32)]
        [int]$ThrottleLimit = [math]::Max(1, [math]::Min(8, [Environment]::ProcessorCount))
    )

    if ($Articles.Count -eq 0) { return }
    $ThrottleLimit = [math]::Min($ThrottleLimit, $Articles.Count)

    # Snapshot only the strings used by the resolver, never the full migration
    # objects/HTML. All workers share these maps for reads; regex caches and
    # replacement reports belong to each runspace/article respectively.
    $urlLookup = @{}
    $migrationLookup = Initialize-HuduURLReplacementLookup
    foreach ($entityType in $migrationLookup.Keys) {
        $records = @{}
        foreach ($key in $migrationLookup[$entityType].Keys) {
            $record = $migrationLookup[$entityType][$key]
            $records[$key] = @{ Url = [string]$record.Url; Name = [string]$record.Name }
        }
        $urlLookup[$entityType] = $records
    }
    $attachmentLookup = @{}
    if ($AttachmentUrlLookup) {
        foreach ($key in $AttachmentUrlLookup.Keys) {
            $record = $AttachmentUrlLookup[$key]
            $attachmentLookup[$key] = @{
                OriginalUrl = [string]$record.OriginalUrl
                ReplacementUrl = [string]$record.ReplacementUrl
            }
        }
    }
    $context = @{
        ProjectRoot = Split-Path $PSScriptRoot -Parent
        ITGURL = $ITGURL
        HuduBaseDomain = $HuduBaseDomain
        SettingsBaseDomain = $settings.HuduBaseDomain
        EnvironmentBaseDomain = $environmentSettings.HuduBaseDomain
        BaseURL = Get-HuduBaseURL
        UrlLookup = $urlLookup
        ImageMapByLeaf = Get-HardcodedImageMapByLeaf -ImageMap $ImageMap
        AttachmentLookup = $attachmentLookup
    }

    $worker = {
        param([string]$ContentPath, [string]$ArticleName, $Context)
        $ErrorActionPreference = 'Stop'
        try {
            if (-not $script:ArticleLinkReplacementInitialized) {
                $ITGURL = $Context.ITGURL
                $HuduBaseDomain = $Context.HuduBaseDomain
                $settings = @{ HuduBaseDomain = $Context.SettingsBaseDomain }
                $environmentSettings = @{ HuduBaseDomain = $Context.EnvironmentBaseDomain }
                . (Join-Path $Context.ProjectRoot 'Private/ConvertTo-HuduURL.ps1')
                . (Join-Path $Context.ProjectRoot 'Public/ReplaceAttachmentLinks.ps1')
                . (Join-Path $Context.ProjectRoot 'Public/Set-HuduImageAnchorsReplaced.ps1')
                . (Join-Path $Context.ProjectRoot 'Public/ArticleContentLocalCache.ps1')
                $script:HuduURLReplacementLookup = $Context.UrlLookup
                $script:ArticleLinkReplacementBaseURL = $Context.BaseURL
                function Get-HuduBaseURL { $script:ArticleLinkReplacementBaseURL }
                $script:ArticleLinkReplacementInitialized = $true
            }

            $content = Get-HuduArticleLocalContent -Article @{ LocalContentPath = $ContentPath }
            if ($null -eq $content) {
                throw "Local article HTML was not found for '$ArticleName' at '$ContentPath'. Refusing to use Hudu-returned content as a fallback."
            }
            $updated = Update-HuduContentLinks -Content $content -Type 'rich' `
                -ImageMapByLeaf $Context.ImageMapByLeaf -AttachmentUrlLookup $Context.AttachmentLookup `
                -IncludeHardcodedImages -IncludeAttachments -IncludeHostedImageAnchors -IncludeUploads
            [pscustomobject]@{ UpdatedContent = $updated; Error = $null }
        } catch {
            [pscustomobject]@{ UpdatedContent = $null; Error = $_.Exception.Message }
        }
    }

    function Receive-ArticleLinkReplacement {
        param($Pending)
        try {
            $output = $Pending.PowerShell.EndInvoke($Pending.Handle)
            if ($output.Count -ne 1) { throw 'The article replacement worker did not return exactly one result.' }
            [pscustomobject]@{
                Index = $Pending.Index
                UpdatedContent = $output[0].UpdatedContent
                Error = $output[0].Error
            }
        } finally {
            $Pending.PowerShell.Dispose()
        }
    }

    Write-Host "Replacing links in $($Articles.Count) article(s) with $ThrottleLimit worker(s) and shared URL/image lookups." -ForegroundColor Cyan
    $pool = [runspacefactory]::CreateRunspacePool(1, $ThrottleLimit)
    $pending = [System.Collections.Generic.Queue[object]]::new()
    try {
        $pool.Open()
        for ($index = 0; $index -lt $Articles.Count; $index++) {
            # Backpressure: at most ThrottleLimit articles can be running or
            # buffered. Drain in source order so serial media/API work retains
            # its order, and never collect every article's HTML before yielding.
            if ($pending.Count -ge $ThrottleLimit) {
                Receive-ArticleLinkReplacement -Pending $pending.Dequeue()
            }
            $powershell = [powershell]::Create()
            try {
                $powershell.RunspacePool = $pool
                $null = $powershell.AddScript($worker.ToString()).AddArgument([string]$Articles[$index].LocalContentPath).AddArgument([string]$Articles[$index].name).AddArgument($context)
                $handle = $powershell.BeginInvoke()
                $pending.Enqueue(@{ Index = $index; PowerShell = $powershell; Handle = $handle })
            } catch {
                $powershell.Dispose()
                throw
            }
        }
        while ($pending.Count -gt 0) {
            Receive-ArticleLinkReplacement -Pending $pending.Dequeue()
        }
    } finally {
        # Also runs when the downstream staging pipeline fails or is stopped.
        while ($pending.Count -gt 0) {
            $item = $pending.Dequeue()
            try { $item.PowerShell.Stop() } finally { $item.PowerShell.Dispose() }
        }
        $pool.Dispose()
    }
}
