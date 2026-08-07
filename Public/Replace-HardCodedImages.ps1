if (-not (Get-Command -Name Convert-HardcodedITGlueImagesToHudu -ErrorAction SilentlyContinue)) {
    . $PSScriptRoot\..\Private\ConvertTo-HuduURL.ps1
}

$HardcodedImagesArticles = Get-HuduArticles | Where-Object {
    Test-HuduContentLinkReplacementCandidate `
        -Content ([string]$_.content) `
        -Type 'rich' `
        -ImageMap $ImageMap `
        -IncludeHardcodedImages
}

foreach ($Article in $HardcodedImagesArticles) {
    $Updated = Convert-HardcodedITGlueImagesToHudu -Content $Article.content -ImageMap $ImageMap
    if (-not $Updated.Changed) {
        continue
    }

    Write-Host "Updating article: $($Article.name)"

    $SetArticleSplat = @{
        Id      = $Article.id
        Content = $Updated.Content
    }
    if ($Article.company_id) { $SetArticleSplat.CompanyId = $Article.company_id }
    if ($Article.name) { $SetArticleSplat.Name = $Article.name }

    Set-HuduArticle @SetArticleSplat
}