function ConvertTo-PublicArticleReportHtml {
    param([AllowNull()]$Value)

    if ($null -eq $Value) { return "" }
    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function ConvertTo-PublicArticleReportUrl {
    param(
        [AllowNull()][string]$Url,
        [AllowNull()][string]$BaseUrl
    )

    if ([string]::IsNullOrWhiteSpace($Url)) { return "" }
    if ($Url -match '^https?://') { return $Url }
    if ([string]::IsNullOrWhiteSpace($BaseUrl)) { return $Url }

    return "$($BaseUrl.TrimEnd('/'))/$($Url.TrimStart('/'))"
}

function New-PublicArticleReportLink {
    param(
        [AllowNull()][string]$Url,
        [string]$Label
    )

    if ([string]::IsNullOrWhiteSpace($Url)) {
        return '<span>Not available</span>'
    }

    $safeUrl = ConvertTo-PublicArticleReportHtml $Url
    $safeLabel = ConvertTo-PublicArticleReportHtml $Label
    return "<a href=""$safeUrl"" target=""_blank"" rel=""noopener noreferrer"">$safeLabel</a>"
}

function Test-ITGluePublicArticleFlag {
    param([AllowNull()]$Value)

    if ($Value -is [bool]) { return $Value }
    if ($null -eq $Value) { return $false }

    $normalized = ([string]$Value).Trim()
    return $normalized -in @('true', 'True', 'TRUE', '1', 'yes', 'Yes', 'YES')
}

$publicArticleReportTitle = "Public ITGlue Articles Report"
$publicArticleReportRows = @()
$publicArticleReportHtml = $null
$publicArticleReportHuduArticle = $null
$articleRelationPreloadPath = Join-Path $migrationlogs "RelationsPreload-Articles.json"

if (Test-Path -LiteralPath $articleRelationPreloadPath -PathType Leaf) {
    $publicArticleIDs = @(
        Get-Content -LiteralPath $articleRelationPreloadPath -Raw |
            ConvertFrom-Json -Depth 99 |
            Where-Object { Test-ITGluePublicArticleFlag $_.data.attributes.public } |
            ForEach-Object { [string]$_.data.id }
    )
} else {
    Write-Warning "Skipping public ITGlue articles report because RelationsPreload-Articles.json was not found."
    $publicArticleIDs = @()
}

$publicArticleReportRows = @(
    $matchedarticles |
        Where-Object { $publicArticleIDs -contains [string]$_.ITGID } |
        Sort-Object @{ Expression = { $_.Company.CompanyName } }, @{ Expression = { $_.Name } } |
        ForEach-Object {
            $huduUrl = ConvertTo-PublicArticleReportUrl -Url ($_.HuduObject.url ?? $_.url) -BaseUrl ($HuduBaseDomain ?? $settings.HuduBaseDomain)
            $itgBaseUrl = [string]($ITGURL ?? $settings.ITGURL ?? '')
            $itGlueUrl = if (-not [string]::IsNullOrWhiteSpace($itgBaseUrl) -and -not [string]::IsNullOrWhiteSpace([string]$_.ITGLocator)) {
                ConvertTo-PublicArticleReportUrl -Url "$($itgBaseUrl.TrimEnd('/'))/$($_.ITGLocator)" -BaseUrl $null
            } else {
                ""
            }

            [pscustomobject]@{
                CompanyName = [string]($_.Company.CompanyName ?? $_.HuduObject.company_name ?? '')
                ArticleName = [string]($_.Name ?? $_.HuduObject.name ?? '')
                HuduUrl     = [string]$huduUrl
                ITGlueUrl   = [string]$itGlueUrl
                ITGlueID    = [string]$_.ITGID
                HuduID      = [string]($_.HuduID ?? $_.HuduObject.id ?? '')
            }
        }
)

ConvertTo-Json -InputObject $publicArticleReportRows -Depth 10 | Out-File -LiteralPath (Join-Path $migrationlogs "PublicITGlueArticlesReport.json") -Encoding utf8

$publicArticleTableRows = @(
    foreach ($row in $publicArticleReportRows) {
        $companyName = ConvertTo-PublicArticleReportHtml $row.CompanyName
        $articleName = ConvertTo-PublicArticleReportHtml $row.ArticleName
        $huduLink = New-PublicArticleReportLink -Url $row.HuduUrl -Label "Hudu"
        $itGlueLink = New-PublicArticleReportLink -Url $row.ITGlueUrl -Label "ITGlue"

        "<tr><td>$companyName</td><td>$articleName</td><td>$huduLink</td><td>$itGlueLink</td></tr>"
    }
)

if ($publicArticleTableRows.Count -eq 0) {
    $publicArticleTableRows = @('<tr><td colspan="4">No public ITGlue articles were found in the article relation preload.</td></tr>')
}

$publicArticleReportHtml = @"
<h1>$publicArticleReportTitle</h1>
<p>Found $($publicArticleReportRows.Count) ITGlue document(s) marked public by the article relation preload.</p>
<table>
  <thead>
    <tr>
      <th>Company Name</th>
      <th>Article Name</th>
      <th>Hudu Link</th>
      <th>ITGlue Link</th>
    </tr>
  </thead>
  <tbody>
$($publicArticleTableRows -join [Environment]::NewLine)
  </tbody>
</table>
"@

$publicArticleReportHtml | Out-File -LiteralPath (Join-Path $migrationlogs "PublicITGlueArticlesReport.html") -Encoding utf8

try {
    $existingReportCandidates = @(Get-HuduArticles -Name $publicArticleReportTitle)
    $existingReportArticle = @(
        $existingReportCandidates |
            ForEach-Object { $_.articles ?? $_.article ?? $_ } |
            Where-Object { $_.name -eq $publicArticleReportTitle -and -not $_.company_id }
    ) | Select-Object -First 1

    if ($existingReportArticle) {
        $setPublicArticleReportSplat = @{
            Id      = $existingReportArticle.id
            Name    = $publicArticleReportTitle
            Content = $publicArticleReportHtml
        }

        if ($existingReportArticle.company_id) {
            $setPublicArticleReportSplat.CompanyId = $existingReportArticle.company_id
        }

        $publicArticleReportHuduArticle = (Set-HuduArticle @setPublicArticleReportSplat).article ?? $existingReportArticle
        Write-Host "Updated Hudu public ITGlue articles report: $($publicArticleReportHuduArticle.url ?? $existingReportArticle.url)" -ForegroundColor Cyan
    } else {
        $newPublicArticleReport = New-HuduArticle -Name $publicArticleReportTitle -Content $publicArticleReportHtml
        $publicArticleReportHuduArticle = $newPublicArticleReport.article ?? $newPublicArticleReport
        Write-Host "Created Hudu public ITGlue articles report: $($publicArticleReportHuduArticle.url)" -ForegroundColor Cyan
    }
} catch {
    Write-Warning "Failed to create or update the Hudu public ITGlue articles report: $($_.Exception.Message)"
}
