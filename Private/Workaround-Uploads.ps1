if (-not $script:HuduUploadImageSourceWorkaroundLookup) {
    $script:HuduUploadImageSourceWorkaroundLookup = $null
}
if (-not $script:HuduUploadImageSourceWorkaroundDownloadCache) {
    $script:HuduUploadImageSourceWorkaroundDownloadCache = @{}
}
if (-not $script:HuduUploadImageSourceWorkaroundPhotoCache) {
    $script:HuduUploadImageSourceWorkaroundPhotoCache = @{}
}
if (-not $script:HuduUploadImageSourceWorkaroundVersionChecked) {
    $script:HuduUploadImageSourceWorkaroundVersionChecked = $false
}

function Test-HuduUploadImageSourceWorkaroundVersion {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [version]$Version,

        [switch]$Force
    )

    if ($Force) {
        return $true
    }

    if (-not $Version) {
        foreach ($candidate in @($CurrentVersion, $script:CurrentVersion)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$candidate)) {
                try {
                    $Version = [version]$candidate
                    break
                } catch {}
            }
        }
    }

    if (-not $Version -and -not $script:HuduUploadImageSourceWorkaroundVersionChecked) {
        try {
            $Version = [version]$(Get-HuduAppInfo).version
            $script:HuduUploadImageSourceWorkaroundVersion = $Version
        } catch {
            Write-Verbose "Unable to detect Hudu version for upload image source workaround: $($_.Exception.Message)"
        } finally {
            $script:HuduUploadImageSourceWorkaroundVersionChecked = $true
        }
    }

    if (-not $Version) {
        $Version = $script:HuduUploadImageSourceWorkaroundVersion
    }

    return ($Version -ge [version]'2.44.1' -and $Version -le [version]'2.44.3')
}

function Test-HuduUploadImageSourceWorkaroundCandidate {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$Content,

        [switch]$Force
    )

    if ([string]::IsNullOrWhiteSpace($Content)) {
        return $false
    }

    if (-not (Test-HuduUploadImageSourceWorkaroundVersion -Force:$Force)) {
        return $false
    }

    return $Content -imatch '<img\b[^>]*\bsrc\s*=\s*["''](?:[^"'']*/)?(?:file|uploads?)/[^"'']+["'']'
}

function Get-HuduUploadImageSourceWorkaroundObject {
    param(
        [AllowNull()]
        $Upload
    )

    if ($null -eq $Upload) {
        return $null
    }

    if ($null -ne $Upload.PSObject.Properties['upload']) {
        return $Upload.upload
    }

    return $Upload
}

function Get-HuduUploadImageSourceWorkaroundList {
    param(
        [AllowNull()]
        $Uploads
    )

    if ($null -eq $Uploads) {
        return @()
    }

    if ($null -ne $Uploads.PSObject.Properties['uploads']) {
        return @($Uploads.uploads)
    }

    if ($null -ne $Uploads.PSObject.Properties['upload']) {
        return @($Uploads.upload)
    }

    return @($Uploads)
}

function Get-HuduUploadImageSourceWorkaroundBaseUrl {
    foreach ($candidate in @($HuduBaseDomain, $settings.HuduBaseDomain, $environmentSettings.HuduBaseDomain)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$candidate)) {
            return ([string]$candidate).Trim().TrimEnd('/')
        }
    }

    if (Get-Command -Name Get-HuduBaseURL -ErrorAction SilentlyContinue) {
        try {
            return ([string](Get-HuduBaseURL)).Trim().TrimEnd('/')
        } catch {}
    }

    return $null
}

