if (-not (Get-Command -Name Convert-HardcodedITGlueImagesToHudu -ErrorAction SilentlyContinue)) {
    . $PSScriptRoot\..\Private\ConvertTo-HuduURL.ps1
}
if (-not (Get-Command -Name Get-HuduArticleLocalContent -ErrorAction SilentlyContinue)) {
    . $PSScriptRoot\ArticleContentLocalCache.ps1
}

$ArticleContentCandidates = if ($MatchedArticles) {
    @($MatchedArticles)
} elseif (Test-Path -LiteralPath "$MigrationLogs\Articles.json" -PathType Leaf -ErrorAction SilentlyContinue) {
    @(Get-Content -LiteralPath "$MigrationLogs\Articles.json" -Raw | ConvertFrom-Json -Depth 100)
} else {
    @()
}

$HardcodedImagesArticles = $ArticleContentCandidates | Where-Object {
    $ArticleContent = Get-HuduArticleLocalContent -Article $_
    if ($null -eq $ArticleContent) {
        Write-Warning "Skipping article '$($_.name)' because local article HTML was not found at '$($_.LocalContentPath)'."
        return $false
    }

    Test-HuduContentLinkReplacementCandidate `
        -Content $ArticleContent `
        -Type 'rich' `
        -ImageMap $ImageMap `
        -IncludeHardcodedImages
}

foreach ($Article in $HardcodedImagesArticles) {
    $ArticleContent = Get-HuduArticleLocalContent -Article $Article
    $Updated = Convert-HardcodedITGlueImagesToHudu -Content $ArticleContent -ImageMap $ImageMap
    if (-not $Updated.Changed) {
        continue
    }

    Write-Host "Updating article: $($Article.name)"

    $SetArticleSplat = @{
        Id      = $Article.HuduID ?? $Article.id
        Content = $Updated.Content
    }
    if ($Article.company.HuduID) { $SetArticleSplat.CompanyId = $Article.company.HuduID }
    elseif ($Article.company_id) { $SetArticleSplat.CompanyId = $Article.company_id }
    if ($Article.name) { $SetArticleSplat.Name = $Article.name }

    Set-HuduArticle @SetArticleSplat
}
