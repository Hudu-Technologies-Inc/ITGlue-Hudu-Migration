
function Set-HuduImageAnchorsReplaced {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Html,[bool]$IncludeUploads = $false)

    $base = (Get-HuduBaseURL).TrimEnd('/')
    $e    = [regex]::Escape($base)

    if ($IncludeUploads) {
        $serverPatterns = @(
            "^/public_photo[s]?/",
            "^$e/public_photo[s]?/",
            "^/uploads/",
            "^$e/uploads/"
        )
    }
    else {
        $serverPatterns = @(
            "^/public_photo[s]?/",
            "^$e/public_photo[s]?/"
        )
    }

    $isHuduHostedImage = {
        param([string]$src)

        foreach ($p in $serverPatterns) {
            if ($src -match $p) {
                return $true
            }
        }

        return $false
    }

    $getFullImageUrl = {
        param([string]$src)

        if ($src -match '^https?://') {
            return $src
        }

        if ($src.StartsWith('/')) {
            return "$base$src"
        }

        return "$base/$src"
    }

    $imgPattern = '<img\b[^>]*\bsrc\s*=\s*["'']([^"'']+)["''][^>]*>'

    # 1) Remove existing anchors that ONLY wrap one of our hosted <img> tags.
    # <a ...><img src="/public_photo/..."></a>  ->  <img src="/public_photo/...">
    # External image links are preserved.
    $noAnchors = [regex]::Replace(
        $Html,
        '<a\b[^>]*>\s*(<img\b[^>]*>)\s*</a>',
        {
            param($match)

            $imgTag = $match.Groups[1].Value
            $imgMatch = [regex]::Match($imgTag, $imgPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if (-not $imgMatch.Success) {
                return $match.Value
            }

            $src = $imgMatch.Groups[1].Value
            if (& $isHuduHostedImage $src) {
                return $imgTag
            }

            return $match.Value
        },
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase `
            -bor [System.Text.RegularExpressions.RegexOptions]::Singleline
    )

    # 2) Wrap qualifying <img> tags in <a href="fullsrc">
    $result = [regex]::Replace(
        $noAnchors,
        $imgPattern,
        {
            param($match)

            $imgTag = $match.Value
            $src    = $match.Groups[1].Value

            # Only touch "our" images (public_photo / uploads)
            if (-not (& $isHuduHostedImage $src)) {
                return $imgTag   # leave external images alone
            }

            $full = & $getFullImageUrl $src

            "<a href=""$full"">$imgTag</a>"
        },
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )

    return $result
}

function Get-AllHuduHostedImageAnchorsReplaced {
    [CmdletBinding(SupportsShouldProcess)]
    param ([array]$allHuduArticles=@(),[bool]$includeUploads=$false)

    foreach ($a in @($allHuduArticles)) {
        if ([string]::IsNullOrEmpty($a.content)) {
            Write-Host "skipping $($a.id)"
            [pscustomobject]@{
                Status      = 'skipped'
                ArticleId   = $a.id
                ArticleName = $a.name
                Reason      = 'empty content'
            }
            continue
        }

        $newContent = Set-HuduImageAnchorsReplaced -Html $a.content -IncludeUploads $includeUploads
        if ($newContent -eq $a.content) {
            [pscustomobject]@{
                Status      = 'clean'
                ArticleId   = $a.id
                ArticleName = $a.name
            }
            continue
        }

        try {
            $updatedArticle = $null
            if ($PSCmdlet.ShouldProcess("Article $($a.id) '$($a.name)'", "replace hosted image anchors")) {
                $setArticleSplat = @{
                    Id      = $a.id
                    Content = $newContent
                }
                if ($a.name) { $setArticleSplat.Name = $a.name }
                if ($a.company_id) { $setArticleSplat.CompanyId = $a.company_id }

                $updatedArticle = Set-HuduArticle @setArticleSplat -ErrorAction Stop
            }

            [pscustomobject]@{
                Status         = if ($WhatIfPreference) { 'whatif' } else { 'replaced' }
                ArticleId      = $a.id
                ArticleName    = $a.name
                UpdatedArticle = $updatedArticle
            }
        }
        catch {
            [pscustomobject]@{
                Status      = 'failed'
                ArticleId   = $a.id
                ArticleName = $a.name
                Error       = $_.Exception.Message
            }
        }
    }
}