function Get-HuduUploadImageSourceWorkaroundKeys {
    param(
        [AllowNull()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return @()
    }

    $decoded = [System.Net.WebUtility]::HtmlDecode(([string]$Value).Trim())
    if ([string]::IsNullOrWhiteSpace($decoded)) {
        return @()
    }

    $keys = [System.Collections.ArrayList]@()
    $addKey = {
        param([AllowNull()][string]$Key)

        if ([string]::IsNullOrWhiteSpace($Key)) {
            return
        }

        $clean = ([string]$Key).Trim()
        $clean = $clean -replace '[?#].*$', ''
        $clean = $clean.Trim()
        if ([string]::IsNullOrWhiteSpace($clean)) {
            return
        }

        $clean = $clean.TrimStart('/').ToLowerInvariant()
        if (-not [string]::IsNullOrWhiteSpace($clean)) {
            $null = $keys.Add($clean)
        }
    }

    & $addKey $decoded

    $baseUrl = Get-HuduUploadImageSourceWorkaroundBaseUrl
    if (-not [string]::IsNullOrWhiteSpace($baseUrl)) {
        $withoutBase = [regex]::Replace(
            $decoded,
            "(?i)^$([regex]::Escape($baseUrl))(?=/|$)",
            ''
        )
        & $addKey $withoutBase
    }

    if ($decoded -match '^https?://') {
        try {
            $uri = [uri]$decoded
            & $addKey $uri.AbsolutePath
        } catch {}
    }

    $routeMatch = [regex]::Match(
        $decoded,
        '(?i)(?:^|/)(?<Route>file|uploads?)/(?<Resource>[^"''\s<>?#]+(?:/[^"''\s<>?#]+)*)'
    )
    if ($routeMatch.Success) {
        $route = $routeMatch.Groups['Route'].Value.ToLowerInvariant()
        $resource = $routeMatch.Groups['Resource'].Value
        & $addKey "$route/$resource"
        & $addKey $resource
    }

    return @($keys | Select-Object -Unique)
}

function Add-HuduUploadImageSourceWorkaroundLookupKey {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Lookup,

        [AllowNull()]
        [string]$Key,

        [AllowNull()]
        $Upload
    )

    $uploadObject = Get-HuduUploadImageSourceWorkaroundObject -Upload $Upload
    if (-not $uploadObject) {
        return
    }

    foreach ($normalizedKey in @(Get-HuduUploadImageSourceWorkaroundKeys -Value $Key)) {
        if (-not $Lookup.ContainsKey($normalizedKey)) {
            $Lookup[$normalizedKey] = $uploadObject
        }
    }
}

function Get-HuduUploadImageSourceWorkaroundFileData {
    param(
        [AllowNull()]
        $Upload
    )

    $uploadObject = Get-HuduUploadImageSourceWorkaroundObject -Upload $Upload
    if (-not $uploadObject -or $null -eq $uploadObject.PSObject.Properties['file_data']) {
        return $null
    }

    $fileData = $uploadObject.file_data
    if ($fileData -is [string]) {
        try {
            return $fileData | ConvertFrom-Json -Depth 100
        } catch {
            return $null
        }
    }

    return $fileData
}

function Add-HuduUploadImageSourceWorkaroundLookupEntry {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Lookup,

        [AllowNull()]
        $Upload
    )

    $uploadObject = Get-HuduUploadImageSourceWorkaroundObject -Upload $Upload
    if (-not $uploadObject) {
        return
    }

    foreach ($propertyName in @('id', 'slug', 'url', 'file_url', 'download_url', 'public_url', 'cdn_url', 'name')) {
        if ($null -ne $uploadObject.PSObject.Properties[$propertyName]) {
            $value = [string]$uploadObject.$propertyName
            Add-HuduUploadImageSourceWorkaroundLookupKey -Lookup $Lookup -Key $value -Upload $uploadObject
            if ($propertyName -eq 'id') {
                Add-HuduUploadImageSourceWorkaroundLookupKey -Lookup $Lookup -Key "uploads/$value" -Upload $uploadObject
            } elseif ($propertyName -eq 'slug') {
                Add-HuduUploadImageSourceWorkaroundLookupKey -Lookup $Lookup -Key "file/$value" -Upload $uploadObject
            }
        }
    }

    $fileData = Get-HuduUploadImageSourceWorkaroundFileData -Upload $uploadObject
    foreach ($value in @($fileData.id, $fileData.metadata.filename, $fileData.metadata.original_filename)) {
        if ([string]::IsNullOrWhiteSpace([string]$value)) {
            continue
        }

        Add-HuduUploadImageSourceWorkaroundLookupKey -Lookup $Lookup -Key ([string]$value) -Upload $uploadObject
        Add-HuduUploadImageSourceWorkaroundLookupKey -Lookup $Lookup -Key "file/$value" -Upload $uploadObject
    }
}

function Initialize-HuduUploadImageSourceWorkaroundLookup {
    [CmdletBinding()]
    param(
        [switch]$Force
    )

    if ($script:HuduUploadImageSourceWorkaroundLookup -and -not $Force) {
        return $script:HuduUploadImageSourceWorkaroundLookup
    }

    $lookup = @{}
    try {
        foreach ($upload in @(Get-HuduUploadImageSourceWorkaroundList -Uploads (Get-HuduUploads))) {
            Add-HuduUploadImageSourceWorkaroundLookupEntry -Lookup $lookup -Upload $upload
        }
    } catch {
        Write-Warning "Unable to load Hudu uploads for image source workaround: $($_.Exception.Message)"
    }

    $script:HuduUploadImageSourceWorkaroundLookup = $lookup
    return $script:HuduUploadImageSourceWorkaroundLookup
}

