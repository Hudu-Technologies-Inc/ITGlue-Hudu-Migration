
function Get-ImageLinksFromHTML {
    param ([string]$htmlContent)
    $allLinks = @()
    $srcPattern = '<img\s[^>]*?src=["'']([^"'']+)["'']'
    $srcMatches = [regex]::Matches($htmlContent, $srcPattern, 'IgnoreCase')
    foreach ($match in $srcMatches) {
        $allLinks += $match.Groups[1].Value
    }
    return $allLinks
}

function Get-LinksFromHTML {
    param ([string]$htmlContent)
    $allLinks = @()
    $hrefPattern = '<a\s[^>]*?href=["'']([^"'']+)["'']'
    $hrefMatches = [regex]::Matches($htmlContent, $hrefPattern, 'IgnoreCase')
    foreach ($match in $hrefMatches) {
        $allLinks += $match.Groups[1].Value
    }
    return $allLinks
}

function Add-AnchorToServerImages {
    param([Parameter(Mandatory)][string]$Html,[bool]$includeUploads=$false)
    if ($true -eq $includeUploads){
        $b = (Get-HuduBaseURL).TrimEnd('/')
        $e = [regex]::Escape($b)
        $ServerPatterns = @("^/public_photo/","^$e/public_photo/","^/uploads/","^$e/uploads/")
    } else {
        $b = (Get-HuduBaseURL).TrimEnd('/')
        $e = [regex]::Escape($b)
        $ServerPatterns = @("^/public_photo/","^$e/public_photo/")
    }
    $imgPattern = '<img\b[^>]*?src=["'']([^"'']+)["''][^>]*>'
    return [regex]::Replace(
        $Html,
        $imgPattern,
        {
            param($match)

            $imgTag = $match.Value
            $src    = $match.Groups[1].Value

            $isOurImage = $false
            foreach ($p in $ServerPatterns) {
                if ($src -match $p) {
                    $isOurImage = $true
                    break
                }
            }

            if (-not $isOurImage) {
                return $imgTag    # leave unchanged
            }

            # Build absolute URL if needed
            if ($src -match '^https?://') {
                $full = $src
            } else {
                # Prepend your domain
                $full = "$(get-hudubaseurl)$src"
            }

            # Wrap <img> with <a>
            return "<a href=""$full"">$imgTag</a>"
        },
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
}



function ReWriteAnchorsToPublicPhotos {
    <#
    either: Match public photos and add anchors when/where already present
    OR
    when image links are present as hrefs, and match public photos, rewrite those hrefs to the public photo urls
    #>

    param ([PSCustomObject]$a,[array]$allpublicphotos,[bool]$ReWriteAnchorsToPublicPhotos = $false)
    if ([string]::IsNullOrWhiteSpace($a.Content)){
        return $null
    }
    Write-Host "processing article $($a.id)"

    $linksFound = [PSCustomObject]@{
        ImageLinks       = Get-ImageLinksFromHTML -htmlContent $a.content
        HyperLinks       = Get-LinksFromHTML      -htmlContent $a.content
        AssociatedPhotos = $allpublicphotos | Where-Object {
            $_.record_id   -eq $a.id -and
            $_.record_type -eq 'Article'
        }
        LinksToImages    = @()
    }
    $linksToImages = $linksFound.HyperLinks | Where-Object {
        $_ -match '\.(jpg|jpeg|png)$'
    }
    if (-not $linksToImages -or $linksToImages.Count -lt 1){
        return $null
    }

    $linksFound.LinksToImages = $linksToImages

    $photos = @($linksFound.AssociatedPhotos)  # force array
    $imageLinks = @($linksFound.LinksToImages) # also force array
    $linkMap = @{}

    if ($photos.Count -eq 1) {
        foreach ($old in $imageLinks) {
            $linkMap[$old] = $photos[0].url
        }
    }
    elseif ($photos.Count -eq $imageLinks.Count) {
        for ($i = 0; $i -lt $imageLinks.Count; $i++) {
            $linkMap[$imageLinks[$i]] = $photos[$i].url
        }
    }
    else {
        $newContent = $a.content
        foreach ($old in $imageLinks) {
            # Only touch image-like hrefs, which LinksToImages already is
            $escaped = [regex]::Escape($old)

            # Pattern: <a ... href="<old>" ...>innerHtml</a>
            # We keep innerHtml ($2) and drop the <a> wrapper
            $pattern = "(<a\b[^>]*?href\s*=\s*['""]$escaped['""][^>]*>)(.*?)(</a>)"

            $newContent = [regex]::Replace(
                $newContent,
                $pattern,
                '$2',
                [System.Text.RegularExpressions.RegexOptions]::IgnoreCase `
                    -bor [System.Text.RegularExpressions.RegexOptions]::Singleline
            )
        }
        if ($true -eq $ReWriteAnchorsToPublicPhotos){
            $newcontent = Add-AnchorToServerImages -Html $newContent
        }
        if ($newContent -ne $a.content) {
            return $newcontent
        }
        else {
            return $null
        }
    }

    if ($linkMap.Count -gt 0) {
        $newContent = $a.content

        foreach ($kvp in $linkMap.GetEnumerator()) {
            $old = $kvp.Key
            $new = $kvp.Value
            $escaped = [regex]::Escape($old)
            $newContent = [regex]::Replace(
                $newContent,
                "(href\s*=\s*['""])$escaped(['""])",
                "`$1$new`$2",
                [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
            )
        }

        if ($newContent -ne $a.content) {
            Write-Host "Updating article $($a.id) with fixed image links" -ForegroundColor Cyan
            return $newContent
        } else {
            return $null
        }
    }
    return $null
}


function Write-DirectContentLinks {
    param (
        [array]$forArticles,
        [array]$allpublicphotos,
        [bool]$ReWriteAnchorsToPublicPhotos = $false # if anchors dont match image sources, rewrite links to images?
    )

    $linkResultsPerArticle = @{}
    foreach ($a in $forArticles){
        if ([string]::IsNullOrWhiteSpace($a.Content)){
            write-host "nothing to do for article $($a.id)"
            continue
        }
        write-host "processing article $($a.id)"
        $updatedContent = ReWriteAnchorsToPublicPhotos -a $a -allpublicphotos $allpublicphotos -ReWriteAnchorsToPublicPhotos $ReWriteAnchorsToPublicPhotos
        if ($null -ne $updatedContent){
            $linkResultsPerArticle["$($a.id)"] = @{
                OriginalContent = $a.Content
                UpdatedContent  = $updatedContent
                result = Set-HuduArticle -id $a.id -Content $updatedContent
            }
        }
    }
    return $linkResultsPerArticle
}