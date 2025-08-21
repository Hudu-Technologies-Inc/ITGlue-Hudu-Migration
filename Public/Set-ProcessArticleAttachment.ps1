function Set-ProcessArticleAttachment {
    [CmdletBinding()]
    param (
        # COM HTMLFile document object (mutated in place)
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
        [string]$UploadableType,

        [switch]$UploadUnlinked
    )

    $errors      = New-Object System.Collections.Generic.List[object]
    $rewritten   = 0
    $linkedMeta  = New-Object System.Collections.Generic.List[object]   # files uploaded for anchors
    $unlinkedMeta= New-Object System.Collections.Generic.List[object]   # files uploaded without anchors

    # Collect anchors
    $anchors = @($Html.Links)

    # Flatten files under all provided attachment dirs
    $articleFiles = foreach ($dir in $Attachments) {
        if (Test-Path $dir) {
            Get-ChildItem -Path $dir -File -Recurse -ErrorAction SilentlyContinue
        }
    }

    # Quick lookup by lowercase filename
    $byName = @{}
    foreach ($f in $articleFiles) { $byName[$f.Name.ToLower()] = $f.FullName }

    # Track which local files were handled via anchors (case-insensitive)
    $linkedLocalPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

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
                    # Fallback: startswith match (helps with cache suffixes or minor variations)
                    $cand = $articleFiles | Where-Object { $_.Name.ToLower().StartsWith($decKey) } | Select-Object -First 1
                    if ($cand) { $localPath = $cand.FullName }
                }
            }
        }

        if (-not $localPath) { continue }

        try {
            $upload = New-HuduUpload -FilePath $localPath -uploadable_id $UploadableId -uploadable_type $UploadableType
            $newUrl = $upload.url
            if ([string]::IsNullOrWhiteSpace($newUrl)) {
                $errors.Add([pscustomobject]@{Kind='Linked'; Href=$href; File=$localPath; Error='Upload returned no URL'; Raw=$upload})
                continue
            }

            # Rewrite DOM
            $null = $a.setAttribute('href', $newUrl)
            $null = $a.setAttribute('target', '_blank')
            if ([string]::IsNullOrWhiteSpace("$($a.innerText)")) {
                $a.innerText = [System.IO.Path]::GetFileName($localPath)
            }

            $rewritten++
            $linkedLocalPaths.Add($localPath) | Out-Null
            $linkedMeta.Add([pscustomobject]@{
                LocalPath = $localPath
                FileName  = [IO.Path]::GetFileName($localPath)
                Url       = $newUrl
                Raw       = $upload
            })
        }
        catch {
            $errors.Add([pscustomobject]@{Kind='Linked'; Href=$href; File=$localPath; Error=$_.Exception.Message})
            continue
        }
    }

    # Upload any remaining files that weren't referenced by anchors
    if ($UploadUnlinked -and $articleFiles) {
        foreach ($f in $articleFiles) {
            if ($linkedLocalPaths.Contains($f.FullName)) { continue }
            try {
                $upload = New-HuduUpload -FilePath $f.FullName -uploadable_id $UploadableId -uploadable_type $UploadableType
                if (-not $upload -or [string]::IsNullOrWhiteSpace($upload.url)) {
                    $errors.Add([pscustomobject]@{Kind='Unlinked'; File=$f.FullName; Error='Upload returned no URL'; Raw=$upload})
                    continue
                }
                $unlinkedMeta.Add([pscustomobject]@{
                    LocalPath = $f.FullName
                    FileName  = $f.Name
                    Url       = $upload.url
                    Raw       = $upload
                })
            } catch {
                $errors.Add([pscustomobject]@{Kind='Unlinked'; File=$f.FullName; Error=$_.Exception.Message})
            }
        }
    }

    [pscustomobject]@{
        Success            = ($errors.Count -eq 0)
        LinkedRewritten    = $rewritten
        LinkedUploads      = $linkedMeta          # {LocalPath, FileName, Url, Raw}
        UnlinkedUploads    = $unlinkedMeta        # {LocalPath, FileName, Url, Raw}
        Html               = $Html.documentElement.outerHTML  # DOM already mutated
        Errors             = $errors
    }
}