function Resolve-HuduUploadImageSourceWorkaroundUpload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SourceUrl,

        [AllowNull()]
        [hashtable]$Lookup
    )

    if (-not $Lookup) {
        $Lookup = Initialize-HuduUploadImageSourceWorkaroundLookup
    }

    foreach ($key in @(Get-HuduUploadImageSourceWorkaroundKeys -Value $SourceUrl)) {
        if ($Lookup.ContainsKey($key)) {
            return $Lookup[$key]
        }
    }

    $routeMatch = [regex]::Match($SourceUrl, '(?i)(?:^|/)uploads?/(?<Id>\d{1,20})(?=$|[/?#])')
    if ($routeMatch.Success) {
        try {
            $upload = Get-HuduUploads -Id ([int]$routeMatch.Groups['Id'].Value) -ErrorAction Stop
            return Get-HuduUploadImageSourceWorkaroundObject -Upload $upload
        } catch {
            Write-Warning "Unable to resolve Hudu upload $($routeMatch.Groups['Id'].Value): $($_.Exception.Message)"
        }
    }

    return $null
}

function Get-HuduUploadImageSourceWorkaroundDownload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Upload,

        [Parameter(Mandatory)]
        [string]$OutDir
    )

    $uploadObject = Get-HuduUploadImageSourceWorkaroundObject -Upload $Upload
    if (-not $uploadObject -or [string]::IsNullOrWhiteSpace([string]$uploadObject.id)) {
        return $null
    }

    $cacheKey = [string]$uploadObject.id
    if ($script:HuduUploadImageSourceWorkaroundDownloadCache.ContainsKey($cacheKey)) {
        return $script:HuduUploadImageSourceWorkaroundDownloadCache[$cacheKey]
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$uploadObject.localPath) -and (Test-Path -LiteralPath $uploadObject.localPath)) {
        $script:HuduUploadImageSourceWorkaroundDownloadCache[$cacheKey] = [string]$uploadObject.localPath
        return $script:HuduUploadImageSourceWorkaroundDownloadCache[$cacheKey]
    }

    $downloaded = Get-HuduUploads -Id ([int]$uploadObject.id) -Download -OutDir $OutDir
    $downloadedObject = Get-HuduUploadImageSourceWorkaroundObject -Upload $downloaded

    if ($downloadedObject -and -not [string]::IsNullOrWhiteSpace([string]$downloadedObject.localPath) -and (Test-Path -LiteralPath $downloadedObject.localPath)) {
        $script:HuduUploadImageSourceWorkaroundDownloadCache[$cacheKey] = [string]$downloadedObject.localPath
        return $script:HuduUploadImageSourceWorkaroundDownloadCache[$cacheKey]
    }

    return $null
}

function ConvertTo-HuduUploadImageSourceWorkaroundPublicPhotoUrl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Url
    )

    if (Get-Command -Name ConvertTo-HuduRelativeURL -ErrorAction SilentlyContinue) {
        return ConvertTo-HuduRelativeURL -Url $Url
    }

    $baseUrl = Get-HuduUploadImageSourceWorkaroundBaseUrl
    if (-not [string]::IsNullOrWhiteSpace($baseUrl)) {
        return [regex]::Replace($Url, "(?i)^$([regex]::Escape($baseUrl))(?=/|$)", '')
    }

    return $Url
}

function New-HuduUploadImageSourceWorkaroundPublicPhoto {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Upload,

        [AllowNull()]
        [int]$RecordId,

        [AllowNull()]
        [ValidateSet('Article', 'Asset')]
        [string]$RecordType,

        [Parameter(Mandatory)]
        [string]$OutDir
    )

    $uploadObject = Get-HuduUploadImageSourceWorkaroundObject -Upload $Upload
    if (-not $uploadObject -or [string]::IsNullOrWhiteSpace([string]$uploadObject.id)) {
        return $null
    }

    $photoCacheKey = "$($uploadObject.id)|$RecordType|$RecordId"
    if ($script:HuduUploadImageSourceWorkaroundPhotoCache.ContainsKey($photoCacheKey)) {
        return $script:HuduUploadImageSourceWorkaroundPhotoCache[$photoCacheKey]
    }

    $localPath = Get-HuduUploadImageSourceWorkaroundDownload -Upload $uploadObject -OutDir $OutDir
    if ([string]::IsNullOrWhiteSpace($localPath) -or -not (Test-Path -LiteralPath $localPath)) {
        throw "Upload $($uploadObject.id) could not be downloaded."
    }

    $photoSplat = @{
        FilePath = $localPath
    }
    if ($RecordId -gt 0) {
        $photoSplat.RecordId = $RecordId
    }
    if (-not [string]::IsNullOrWhiteSpace($RecordType)) {
        $photoSplat.RecordType = $RecordType
    }

    $photoResult = New-HuduPublicPhoto @photoSplat
    $photoObject = $photoResult.public_photo ?? $photoResult
    $photoUrl = $photoObject.url ?? $photoObject.public_url ?? $photoObject.file_url ?? $photoObject.cdn_url

    if ([string]::IsNullOrWhiteSpace([string]$photoUrl)) {
        throw "Hudu did not return a public photo URL for upload $($uploadObject.id)."
    }

    $script:HuduUploadImageSourceWorkaroundPhotoCache[$photoCacheKey] = ConvertTo-HuduUploadImageSourceWorkaroundPublicPhotoUrl -Url ([string]$photoUrl)
    return $script:HuduUploadImageSourceWorkaroundPhotoCache[$photoCacheKey]
}

