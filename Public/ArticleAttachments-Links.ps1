function Set-ProcessArticleAttachment {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        $Html,

        [Parameter(Mandatory)]
        [string[]]$Attachments,

        [Parameter(Mandatory)]
        [string]$ITGURL,

        [Parameter(Mandatory)]
        [int]$UploadableId,
        [Parameter(Mandatory)]
        [ValidateSet('Article','Asset','Company','Procedure')]
        [string]$UploadableType
    )

    $errors = New-Object System.Collections.Generic.List[object]
    $rewritten = 0

    # Collect anchors
    $anchors = @($Html.Links)
    if (-not $anchors -or $anchors.Count -eq 0) {
        return [pscustomobject]@{
            Success        = $true
            RewrittenCount = 0
            Html           = $Html.documentElement.outerHTML
            Errors         = @()
        }
    }

    # Flatten files under all provided attachment dirs
    $articleFiles = foreach ($dir in $Attachments) {
        if (Test-Path $dir) {
            Get-ChildItem -Path $dir -File -Recurse -ErrorAction SilentlyContinue
        }
    }

    # Quick lookup by lowercase filename
    $byName = @{}
    foreach ($f in $articleFiles) { $byName[$f.Name.ToLower()] = $f.FullName }

    # Helper: URL-decode filename safely
    function _TryUrlDecode([string]$s) {
        if ([string]::IsNullOrWhiteSpace($s)) { return $s }
        try {
            Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue | Out-Null
            if ([type]::GetType('System.Web.HttpUtility')) {
                return [System.Web.HttpUtility]::UrlDecode($s)
            }
        } catch {}
        return $s
    }

    foreach ($a in $anchors) {
        $href = "$($a.href)"
        if ([string]::IsNullOrWhiteSpace($href)) { continue }

        $isRelative = ($href -notmatch '^https?://')
        $isITG      = ($href -match [regex]::Escape($ITGURL))
        if (-not ($isRelative -or $isITG)) { continue }

        # Get filename (strip ?query and #fragment)
        $rawFileName = [System.IO.Path]::GetFileName($href.Split('?')[0].Split('#')[0])
        if ([string]::IsNullOrWhiteSpace($rawFileName)) { continue }

        # Resolve local path
        $localPath = $null
        $key = $rawFileName.ToLower()
        if ($byName.ContainsKey($key)) {
            $localPath = $byName[$key]
        } else {
            $decoded = _TryUrlDecode $rawFileName
            if ($decoded) {
                $decKey = $decoded.ToLower()
                if ($byName.ContainsKey($decKey)) {
                    $localPath = $byName[$decKey]
                } else {
                    # Fallback: startswith match
                    $localPath = $articleFiles | Where-Object {
                        $_.Name.ToLower().StartsWith($decKey)
                    } | Select-Object -First 1 -ExpandProperty FullName
                }
            }
        }

        if (-not $localPath) { continue }

        try {
            $upload = New-HuduUpload -FilePath $localPath -uploadable_id $UploadableId -uploadable_type $UploadableType
            $newUrl = $upload.url
            if ([string]::IsNullOrWhiteSpace($newUrl)) {
                $errors.Add([pscustomobject]@{Href=$href; File=$localPath; Error='Upload returned no URL'; Raw=$upload})
                continue
            }

            $null = $a.setAttribute('href', $newUrl)
            $null = $a.setAttribute('target', '_blank')
            if ([string]::IsNullOrWhiteSpace("$($a.innerText)")) {
                $a.innerText = [System.IO.Path]::GetFileName($localPath)
            }
            $rewritten++
        }
        catch {
            $errors.Add([pscustomobject]@{Href=$href; File=$localPath; Error=$_.Exception.Message})
            continue
        }
    }

    [pscustomobject]@{
        Success        = ($errors.Count -eq 0)
        RewrittenCount = $rewritten
        Html           = $Html.documentElement.outerHTML
        Errors         = $errors
    }
}
