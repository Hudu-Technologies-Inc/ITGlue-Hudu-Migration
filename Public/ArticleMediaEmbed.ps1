function Get-HuduEmbeddableUploadMediaKind {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $extension = [IO.Path]::GetExtension($Path).ToLowerInvariant()
    if ($extension -in @('.mp4', '.m4v', '.webm', '.ogv', '.mov', '.mkv')) { return 'Video' }
    if ($extension -in @('.mp3', '.m4a', '.aac', '.wav', '.ogg', '.oga', '.opus', '.flac', '.weba')) { return 'Audio' }

    return $null
}

function Get-HuduStandaloneArticleFileKind {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $mediaKind = Get-HuduEmbeddableUploadMediaKind -Path $Path
    if ($mediaKind) { return $mediaKind }

    $extension = [IO.Path]::GetExtension($Path).ToLowerInvariant()
    if ($extension -in @('.jpeg', '.jpg', '.png', '.gif', '.webp', '.heic')) { return 'Image' }

    return $null
}

function Get-ITGlueArticleStandaloneFile {
    param(
        [Parameter(Mandatory = $true)]
        $Article,

        [Parameter(Mandatory = $true)]
        [string]$ExportPath,

        [string[]]$Kinds = @('Audio', 'Video'),

        [switch]$RequireTitleFileName
    )

    $articleId = [string]($Article.ITGID ?? $Article.id)
    if ([string]::IsNullOrWhiteSpace($articleId)) { return $null }

    $articleAttachmentPath = Join-Path -Path $ExportPath -ChildPath "attachments\documents\$articleId"
    if (-not (Test-Path -LiteralPath $articleAttachmentPath -PathType Container)) { return $null }

    $candidateFiles = @(
        Get-ChildItem -LiteralPath $articleAttachmentPath -Recurse -File -ErrorAction SilentlyContinue |
            ForEach-Object {
                $kind = Get-HuduStandaloneArticleFileKind -Path $_.FullName
                if ($kind -and $Kinds -contains $kind) {
                    [pscustomobject]@{
                        File = $_
                        Kind = $kind
                    }
                }
            }
    )
    if ($candidateFiles.Count -lt 1) { return $null }

    $articleFileName = [IO.Path]::GetFileName([string]$Article.name)
    $matchingMediaFiles = if (-not [string]::IsNullOrWhiteSpace($articleFileName)) {
        @($candidateFiles | Where-Object { $_.File.Name -ieq $articleFileName })
    } else {
        @()
    }

    if ($RequireTitleFileName) {
        if ($candidateFiles.Count -eq 1 -and $matchingMediaFiles.Count -eq 1) { return $matchingMediaFiles[0] }
        return $null
    }

    if ($matchingMediaFiles.Count -eq 1) { return $matchingMediaFiles[0] }
    if ($candidateFiles.Count -eq 1) { return $candidateFiles[0] }

    return $null
}

function Get-ITGlueArticleStandaloneMediaFile {
    param(
        [Parameter(Mandatory = $true)]
        $Article,

        [Parameter(Mandatory = $true)]
        [string]$ExportPath
    )

    $standaloneFile = Get-ITGlueArticleStandaloneFile -Article $Article -ExportPath $ExportPath -Kinds @('Audio', 'Video')
    if ($standaloneFile) { return $standaloneFile.File }

    return $null
}

function ConvertTo-HuduMediaEmbedRelativeUrl {
    param(
        [AllowNull()]
        [string]$Url
    )

    if ([string]::IsNullOrWhiteSpace($Url)) { return $null }

    if (Get-Command -Name ConvertTo-HuduRelativeURL -ErrorAction SilentlyContinue) {
        return ConvertTo-HuduRelativeURL -Url $Url
    }

    $trimmedUrl = $Url.Trim()
    if ($trimmedUrl.StartsWith('/')) { return $trimmedUrl }

    if (-not [string]::IsNullOrWhiteSpace([string]$HuduBaseDomain)) {
        return [regex]::Replace(
            $trimmedUrl,
            "(?i)^$([regex]::Escape(([string]$HuduBaseDomain).TrimEnd('/')))(?=/|$)",
            ''
        )
    }

    return $trimmedUrl
}

function Resolve-HuduStandaloneImagePhotoCompanyId {
    param(
        [Parameter(Mandatory = $true)]
        $Article,

        [AllowNull()]
        $MatchedCompanies
    )

    $articleCompanyId = [int]($Article.Company.HuduID ?? $Article.HuduObject.company_id ?? $Article.company_id ?? 0)
    if ($articleCompanyId -gt 0) { return $articleCompanyId }

    $primaryCompanyMatches = @(
        @($MatchedCompanies) | Where-Object {
            $true -eq $_.InternalCompany -and [int]($_.HuduID ?? $_.HuduCompanyObject.id ?? 0) -gt 0
        }
    )

    if ($primaryCompanyMatches.Count -eq 1) {
        return [int]($primaryCompanyMatches[0].HuduID ?? $primaryCompanyMatches[0].HuduCompanyObject.id)
    }

    return 1
}

