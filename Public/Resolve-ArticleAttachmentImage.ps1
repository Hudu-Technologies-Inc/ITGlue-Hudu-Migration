function ConvertFrom-ITGlueArticleAttachmentEncodedText {
    param(
        [AllowNull()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $Value
    }

    try {
        return [Uri]::UnescapeDataString($Value)
    } catch {
        return $Value
    }
}

function Get-ITGlueArticleAttachmentSourceInfo {
    param(
        [AllowNull()]
        [object[]]$SourceValues
    )

    $attachmentIds = [System.Collections.ArrayList]@()
    $fileReferences = [System.Collections.ArrayList]@()

    foreach ($value in @($SourceValues)) {
        if ([string]::IsNullOrWhiteSpace([string]$value)) {
            continue
        }

        $decoded = [System.Net.WebUtility]::HtmlDecode(([string]$value).Trim())
        foreach ($candidate in @($decoded, (ConvertFrom-ITGlueArticleAttachmentEncodedText -Value $decoded)) | Select-Object -Unique) {
            if ([string]::IsNullOrWhiteSpace([string]$candidate)) {
                continue
            }

            foreach ($match in [regex]::Matches($candidate, '(?i)(?:^|[\\/])attachments[\\/](?<AttachmentId>\d{1,20})(?=$|[\\/?#&])')) {
                $null = $attachmentIds.Add($match.Groups['AttachmentId'].Value)
            }

            foreach ($match in [regex]::Matches($candidate, '(?i)(?:^|[\\/])files[\\/](?<FileRef>[^"''\s<>?#]+)')) {
                $null = $fileReferences.Add($match.Groups['FileRef'].Value)
            }
        }
    }

    [pscustomobject]@{
        AttachmentIds  = @($attachmentIds | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)
        FileReferences = @($fileReferences | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)
    }
}

function Get-ITGlueArticleAttachmentFiles {
    param(
        [AllowNull()]
        $Article,

        [AllowNull()]
        [object[]]$AttachmentFiles,

        [AllowNull()]
        [string]$ExportPath
    )

    $articleId = [string]($Article.ITGID ?? $Article.id)
    $files = @($AttachmentFiles | Where-Object { $_ -and $_.PSIsContainer -ne $true })

    if (-not [string]::IsNullOrWhiteSpace($articleId)) {
        $articlePathPattern = "[\\/]documents[\\/]$([regex]::Escape($articleId))([\\/]|$)"
        $articleFiles = @($files | Where-Object { $_.FullName -match $articlePathPattern })
        if ($articleFiles.Count -gt 0) {
            return $articleFiles
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($ExportPath)) {
        $attachmentRoot = Join-Path -Path $ExportPath -ChildPath 'attachments\documents'
        if (-not [string]::IsNullOrWhiteSpace($articleId)) {
            $attachmentRoot = Join-Path -Path $attachmentRoot -ChildPath $articleId
        }

        if (Test-Path -LiteralPath $attachmentRoot -PathType Container -ErrorAction SilentlyContinue) {
            return @(Get-ChildItem -LiteralPath $attachmentRoot -Recurse -File -Force -ErrorAction SilentlyContinue)
        }
    }

    return $files
}

function Normalize-ITGlueArticleAttachmentImageName {
    param(
        [AllowNull()]
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return ''
    }

    return ([IO.Path]::GetFileName($Name).Trim()).ToLowerInvariant()
}

function Find-ITGlueArticleAttachmentFileById {
    param(
        [AllowNull()]
        [string]$AttachmentId,

        [AllowNull()]
        [object[]]$AttachmentFiles
    )

    if ([string]::IsNullOrWhiteSpace($AttachmentId)) {
        return $null
    }

    $escapedAttachmentId = [regex]::Escape($AttachmentId)
    @($AttachmentFiles |
        Where-Object {
            $_ -and $_.PSIsContainer -ne $true -and (
                $_.BaseName -eq $AttachmentId -or
                $_.Name -match "^$escapedAttachmentId(?:\D|$)" -or
                $_.FullName -match "[\\/]$escapedAttachmentId(?:[\\/._ -]|$)"
            )
        } |
        Sort-Object @{
            Expression = {
                if ($_.BaseName -eq $AttachmentId) { 0 }
                elseif ($_.Name -match "^$escapedAttachmentId(?:\D|$)") { 1 }
                else { 2 }
            }
        }, FullName) | Select-Object -First 1
}

function Find-ITGlueArticleAttachmentFileByName {
    param(
        [AllowNull()]
        [string]$AttachmentName,

        [AllowNull()]
        [object[]]$AttachmentFiles
    )

    $normalizedName = Normalize-ITGlueArticleAttachmentImageName -Name $AttachmentName
    if ([string]::IsNullOrWhiteSpace($normalizedName)) {
        return $null
    }

    $normalizedStem = Normalize-ITGlueArticleAttachmentImageName -Name ([IO.Path]::GetFileNameWithoutExtension($AttachmentName))
    $normalizedRelativePath = ([string]$AttachmentName).Trim().Replace('/', '\').Trim('\').ToLowerInvariant()

    @($AttachmentFiles |
        Where-Object {
            if (-not $_ -or $_.PSIsContainer -eq $true) {
                $false
            } else {
                $fileName = Normalize-ITGlueArticleAttachmentImageName -Name $_.Name
                $fileStem = Normalize-ITGlueArticleAttachmentImageName -Name $_.BaseName
                $fullName = ([string]$_.FullName).Replace('/', '\').ToLowerInvariant()
                $fullName.EndsWith("\$normalizedRelativePath") -or
                    $fileName -eq $normalizedName -or
                    ($normalizedStem -and $fileStem -eq $normalizedStem)
            }
        } |
        Sort-Object @{
            Expression = {
                $fullName = ([string]$_.FullName).Replace('/', '\').ToLowerInvariant()
                if ($fullName.EndsWith("\$normalizedRelativePath")) { 0 }
                elseif ((Normalize-ITGlueArticleAttachmentImageName -Name $_.Name) -eq $normalizedName) { 1 }
                else { 2 }
            }
        }, FullName) | Select-Object -First 1
}

function Get-ITGlueArticleAttachmentMetadataName {
    param(
        [AllowNull()]
        $Attachment
    )

    @(
        $Attachment.attributes.'file-name'
        $Attachment.attributes.file_name
        $Attachment.attributes.name
        $Attachment.attributes.attachment.file_name
        $Attachment.attributes.attachment.'file-name'
        $Attachment.attributes.'attachment-file-name'
        $Attachment.attributes.'attachment-file_name'
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -First 1
}

function Get-ITGlueArticleAttachmentMetadata {
    param(
        [AllowNull()]
        [string]$ArticleId
    )

    if ([string]::IsNullOrWhiteSpace($ArticleId) -or [string]::IsNullOrWhiteSpace($ITGKey)) {
        return @()
    }

    if (-not $script:ITGlueArticleAttachmentMetadataCache) {
        $script:ITGlueArticleAttachmentMetadataCache = @{}
    }

    if ($script:ITGlueArticleAttachmentMetadataCache.ContainsKey($ArticleId)) {
        return $script:ITGlueArticleAttachmentMetadataCache[$ArticleId]
    }

    $apiBase = @($ITGAPIEndpoint, $settings.ITGAPIEndpoint, $environmentSettings.ITGAPIEndpoint) |
        Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
        Select-Object -First 1

    if ([string]::IsNullOrWhiteSpace($apiBase)) {
        return @()
    }

    $uri = "$($apiBase.TrimEnd('/'))/documents/$ArticleId/relationships/attachments?page%5Bsize%5D=1000"
    try {
        $response = Invoke-RestMethod -Method GET -Uri $uri -Headers @{ 'x-api-key' = $ITGKey } -ErrorAction Stop
        $attachments = @($response.data)
    } catch {
        Write-Warning "Unable to retrieve IT Glue attachments for document $ArticleId while resolving inline attachment images. $($_.Exception.Message)"
        $attachments = @()
    }

    $script:ITGlueArticleAttachmentMetadataCache[$ArticleId] = $attachments
    return $attachments
}

function Resolve-ITGlueArticleAttachmentImageFile {
    param(
        [AllowNull()]
        $Article,

        [AllowNull()]
        [object[]]$SourceValues,

        [AllowNull()]
        [object[]]$AttachmentFiles,

        [AllowNull()]
        [string]$ExportPath
    )

    $sourceInfo = Get-ITGlueArticleAttachmentSourceInfo -SourceValues $SourceValues
    if ($sourceInfo.AttachmentIds.Count -lt 1 -and $sourceInfo.FileReferences.Count -lt 1) {
        return $null
    }

    $articleFiles = Get-ITGlueArticleAttachmentFiles -Article $Article -AttachmentFiles $AttachmentFiles -ExportPath $ExportPath

    foreach ($attachmentId in @($sourceInfo.AttachmentIds)) {
        $foundFile = Find-ITGlueArticleAttachmentFileById -AttachmentId $attachmentId -AttachmentFiles $articleFiles
        if ($foundFile) {
            return $foundFile
        }
    }

    foreach ($fileReference in @($sourceInfo.FileReferences)) {
        foreach ($candidateName in @($fileReference, (ConvertFrom-ITGlueArticleAttachmentEncodedText -Value $fileReference)) | Select-Object -Unique) {
            $foundFile = Find-ITGlueArticleAttachmentFileByName -AttachmentName $candidateName -AttachmentFiles $articleFiles
            if ($foundFile) {
                return $foundFile
            }

            if ($candidateName -match '^(?<AttachmentId>\d{1,20})(?:\D|$)') {
                $foundFile = Find-ITGlueArticleAttachmentFileById -AttachmentId $Matches.AttachmentId -AttachmentFiles $articleFiles
                if ($foundFile) {
                    return $foundFile
                }
            }
        }
    }

    $articleId = [string]($Article.ITGID ?? $Article.id)
    if ([string]::IsNullOrWhiteSpace($articleId)) {
        return $null
    }

    $metadata = @(Get-ITGlueArticleAttachmentMetadata -ArticleId $articleId)
    foreach ($attachmentId in @($sourceInfo.AttachmentIds)) {
        $attachment = $metadata | Where-Object { [string]$_.id -eq [string]$attachmentId } | Select-Object -First 1
        $attachmentName = Get-ITGlueArticleAttachmentMetadataName -Attachment $attachment
        $foundFile = Find-ITGlueArticleAttachmentFileByName -AttachmentName $attachmentName -AttachmentFiles $articleFiles
        if ($foundFile) {
            return $foundFile
        }
    }

    return $null
}

function Convert-ITGlueArticleAttachmentImageToPublicPhoto {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.FileInfo]$ImageFile,

        [Parameter(Mandatory = $true)]
        $Article
    )

    if (-not $script:ArticleAttachmentPublicPhotoMap) {
        $script:ArticleAttachmentPublicPhotoMap = @{}
    }

    $articleId = $Article.HuduID ?? $Article.id
    $cacheKey = "$articleId|$($ImageFile.FullName)"
    if ($script:ArticleAttachmentPublicPhotoMap.ContainsKey($cacheKey)) {
        return $script:ArticleAttachmentPublicPhotoMap[$cacheKey]
    }

    $uploadImage = New-HuduPublicPhoto -FilePath $ImageFile.FullName -record_id $articleId -record_type 'Article'
    $publicPhotoUrl = [string]$uploadImage.public_photo.url
    if (-not [string]::IsNullOrWhiteSpace($HuduBaseDomain)) {
        $publicPhotoUrl = $publicPhotoUrl.Replace($HuduBaseDomain, '')
    }

    $script:ArticleAttachmentPublicPhotoMap[$cacheKey] = $publicPhotoUrl
    return $publicPhotoUrl
}
