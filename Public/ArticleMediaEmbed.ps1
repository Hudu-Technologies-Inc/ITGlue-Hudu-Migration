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

function Get-ITGlueArticleStandaloneMediaFile {
    param(
        [Parameter(Mandatory = $true)]
        $Article,

        [Parameter(Mandatory = $true)]
        [string]$ExportPath
    )

    $articleId = [string]($Article.ITGID ?? $Article.id)
    if ([string]::IsNullOrWhiteSpace($articleId)) { return $null }

    $articleAttachmentPath = Join-Path -Path $ExportPath -ChildPath "attachments\documents\$articleId"
    if (-not (Test-Path -LiteralPath $articleAttachmentPath -PathType Container)) { return $null }

    $mediaFiles = @(
        Get-ChildItem -LiteralPath $articleAttachmentPath -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { -not [string]::IsNullOrWhiteSpace((Get-HuduEmbeddableUploadMediaKind -Path $_.FullName)) }
    )
    if ($mediaFiles.Count -lt 1) { return $null }

    $articleFileName = [IO.Path]::GetFileName([string]$Article.name)
    $matchingMediaFiles = if (-not [string]::IsNullOrWhiteSpace($articleFileName)) {
        @($mediaFiles | Where-Object { $_.Name -ieq $articleFileName })
    } else {
        @()
    }

    if ($matchingMediaFiles.Count -eq 1) { return $matchingMediaFiles[0] }
    if ($mediaFiles.Count -eq 1) { return $mediaFiles[0] }

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