function New-HuduArticleStandaloneMediaEmbed {
    param(
        [Parameter(Mandatory = $true)]
        $Article,

        [Parameter(Mandatory = $true)]
        [string]$ExportPath
    )

    $mediaFile = Get-ITGlueArticleStandaloneMediaFile -Article $Article -ExportPath $ExportPath
    if (-not $mediaFile) { return $null }

    $articleId = [int]($Article.HuduID ?? $Article.id ?? 0)
    if ($articleId -lt 1) { return $null }

    $mediaKind = Get-HuduEmbeddableUploadMediaKind -Path $mediaFile.FullName
    if ([string]::IsNullOrWhiteSpace($mediaKind)) { return $null }

    if ($MaxHuduUploadBytes -and $mediaFile.Length -gt $MaxHuduUploadBytes) {
        Write-Warning "Skipping standalone media embed for '$($Article.name)' because '$($mediaFile.Name)' is larger than the Hudu upload size limit."
        return $null
    }

    $upload = if (Get-Command -Name Find-HuduExistingUpload -ErrorAction SilentlyContinue) {
        Find-HuduExistingUpload -FileName $mediaFile.Name -UploadableId $articleId -UploadableType 'Article'
    } else {
        $null
    }

    if (-not $upload -and (Get-Command -Name Add-HuduUploadOnce -ErrorAction SilentlyContinue)) {
        $uploadResult = Add-HuduUploadOnce -FilePath $mediaFile.FullName -UploadableId $articleId -UploadableType 'Article'
        $upload = $uploadResult.Upload
    }

    if (-not $upload) { return $null }

    $uploadUrl = if (Get-Command -Name Resolve-HuduUploadUrl -ErrorAction SilentlyContinue) {
        Resolve-HuduUploadUrl -Upload $upload
    } else {
        $upload.url ?? $upload.file_url ?? $upload.download_url
    }

    $relativeUrl = ConvertTo-HuduMediaEmbedRelativeUrl -Url $uploadUrl
    if ([string]::IsNullOrWhiteSpace($relativeUrl)) { return $null }

    $encodedTitle = [System.Net.WebUtility]::HtmlEncode([string]($Article.name ?? $mediaFile.Name))
    $encodedUrl = [System.Net.WebUtility]::HtmlEncode($relativeUrl)

    if ($mediaKind -eq 'Video') {
        return [pscustomobject]@{
            Content = "<video src='$encodedUrl' controls='controls' width='640'>$encodedTitle</video>"
            File    = $mediaFile
            Url     = $relativeUrl
            Kind    = $mediaKind
        }
    }

    return [pscustomobject]@{
        Content = "<audio src='$encodedUrl' controls='controls'>$encodedTitle</audio>"
        File    = $mediaFile
        Url     = $relativeUrl
        Kind    = $mediaKind
    }
}

function New-HuduArticleStandaloneImagePhoto {
    param(
        [Parameter(Mandatory = $true)]
        $Article,

        [Parameter(Mandatory = $true)]
        [string]$ExportPath,

        [AllowNull()]
        $MatchedCompanies
    )

    $standaloneFile = Get-ITGlueArticleStandaloneFile -Article $Article -ExportPath $ExportPath -Kinds @('Image') -RequireTitleFileName
    if (-not $standaloneFile) { return $null }

    if (-not (Get-Command -Name New-HuduPhoto -ErrorAction SilentlyContinue)) {
        Write-Warning "Skipping standalone image photo conversion for '$($Article.name)' because New-HuduPhoto is unavailable."
        return $null
    }

    $imageFile = $standaloneFile.File
    $articleId = [int]($Article.HuduID ?? $Article.id ?? 0)
    if ($articleId -lt 1) { return $null }

    if ($MaxHuduUploadBytes -and $imageFile.Length -gt $MaxHuduUploadBytes) {
        Write-Warning "Skipping standalone image photo conversion for '$($Article.name)' because '$($imageFile.Name)' is larger than the Hudu upload size limit."
        return $null
    }

    $companyId = Resolve-HuduStandaloneImagePhotoCompanyId -Article $Article -MatchedCompanies $MatchedCompanies
    $folderId = [int]($Article.HuduObject.folder_id ?? $Article.folder_id ?? 0)
    $photoParams = @{
        Path           = $imageFile.FullName
        Caption        = [string]($Article.name ?? $imageFile.Name)
        Photoable_Type = 'Company'
        Photoable_Id   = $companyId
        CompanyId      = $companyId
    }

    if ($folderId -gt 0) { $photoParams.FolderId = $folderId }

    $photoResponse = New-HuduPhoto @photoParams
    $photo = $photoResponse.photo ?? $photoResponse
    if (-not $photo) { return $null }

    return [pscustomobject]@{
        Kind                   = 'Image'
        File                   = $imageFile
        Photo                  = $photo
        PhotoId                = $photo.id
        ArticleId              = $articleId
        PhotoableType          = 'Company'
        PhotoableId            = $companyId
        ArchiveOriginalArticle = $true
        Content                = "Converted standalone image article to Hudu photo: $($imageFile.Name)"
    }
}
