function Get-ITGFileUrlParts {
    param([string]$Url)

    if ($Url -match '/assets/(?<layoutId>\d+)-(?<assetType>[^/]+)/records/(?<recordId>\d+)/files/(?<fileId>\d+)(?=[/?#]|$)') {
        [pscustomobject]@{
            LayoutId  = $Matches.layoutId
            AssetType = [Uri]::UnescapeDataString($Matches.assetType)
            RecordId  = $Matches.recordId
            FileId    = $Matches.fileId
        }
    }
}

function Get-ITGUploadProperty {
    param($InputObject, [string]$Name)

    if ($InputObject -is [System.Collections.IDictionary]) { return $InputObject[$Name] }
    if ($null -ne $InputObject -and $null -ne $InputObject.PSObject.Properties[$Name]) {
        return $InputObject.PSObject.Properties[$Name].Value
    }
}

function Normalize-ITGAttachmentName {
    param(
        [string]$Name,
        [switch]$WithoutExtension
    )

    if ([string]::IsNullOrWhiteSpace($Name)) { return '' }

    $decodedName = [Net.WebUtility]::HtmlDecode([Uri]::UnescapeDataString($Name))
    $extension = [IO.Path]::GetExtension($decodedName)
    $text = [IO.Path]::GetFileNameWithoutExtension($decodedName)

    # IT Glue upload fields often keep the original name, while exports sanitize
    # punctuation and sometimes append a timestamp before the extension.
    $text = $text -replace '^\d{5,}[-_ ]', ''
    $text = $text -replace '-\d{8,14}$', ''
    if (-not $WithoutExtension) { $text += $extension }
    $text = $text.Normalize([Text.NormalizationForm]::FormD)
    $chars = $text.ToCharArray() | Where-Object {
        [Globalization.CharUnicodeInfo]::GetUnicodeCategory($_) -ne [Globalization.UnicodeCategory]::NonSpacingMark
    }
    $text = (-join $chars).ToLowerInvariant()
    $text = $text -replace '&', ' and '
    $text = $text -replace '[^\p{L}\p{Nd}]+', ' '
    $text = $text.Trim()
    $text = $text -replace '\s+', ' '

    return $text
}

function Get-ITGAttachmentNameScore {
    param(
        [string]$ExpectedName,
        [System.IO.FileInfo]$Candidate
    )

    if ($Candidate.Name -ieq $ExpectedName) { return 100 }

    $expectedExtension = [IO.Path]::GetExtension([Net.WebUtility]::HtmlDecode([Uri]::UnescapeDataString($ExpectedName)))
    $candidateExtension = $Candidate.Extension
    if ($expectedExtension -ine $candidateExtension -and
        -not ($expectedExtension -in @('.jpg', '.jpeg') -and $candidateExtension -in @('.jpg', '.jpeg'))) {
        return 0
    }

    $expectedFull = Normalize-ITGAttachmentName -Name $ExpectedName
    $candidateFull = Normalize-ITGAttachmentName -Name $Candidate.Name
    if ($expectedFull -and $expectedFull -eq $candidateFull) { return 96 }

    $expectedStem = Normalize-ITGAttachmentName -Name $ExpectedName -WithoutExtension
    $candidateStem = Normalize-ITGAttachmentName -Name $Candidate.Name -WithoutExtension
    if ($expectedStem -and $expectedStem -eq $candidateStem) { return 94 }
    return 0
}

function Get-ITGAttachmentMatch {
    param(
        [string]$ExpectedName,
        [Nullable[Int64]]$ExpectedSize,
        [object]$UrlParts,
        [object]$UploadAsset,
        [array]$Candidates
    )

    if (-not $Candidates -or $Candidates.Count -eq 0) { return $null }

    $hintIds = @(
        if ($UrlParts) { $UrlParts.RecordId }
        Get-ITGUploadProperty $UploadAsset 'ITGID'
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace("$_") } | Select-Object -Unique

    $scored = foreach ($candidate in $Candidates) {
        if ($null -eq $candidate) { continue }
        $candidateId = if ($candidate.Name -match '^(?<id>\d+)(?:[-_ ]|(?=\.[^.]+$)|$)') { $Matches.id } else { $null }
        $fileIdPrefixMatch = $UrlParts -and $candidateId -eq $UrlParts.FileId
        $nameScore = Get-ITGAttachmentNameScore -ExpectedName $ExpectedName -Candidate $candidate
        if (-not $fileIdPrefixMatch -and $nameScore -lt 94) { continue }
        # A different exported file ID is evidence against a name-only match.
        # Keep literal original names such as 20240101-report.pdf valid.
        if ($UrlParts -and $candidateId -and -not $fileIdPrefixMatch -and $candidate.Name -ine $ExpectedName) { continue }

        $dirMatch = $false
        foreach ($hintId in $hintIds) {
            if ($candidate.Directory.FullName -match "[\\/]$([regex]::Escape([string]$hintId))([\\/]|$)") { $dirMatch = $true; break }
        }
        $sizeMatch = $null -ne $ExpectedSize -and $candidate.Length -eq $ExpectedSize
        $score = $nameScore
        if ($sizeMatch) { $score += 20 }
        if ($dirMatch) { $score += 30 }
        if ($fileIdPrefixMatch) { $score += 1000 }

        [pscustomobject]@{
            File              = $candidate
            Score             = $score
            NameScore         = $nameScore
            SizeMatch         = [bool]$sizeMatch
            DirMatch          = $dirMatch
            FileIdPrefixMatch = [bool]$fileIdPrefixMatch
        }
    }

    $ranked = @($scored | Sort-Object Score, NameScore -Descending)
    if ($ranked.Count -eq 0) { return $null }

    $best = $ranked[0]
    $tied = @($ranked | Where-Object { $_.Score -eq $best.Score })
    if ($tied.Count -gt 1) {
        return [pscustomobject]@{
            File = $null
            Score = $best.Score
            Problem = 'Multiple equally likely exported files'
            CandidatePaths = @($tied.File.FullName)
        }
    }
    return $best
}