function Convert-HuduUploadImageSourcesToPublicPhotos {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$Content,

        [AllowNull()]
        [int]$RecordId,

        [AllowNull()]
        [ValidateSet('Article', 'Asset')]
        [string]$RecordType,

        [AllowNull()]
        [hashtable]$UploadLookup,

        [string]$OutDir,

        [switch]$Force
    )

    if ([string]::IsNullOrWhiteSpace($Content) -or -not (Test-HuduUploadImageSourceWorkaroundCandidate -Content $Content -Force:$Force)) {
        return [pscustomobject]@{
            Content      = $Content
            Changed      = $false
            Replacements = @()
            Failures     = @()
        }
    }

    if ([string]::IsNullOrWhiteSpace($OutDir)) {
        $baseOutDir = $MigrationLogs ?? (Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath 'HuduMigration')
        $OutDir = Join-Path -Path $baseOutDir -ChildPath 'UploadImageSourceWorkaround'
    }
    $OutDir = (New-Item -ItemType Directory -Path $OutDir -Force).FullName

    if (-not $UploadLookup) {
        $UploadLookup = Initialize-HuduUploadImageSourceWorkaroundLookup
    }

    $replacements = [System.Collections.ArrayList]@()
    $failures = [System.Collections.ArrayList]@()
    $imgPattern = '<img\b[^>]*>'
    $srcPattern = '(\bsrc\s*=\s*)(["''])(?<Src>[^"'']+)\2'

    $newContent = [regex]::Replace(
        $Content,
        $imgPattern,
        [System.Text.RegularExpressions.MatchEvaluator]{
            param([System.Text.RegularExpressions.Match]$imgMatch)

            $imgTag = $imgMatch.Value
            $srcMatch = [regex]::Match(
                $imgTag,
                $srcPattern,
                [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
            )

            if (-not $srcMatch.Success) {
                return $imgTag
            }

            $src = $srcMatch.Groups['Src'].Value
            if ($src -notmatch '(?i)(?:^|/)(?:file|uploads?)/[^"''\s<>?#]+') {
                return $imgTag
            }

            try {
                $upload = Resolve-HuduUploadImageSourceWorkaroundUpload -SourceUrl $src -Lookup $UploadLookup
                if (-not $upload) {
                    $null = $failures.Add([pscustomobject]@{
                        SourceUrl = $src
                        Reason    = 'No matching Hudu upload was found.'
                    })
                    return $imgTag
                }

                $replacementUrl = New-HuduUploadImageSourceWorkaroundPublicPhoto `
                    -Upload $upload `
                    -RecordId $RecordId `
                    -RecordType $RecordType `
                    -OutDir $OutDir

                if ([string]::IsNullOrWhiteSpace([string]$replacementUrl)) {
                    $null = $failures.Add([pscustomobject]@{
                        SourceUrl = $src
                        UploadId  = $upload.id
                        Reason    = 'No replacement public photo URL was returned.'
                    })
                    return $imgTag
                }

                $null = $replacements.Add([pscustomobject]@{
                    OriginalUrl    = $src
                    ReplacementUrl = $replacementUrl
                    UploadId       = $upload.id
                })

                return [regex]::Replace(
                    $imgTag,
                    $srcPattern,
                    [System.Text.RegularExpressions.MatchEvaluator]{
                        param([System.Text.RegularExpressions.Match]$replaceMatch)
                        "$($replaceMatch.Groups[1].Value)$($replaceMatch.Groups[2].Value)$replacementUrl$($replaceMatch.Groups[2].Value)"
                    },
                    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
                )
            } catch {
                $null = $failures.Add([pscustomobject]@{
                    SourceUrl = $src
                    Reason    = $_.Exception.Message
                })
                return $imgTag
            }
        },
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor
            [System.Text.RegularExpressions.RegexOptions]::Singleline
    )

    return [pscustomobject]@{
        Content      = $newContent
        Changed      = ($newContent -ne $Content)
        Replacements = @($replacements)
        Failures     = @($failures)
    }
}
