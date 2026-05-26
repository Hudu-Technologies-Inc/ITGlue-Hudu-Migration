# Enumerate article-owned image uploads/public photos that are not referenced in
# any article content. This is intended to produce a review queue for possible
# orphaned images, not an automatic deletion list.

$allArticles = @(
    Get-HuduArticles | ForEach-Object {
        if ($null -ne $_.article) { $_.article } else { $_ }
    }
)

$allUploads = @(Get-HuduUploads)
$allPublicPhotos = @()

if (Get-Command Get-HuduPublicPhotos -ErrorAction SilentlyContinue) {
    $allPublicPhotos = @(Get-HuduPublicPhotos)
}
else {
    Write-Warning "Get-HuduPublicPhotos is not available; public photos will not be included."
}

$EmbeddableImageExtensions = @(
    ".jpg", ".jpeg",  # JPEG
    ".png",           # Portable Network Graphics
    ".gif",           # GIF (including animated)
    ".bmp",           # Bitmap (support varies by browser)
    ".webp",          # WebP (modern, compressed)
    ".svg",           # Scalable Vector Graphics
    ".apng",          # Animated PNG (limited support)
    ".avif",          # AV1 Image File Format (modern)
    ".ico",           # Icon files (used in favicons)
    ".jfif",          # JPEG File Interchange Format
    ".pjpeg",         # Progressive JPEG
    ".pjp"            # Alternative JPEG extension
)

function Get-NormalizedExtension {
    param(
        [AllowNull()]
        [string]$FileName,

        [AllowNull()]
        [string]$Extension
    )

    if (-not [string]::IsNullOrWhiteSpace($FileName)) {
        $fromFileName = [System.IO.Path]::GetExtension($FileName)
        if (-not [string]::IsNullOrWhiteSpace($fromFileName)) {
            return $fromFileName.ToLowerInvariant()
        }
    }

    if ([string]::IsNullOrWhiteSpace($Extension)) {
        return $null
    }

    $normalized = $Extension.Trim().ToLowerInvariant()
    if (-not $normalized.StartsWith(".")) {
        $normalized = ".$normalized"
    }

    return $normalized
}

function Get-UrlPath {
    param([AllowNull()][string]$Url)

    if ([string]::IsNullOrWhiteSpace($Url)) {
        return $null
    }

    try {
        return ([uri]$Url).AbsolutePath
    }
    catch {
        return $null
    }
}

function Get-ContentVariants {
    param([AllowNull()][string]$Content)

    if ([string]::IsNullOrWhiteSpace($Content)) {
        return @()
    }

    $variants = [System.Collections.Generic.List[string]]::new()
    $variants.Add($Content)

    $htmlDecoded = [System.Net.WebUtility]::HtmlDecode($Content)
    if (-not [string]::IsNullOrWhiteSpace($htmlDecoded) -and $htmlDecoded -ne $Content) {
        $variants.Add($htmlDecoded)
    }

    try {
        $urlDecoded = [System.Net.WebUtility]::UrlDecode($Content)
        if (-not [string]::IsNullOrWhiteSpace($urlDecoded) -and $urlDecoded -ne $Content -and $urlDecoded -ne $htmlDecoded) {
            $variants.Add($urlDecoded)
        }
    }
    catch {
        # UrlDecode is best-effort only; malformed content should not stop the report.
    }

    return $variants.ToArray()
}