function Add-ITGUploadFileToIndex {
    param([hashtable]$Index, [string]$Key, [System.IO.FileInfo]$File)

    if (-not $Index.ContainsKey($Key)) { $Index[$Key] = [System.Collections.Generic.List[System.IO.FileInfo]]::new() }
    $Index[$Key].Add($File)
}

$uploadExportRoot = (Resolve-Path -LiteralPath $ITGlueExportPath).Path.TrimEnd([char[]]@('\', '/'))
$AttachRoot = Join-Path $uploadExportRoot 'attachments'
$Attachfiles = @(if (Test-Path -LiteralPath $AttachRoot) { Get-ChildItem -LiteralPath $AttachRoot -Recurse -File -Force })
$UploadFieldExportDirs = @(
    Get-ChildItem -LiteralPath $uploadExportRoot -Directory -Force |
        Where-Object { $_.Name -ne 'attachments' -and $_.Name -match '^[^-]+-.+' }
)
$UploadFieldFiles = @($UploadFieldExportDirs | ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -Recurse -File -Force })
$AllUploadCandidateFiles = @($Attachfiles + $UploadFieldFiles)
$AttachFilesByAssetType = @{}
$AttachFilesByRecord = @{}
$UploadFilesByFolder = @{}
$UploadFilesById = @{}
$UploadTypeCandidateCache = @{}
foreach ($file in $AllUploadCandidateFiles) {
    $relative = $file.FullName.Substring($uploadExportRoot.Length).TrimStart([char[]]@('\', '/'))
    $segments = @($relative -split '[\\/]')
    Add-ITGUploadFileToIndex -Index $UploadFilesByFolder -Key $segments[0] -File $file
    if ($segments[0] -eq 'attachments' -and $segments.Count -ge 3) {
        Add-ITGUploadFileToIndex -Index $AttachFilesByAssetType -Key $segments[1] -File $file
        if ($segments.Count -ge 4) {
            Add-ITGUploadFileToIndex -Index $AttachFilesByRecord -Key "$($segments[1])/$($segments[2])" -File $file
        }
    }
    if ($file.Name -match '^(?<id>\d+)(?:[-_ ]|(?=\.[^.]+$)|$)') {
        Add-ITGUploadFileToIndex -Index $UploadFilesById -Key $Matches.id -File $file
    }
}

$MatchedUploadFields = @{}
$UnresolvedUploadFields = @{}
foreach ($UploadAsset in $MatchedAssets | Where-Object { $_.HuduID -and $_.HuduID -gt 0 }) {
    $traits = $UploadAsset.ITGObject.attributes.traits
    $traitProperties = if ($traits -is [System.Collections.IDictionary]) {
        foreach ($key in $traits.Keys) { [pscustomobject]@{ Name = $key; Value = $traits[$key] } }
    } elseif ($null -ne $traits) {
        $traits.PSObject.Properties
    }

    foreach ($prop in $traitProperties) {
        $name  = $prop.Name
        $attachmentIndex = 0
        # Upload traits can be one object or an array; retain a result for every file.
        foreach ($value in @($prop.Value)) {
            $attachmentIndex++
            $filename = [string](Get-ITGUploadProperty $value 'name')
            $fileUrl = [string](Get-ITGUploadProperty $value 'url')
            if ([string]::IsNullOrWhiteSpace($filename) -or [string]::IsNullOrWhiteSpace($fileUrl)) { continue }

            $parts = Get-ITGFileUrlParts $fileUrl
            $resultKey = "$($UploadAsset.HuduID):${name}:$attachmentIndex"
            $entry = @{
                UploadAsset = $UploadAsset
                FieldName   = $name
                FieldIndex  = $attachmentIndex
                FilePath    = $null
                ITGFileUrl  = $fileUrl
                ITGFileName = $filename
                MatchScore  = 0
            }
            $expectedSize = $null
            $size = Get-ITGUploadProperty $value 'size'
            $parsedSize = 0L
            if ([Int64]::TryParse("$size", [ref]$parsedSize) -and $parsedSize -ge 0) { $expectedSize = $parsedSize }

            $candidateGroups = [System.Collections.Generic.List[object]]::new()
            if ($parts) {
                # Search file IDs across the export before accepting a name in a
                # narrower folder. Exported names can be completely rewritten.
                if ($UploadFilesById.ContainsKey($parts.FileId)) { $candidateGroups.Add($UploadFilesById[$parts.FileId]) }
                $recordKey = "$($parts.AssetType)/$($parts.RecordId)"
                if ($AttachFilesByRecord.ContainsKey($recordKey)) { $candidateGroups.Add($AttachFilesByRecord[$recordKey]) }
                $fieldFolder = "$($parts.AssetType)-$name"
                if ($UploadFilesByFolder.ContainsKey($fieldFolder)) { $candidateGroups.Add($UploadFilesByFolder[$fieldFolder]) }
                if (-not $UploadTypeCandidateCache.ContainsKey($parts.AssetType)) {
                    $UploadTypeCandidateCache[$parts.AssetType] = @(
                        if ($AttachFilesByAssetType.ContainsKey($parts.AssetType)) { $AttachFilesByAssetType[$parts.AssetType] }
                        foreach ($directory in $UploadFieldExportDirs) {
                            # Preserve hyphens in layout slugs such as network-devices.
                            if ($directory.Name.StartsWith("$($parts.AssetType)-", [StringComparison]::OrdinalIgnoreCase) -and $UploadFilesByFolder.ContainsKey($directory.Name)) {
                                $UploadFilesByFolder[$directory.Name]
                            }
                        }
                    )
                }
                $typeCandidates = $UploadTypeCandidateCache[$parts.AssetType]
                if ($typeCandidates.Count -gt 0) { $candidateGroups.Add($typeCandidates) }
            }
            $candidateGroups.Add($AllUploadCandidateFiles)
            $match = $null
            foreach ($group in $candidateGroups) {
                $match = Get-ITGAttachmentMatch -ExpectedName $filename -ExpectedSize $expectedSize -UrlParts $parts -UploadAsset $UploadAsset -Candidates @($group)
                if ($null -ne $match) { break }
            }
            if ($null -eq $match -or $null -eq $match.File) {
                $entry.Problem = if ($null -eq $match) { 'No matching exported file' } else { $match.Problem }
                $entry.CandidatePaths = if ($null -eq $match) { @() } else { $match.CandidatePaths }
                if ($null -ne $match) { $entry.MatchScore = $match.Score }
                $UnresolvedUploadFields[$resultKey] = $entry
                Write-Warning "Unable to resolve '$filename' with url hint '$fileUrl' in asset ID $($UploadAsset.HuduID): $($entry.Problem)"
                continue
            }

            $matchedFile = $match.File
            $entry.FilePath = $matchedFile.FullName
            $entry.MatchScore = $match.Score
            Write-Host "Matched '$filename' to '$($matchedFile.FullName)' with score $($match.Score) for asset ID $($UploadAsset.HuduID)"
            if ($matchedFile.Length -gt ($MaxHuduUploadBytes ?? 100MB)) {
                Write-Warning "Skipping upload field attachment '$filename' because it exceeds the Hudu upload limit ($($matchedFile.Length) bytes). Added to manual actions."
                if (Get-Command -Name Add-OversizedAttachmentManualAction -ErrorAction SilentlyContinue) {
                    Add-OversizedAttachmentManualAction -FoundFile $matchedFile -FoundAsset $UploadAsset -UploadType 'Asset' -FieldName $name
                }
                $entry.Problem = 'Attachment exceeds the Hudu upload limit'
                $UnresolvedUploadFields[$resultKey] = $entry
                continue
            }

            try {
                $uploadStatus = 'Uploaded Successfully'
                if (Get-Command -Name Add-HuduUploadOnce -ErrorAction SilentlyContinue) {
                    $uploadResult = Add-HuduUploadOnce -uploadable_id $UploadAsset.HuduID -filePath $matchedFile.FullName -uploadable_type 'Asset' -ErrorAction Stop
                    $newUpload = $uploadResult.Upload
                    $uploadStatus = $uploadResult.Status
                } else {
                    $newUpload = New-HuduUpload -uploadable_id $UploadAsset.HuduID -filePath $matchedFile.FullName -uploadable_type 'Asset' -ErrorAction Stop
                    $hasUploadWrapper = if ($newUpload -is [System.Collections.IDictionary]) {
                        $newUpload.Contains('upload')
                    } else {
                        $null -ne $newUpload -and $null -ne $newUpload.PSObject.Properties['upload']
                    }
                    if ($hasUploadWrapper) { $newUpload = Get-ITGUploadProperty $newUpload 'upload' }
                }
                if ($null -eq $newUpload) { throw 'Hudu returned no upload object' }
                $entry.UploadStatus = $uploadStatus
                $entry.Upload = $newUpload
                $MatchedUploadFields[$resultKey] = $entry
            } catch {
                $entry.Problem = "Upload failed: $($_.Exception.Message)"
                $UnresolvedUploadFields[$resultKey] = $entry
                Write-Warning "Failed to upload '$filename' at '$($matchedFile.FullName)' for asset ID $($UploadAsset.HuduID): $($_.Exception.Message)"
            }
        }
    }
}
