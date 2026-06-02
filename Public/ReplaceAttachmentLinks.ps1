function ConvertTo-AttachmentUrlHashtable {
param(
    $MapObject
)
    if ($MapObject -is [hashtable]) { return $MapObject }

    $Hashtable = @{}

    if ($MapObject -is [System.Collections.IDictionary]) {
        foreach ($Key in $MapObject.Keys) {
            $Hashtable[[string]$Key] = [string]$MapObject[$Key]
        }
        return $Hashtable
    }

    foreach ($Property in $MapObject.PSObject.Properties) {
        if ($Property.MemberType -in 'NoteProperty','Property') {
            $Hashtable[[string]$Property.Name] = [string]$Property.Value
        }
    }

    return $Hashtable
}

function Get-AttachmentUrlMap {
param(
    [string]$MapPath = "$MigrationLogs\AttachmentUrlMap.json"
)
    if ($AttachmentUrlMap -and $AttachmentUrlMap.Count -gt 0) {
        return ConvertTo-AttachmentUrlHashtable -MapObject $AttachmentUrlMap
    }

    if (-not (Test-Path $MapPath)) {
        throw "Attachment URL map was not found at '$MapPath'. Run Add-HuduAttachmentsViaAPI.ps1 first."
    }

    $MapObject = Get-Content -Path $MapPath -Raw | ConvertFrom-Json -Depth 100
    return ConvertTo-AttachmentUrlHashtable -MapObject $MapObject
}

function Update-ContentWithAttachmentUrlMap {
param(
    [AllowEmptyString()]
    [string]$Content,
    [hashtable]$UrlMap
)
    $NewContent = $Content
    $Replacements = @()

    foreach ($OriginalUrl in @($UrlMap.Keys | Sort-Object Length -Descending)) {
        if ([string]::IsNullOrWhiteSpace($OriginalUrl) -or [string]::IsNullOrWhiteSpace($UrlMap[$OriginalUrl])) { continue }

        $Candidates = @($OriginalUrl)
        $HtmlEncodedOriginalUrl = [System.Net.WebUtility]::HtmlEncode($OriginalUrl)
        if ($HtmlEncodedOriginalUrl -and $HtmlEncodedOriginalUrl -ne $OriginalUrl) {
            $Candidates += $HtmlEncodedOriginalUrl
        }

        foreach ($CandidateUrl in $Candidates | Select-Object -Unique) {
            $Count = [regex]::Matches($NewContent, [regex]::Escape($CandidateUrl)).Count
            if ($Count -lt 1) { continue }

            $ReplacementUrl = if ($CandidateUrl -eq $HtmlEncodedOriginalUrl) {
                [System.Net.WebUtility]::HtmlEncode($UrlMap[$OriginalUrl])
            } else {
                $UrlMap[$OriginalUrl]
            }

            $NewContent = $NewContent.Replace($CandidateUrl, $ReplacementUrl)
            $Replacements += [pscustomobject]@{
                OriginalUrl    = $OriginalUrl
                MatchedUrl     = $CandidateUrl
                ReplacementUrl = $ReplacementUrl
                Count          = $Count
            }
        }
    }

    [pscustomobject]@{
        Content      = $NewContent
        Changed      = ($NewContent -ne $Content)
        Replacements = $Replacements
    }
}

function Start-HuduAttachmentLinkReplacement {
[CmdletBinding(SupportsShouldProcess)]
param(
    [object[]]$Articles,
    [hashtable]$UrlMap,
    [string]$MapPath = "$MigrationLogs\AttachmentUrlMap.json",
    [string]$OutputPath = "$MigrationLogs\ReplacedAttachmentLinks.json"
)
    if (-not $UrlMap) {
        $UrlMap = Get-AttachmentUrlMap -MapPath $MapPath
    }

    if (-not $UrlMap -or $UrlMap.Count -lt 1) {
        Write-Warning "Attachment URL map is empty. No articles were updated."
        return @()
    }

    if (-not $Articles) {
        $Articles = @(Get-HuduArticles)
    }

    $Results = foreach ($Article in $Articles) {
        if ([string]::IsNullOrEmpty($Article.content)) {
            [pscustomobject]@{
                Status       = 'skipped'
                ArticleId    = $Article.id
                ArticleName  = $Article.name
                Reason       = 'empty content'
                Replacements = @()
            }
            continue
        }

        $Updated = Update-ContentWithAttachmentUrlMap -Content $Article.content -UrlMap $UrlMap
        if (-not $Updated.Changed) {
            [pscustomobject]@{
                Status       = 'clean'
                ArticleId    = $Article.id
                ArticleName  = $Article.name
                Reason       = 'no attachment URLs found'
                Replacements = @()
            }
            continue
        }

        Write-Host "Replacing $($Updated.Replacements.Count) attachment URL set(s) in article '$($Article.name)'" -ForegroundColor Green

        try {
            $UpdatedArticle = $null
            if ($PSCmdlet.ShouldProcess("Article $($Article.id) '$($Article.name)'", "replace attachment links")) {
                $SetArticleSplat = @{
                    Id      = $Article.id
                    Content = $Updated.Content
                }
                if ($Article.name) { $SetArticleSplat.Name = $Article.name }
                if ($Article.company_id) { $SetArticleSplat.CompanyId = $Article.company_id }

                $UpdatedArticle = Set-HuduArticle @SetArticleSplat -ErrorAction Stop
            }

            [pscustomobject]@{
                Status       = if ($WhatIfPreference) { 'whatif' } else { 'replaced' }
                ArticleId    = $Article.id
                ArticleName  = $Article.name
                Replacements = $Updated.Replacements
                UpdatedArticle = $UpdatedArticle
            }
        }
        catch {
            [pscustomobject]@{
                Status       = 'failed'
                ArticleId    = $Article.id
                ArticleName  = $Article.name
                Error        = $_.Exception.Message
                Replacements = $Updated.Replacements
            }
        }
    }

    $Results | ConvertTo-Json -Depth 100 | Out-File $OutputPath -WhatIf:$false
    return $Results
}