function Test-ContentContainsAnyToken {
    param(
        [AllowNull()]
        [string]$Content,

        [Parameter(Mandatory)]
        [string[]]$Tokens
    )

    $contentVariants = @(Get-ContentVariants -Content $Content)
    if ($contentVariants.Count -lt 1) {
        return $false
    }

    foreach ($variant in $contentVariants) {
        foreach ($token in $Tokens) {
            if ([string]::IsNullOrWhiteSpace($token)) {
                continue
            }

            if ($variant.IndexOf($token, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                return $true
            }
        }
    }

    return $false
}

function New-ImageCandidate {
    param(
        [Parameter(Mandatory)]
        [ValidateSet("Upload", "PublicPhoto")]
        [string]$Source,

        [Parameter(Mandatory)]
        [psobject]$Object
    )

    if ($Source -eq "Upload") {
        $fileName = $Object.filename
        $extension = Get-NormalizedExtension -FileName $fileName -Extension $Object.ext
        $tokens = [System.Collections.Generic.List[string]]::new()

        if (-not [string]::IsNullOrWhiteSpace($Object.slug)) {
            $tokens.Add("/file/$($Object.slug)")
        }

        if (-not [string]::IsNullOrWhiteSpace($Object.url)) {
            $tokens.Add($Object.url)
            $urlPath = Get-UrlPath -Url $Object.url
            if (-not [string]::IsNullOrWhiteSpace($urlPath)) {
                $tokens.Add($urlPath)
            }
        }

        return [pscustomobject]@{
            Source    = $Source
            Id        = $Object.id
            NumericId = $null
            Slug      = $Object.slug
            Url       = $Object.url
            FileName  = $fileName
            Extension = $extension
            Mime      = $Object.mime
            Size      = $Object.size
            OwnerType = $Object.uploadable_type
            OwnerId   = $Object.uploadable_id
            Tokens    = @($tokens | Select-Object -Unique)
            Raw       = $Object
        }
    }

    $fileName = $Object.file_name
    $extension = Get-NormalizedExtension -FileName $fileName -Extension $null
    $tokens = [System.Collections.Generic.List[string]]::new()

    if (-not [string]::IsNullOrWhiteSpace($Object.id)) {
        $tokens.Add("/public_photo/$($Object.id)")
        $tokens.Add("/public_photos/$($Object.id)")
    }

    if (-not [string]::IsNullOrWhiteSpace($Object.url)) {
        $tokens.Add($Object.url)
        $urlPath = Get-UrlPath -Url $Object.url
        if (-not [string]::IsNullOrWhiteSpace($urlPath)) {
            $tokens.Add($urlPath)
        }
    }

    return [pscustomobject]@{
        Source    = $Source
        Id        = $Object.id
        NumericId = $Object.numeric_id
        Slug      = $null
        Url       = $Object.url
        FileName  = $fileName
        Extension = $extension
        Mime      = $null
        Size      = $Object.file_size
        OwnerType = $Object.record_type
        OwnerId   = $Object.record_id
        Tokens    = @($tokens | Select-Object -Unique)
        Raw       = $Object
    }
}

$articleById = @{}
foreach ($article in $allArticles) {
    if ($null -ne $article.id) {
        $articleById["$($article.id)"] = $article
    }
}

$allImages = @(
    $allUploads | ForEach-Object { New-ImageCandidate -Source "Upload" -Object $_ }
    $allPublicPhotos | ForEach-Object { New-ImageCandidate -Source "PublicPhoto" -Object $_ }
) | Where-Object {
    $_.OwnerType -ieq "Article" -and
    $EmbeddableImageExtensions -contains $_.Extension
}

$imageTrack = foreach ($image in $allImages) {
    $ownerArticle = $null
    if ($null -ne $image.OwnerId -and $articleById.ContainsKey("$($image.OwnerId)")) {
        $ownerArticle = $articleById["$($image.OwnerId)"]
    }

    $referencedByArticles = @(
        foreach ($article in $allArticles) {
            if (Test-ContentContainsAnyToken -Content $article.content -Tokens $image.Tokens) {
                $article
            }
        }
    )

    $referencedByArticleIds = @($referencedByArticles | Select-Object -ExpandProperty id -Unique)
    $referencedInOwnerArticle = $false

    if ($null -ne $image.OwnerId) {
        $referencedInOwnerArticle = @($referencedByArticleIds | Where-Object { "$_" -eq "$($image.OwnerId)" }).Count -gt 0
    }

    $referencedInAnyArticle = $referencedByArticleIds.Count -gt 0

    $reason = if ($referencedInAnyArticle) {
        if ($referencedInOwnerArticle) {
            "ReferencedInOwnerArticle"
        }
        else {
            "ReferencedInAnotherArticle"
        }
    }
    elseif ($null -eq $ownerArticle) {
        "OwnerArticleMissing"
    }
    else {
        "NoArticleHtmlReference"
    }

    [pscustomobject]@{
        Source                   = $image.Source
        Id                       = $image.Id
        NumericId                = $image.NumericId
        Slug                     = $image.Slug
        Url                      = $image.Url
        FileName                 = $image.FileName
        Extension                = $image.Extension
        OwnerType                = $image.OwnerType
        OwnerId                  = $image.OwnerId
        OwnerArticleExists       = $null -ne $ownerArticle
        OwnerArticleName         = $ownerArticle.name
        CompanyId                = $ownerArticle.company_id
        ReferencedInOwnerArticle = $referencedInOwnerArticle
        ReferencedInAnyArticle   = $referencedInAnyArticle
        ReferenceCount           = $referencedByArticleIds.Count
        ReferencedByArticleIds   = $referencedByArticleIds -join ","
        Reason                   = $reason
        TokensChecked            = $image.Tokens -join ","
        Raw                      = $image.Raw
    }
}

$orphanedImageCandidates = @(
    $imageTrack | Where-Object { -not $_.ReferencedInAnyArticle }
)

write-host "image candidates: $($orphanedImageCandidates.Count)"

$articlesInQuestion = @(
    $orphanedImageCandidates |
        Where-Object { $_.OwnerType -ieq "Article" -and $null -ne $_.OwnerId } |
        Select-Object -ExpandProperty OwnerId -Unique
)

write-host "unique article candidates: $($articlesInQuestion.Count)"

$uniqueCompanyIDs = @(
    $orphanedImageCandidates |
        Where-Object { $null -ne $_.CompanyId } |
        Select-Object -ExpandProperty CompanyId -Unique
)

write-host "unique companies with candidates: $($uniqueCompanyIDs.Count)"

$AddendumBeginMarker = "<!-- hudu-images-addendum:begin -->"
$AddendumEndMarker = "<!-- hudu-images-addendum:end -->"

function ConvertTo-HtmlAttribute {
    param([AllowNull()][object]$Value)

    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function Remove-HuduImageAddendum {
    param([AllowNull()][string]$Content)

    if ([string]::IsNullOrWhiteSpace($Content)) {
        return ""
    }

    $pattern = "(?is)\s*<hr>\s*$([regex]::Escape($AddendumBeginMarker)).*?$([regex]::Escape($AddendumEndMarker))"
    return [regex]::Replace($Content, $pattern, "").TrimEnd()
}


function New-HuduImageAddendumHtml {
    param(
        [Parameter(Mandatory)]
        [array]$Images
    )

    $imageList = @($Images | Sort-Object Source, FileName, Id)
    if ($imageList.Count -lt 1) {
        return $null
    }

    $html = [System.Text.StringBuilder]::new()
    $null = $html.AppendLine("<hr>")
    $null = $html.AppendLine($AddendumBeginMarker)
    $null = $html.AppendLine("<h2>Images included with this article</h2>")
    $null = $html.AppendLine("<p>The following image attachments were associated with this article but were not found inline in article content.</p>")
    $null = $html.AppendLine("<div class=""hudu-image-addendum"">")

    $imageNumber = 0
    foreach ($image in $imageList) {
        $imageNumber++

        $url = ConvertTo-HtmlAttribute $image.Url
        $fileName = ConvertTo-HtmlAttribute $image.FileName
        $source = ConvertTo-HtmlAttribute $image.Source
        $imageId = ConvertTo-HtmlAttribute $image.Id
        $alt = ConvertTo-HtmlAttribute "Included image $imageNumber of $($imageList.Count): $($image.FileName)"

        $null = $html.AppendLine("<figure style=""margin: 0 0 1rem 0;"">")
        $null = $html.AppendLine("<a href=""$url""><img src=""$url"" alt=""$alt"" title=""$source image ID: $imageId"" style=""max-width: 100%; height: auto;"" /></a>")
        $null = $html.AppendLine("<figcaption>$fileName ($source ID: $imageId)</figcaption>")
        $null = $html.AppendLine("</figure>")
    }

    $null = $html.AppendLine("</div>")
    $null = $html.AppendLine($AddendumEndMarker)

    return $html.ToString()
}

function Set-HuduOwnerArticleImageAddendums {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [array]$ImageCandidates = $orphanedImageCandidates,

        [array]$Articles = $allArticles,

        [switch]$Apply
    )

    $articleLookup = @{}
    foreach ($article in $Articles) {
        if ($null -ne $article.id) {
            $articleLookup["$($article.id)"] = $article
        }
    }

    $candidateGroups = @(
        $ImageCandidates |
            Where-Object {
                $_.OwnerType -ieq "Article" -and
                $null -ne $_.OwnerId -and
                $_.OwnerArticleExists
            } |
            Group-Object OwnerId
    )

    foreach ($group in $candidateGroups) {
        $articleId = $group.Name
        if (-not $articleLookup.ContainsKey($articleId)) {
            Write-Warning "Article ID $articleId was listed as an owner but could not be found in the article cache."
            continue
        }

        $article = $articleLookup[$articleId]
        $existingContent = [string]$article.content
        $contentWithoutOldAddendum = Remove-HuduImageAddendum -Content $existingContent
        $addendum = New-HuduImageAddendumHtml -Images @($group.Group)
        $newContent = "$contentWithoutOldAddendum`n$addendum"
        $wouldChange = $newContent -ne $existingContent

        $result = [pscustomobject]@{
            ArticleId       = $article.id
            ArticleName     = $article.name
            CompanyId       = $article.company_id
            ImageCount      = @($group.Group).Count
            WouldChange     = $wouldChange
            Applied         = $false
            ImageIds        = (@($group.Group) | Select-Object -ExpandProperty Id) -join ","
        }

        if ($Apply -and $wouldChange) {
            if ($PSCmdlet.ShouldProcess("Article ID $($article.id)", "add or refresh included images addendum")) {
                $setArticleSplat = @{
                    Id      = $article.id
                    Content = $newContent
                }

                if ($null -ne $article.company_id) {
                    $setArticleSplat.CompanyId = $article.company_id
                }

                $null = Set-HuduArticle @setArticleSplat
                $result.Applied = $true
            }
        }

        $result
    }
}

