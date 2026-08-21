function Start-ITGlueToHuduURLRewrite {

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
$UpdateArticles = $ArticleContentCandidates | Where-Object {
    $ArticleContent = Get-HuduArticleLocalContent -Article $_
    if ($null -eq $ArticleContent) {
        Write-Warning "Skipping article '$($_.name)' because local article HTML was not found at '$($_.LocalContentPath)'."
        return $false
    }

    Test-ITGlueURLReplacementCandidate -Content $ArticleContent
}
$UpdateAssets = $MatchedAssets | Where-Object {$_.HuduObject.fields.value -like "*$ITGURL*"}
$UpdatePasswords = $MatchedPasswords | Where-Object { Test-ITGlueURLReplacementCandidate -Content ([string]$_.HuduObject.description) }
$UpdateAssetPasswords = $MatchedAssetPasswords | Where-Object {
    (Test-ITGlueURLReplacementCandidate -Content ([string]$_.HuduObject.description)) -or
    (Test-ITGlueURLReplacementCandidate -Content ([string]$_.ITGObject.attributes.notes))
}
$UpdateCompanyNotes = $MatchedCompanies | Where-Object { Test-ITGlueURLReplacementCandidate -Content ([string]$_.HuduCompanyObject.notes) }


# Articles
$articlesUpdated = @()
foreach ($articleFound in $UpdateArticles) {
    $ArticleContent = Get-HuduArticleLocalContent -Article $articleFound
    if ($NewContent = Update-StringWithCaptureGroups -inputString $ArticleContent -pattern $RichRegexPatternToMatchSansAssets -type "rich") {
        $NewContent = Update-StringWithCaptureGroups -inputString $NewContent -pattern $RichRegexPatternToMatchWithAssets -type "rich"
	$NewContent = Update-StringWithCaptureGroups -inputString $NewContent -pattern $RichDocLocatorUrlPatternToMatch -type "rich"
    $NewContent = Update-StringWithCaptureGroups -inputString $NewContent -pattern $RichDocLocatorRelativeURLPatternToMatch -type "rich"
        Write-Host "Updating Article $($articleFound.name) with replaced Content" -ForegroundColor 'Green'
	try {
        $ArticleId = $articleFound.HuduID ?? $articleFound.id
        $ArticlePost = Set-HuduArticle -Name $articleFound.name -id $ArticleId -Content $NewContent -ErrorAction Stop
        $articlesUpdated = $articlesUpdated + @{"status" = "replaced"; "article_id" = $ArticleId; "original_article" = $articleFound; "updated_article" = ($ArticlePost.article.id ?? $ArticlePost.id ?? $ArticleId)}
	} catch { $articlesUpdated = $articlesUpdated + @{"status" = "failed"; "original_article" = $articleFound; "attempted_changes" = $newContent} }
        }
    else {
        Write-Warning "Article $($articleFound.HuduID ?? $articleFound.id) found ITGlue URL but didn't match"
        $articlesUpdated = $articlesUpdated + @{"status" = "clean"; "original_article" = $articleFound}
    }
}

$articlesUpdated | ConvertTo-Json -depth 100 |Out-file "$MigrationLogs\ReplacedArticlesURL.json"
Write-TimedMessage -Timeout 3 -Message "Snapshot Point: Article URLs Replaced. Continue?"  -DefaultResponse "continue to Assets, please."

# Assets
$assetsUpdated = @()
foreach ($assetFound in $UpdateAssets.HuduObject) {
    $replacedStatus = 'clean'
    $customFields = @()

    foreach ($field in $assetFound.fields) {
        # Convert the caption to snake_case to match API expectations for 2.37.1
        $label = ($field.caption -replace '[^\w\s]', '') -replace '\s+', '_' | ForEach-Object { $_.ToLower() }

        if ($label -in @('itglue_url', 'itglue_id', 'imported_from_itglue') -and $field.value -like "*$ITGURL*") {
            $NewContent = Update-StringWithCaptureGroups -inputString $field.value -pattern $RichRegexPatternToMatchSansAssets -type "rich"
            $NewContent = Update-StringWithCaptureGroups -inputString $NewContent -pattern $RichRegexPatternToMatchWithAssets -type "rich"

            if ($NewContent -and $NewContent -ne $field.value) {
                Write-Host "Replacing Asset $($assetFound.name) field $($field.caption) with updated content" -ForegroundColor 'Red'
                $customFields += @{ $label = $NewContent }
                $replacedStatus = 'replaced'
            } else {
                $customFields += @{ $label = $field.value }
            }
        } else {
            # For other fields, preserve existing value (optional)
            $customFields += @{ $label = $field.value }
        }
    }

    if ($replacedStatus -eq 'replaced') {
        Write-Host "Updating Asset $($assetFound.name) with new custom_fields array" -ForegroundColor 'Green'
        $AssetPost = Invoke-HuduRequest -Method PUT -Resource "/api/v1/companies/$($assetFound.company_id)/assets/$($assetFound.id)" -Body @{
            name              = $assetFound.name
            asset_layout_id   = $assetFound.asset_layout_id
            custom_fields     = $customFields
        }
    }

    $assetsUpdated += @{
        status         = $replacedStatus
        original_asset = $originalAsset
        updated_asset  = $AssetPost.asset
    }
}
$assetsUpdated | ConvertTo-Json -depth 100 |Out-file "$MigrationLogs\ReplacedAssetsURL.json"
Write-TimedMessage -Timeout 3 -Message  "Snapshot Point: Assets URLs Replaced. Continue?" -DefaultResponse "continue to Passwords Matching, please."

# Passwords
$passwordsUpdated = @()
foreach ($passwordFound in $UpdatePasswords.HuduObject) {
    $NewContent = Convert-ITGlueLinksToHudu -Content $passwordFound.description -Type "plain"
    if ($NewContent -and $NewContent -ne $passwordFound.description) {
        Write-Host "Updating Password $($passwordFound.name) with updated description" -ForegroundColor 'Green'
        $passwordsUpdated = $passwordsUpdated + @{"original_password" = $passwordFound; "updated_password" = (Set-HuduPassword -id $passwordFound.id -Description $NewContent).asset_password}
    }
}
$passwordsUpdated | ConvertTo-Json -depth 100 |Out-file "$MigrationLogs\ReplacedPasswordsURL.json"
Write-TimedMessage -Timeout 3 -Message  "Snapshot Point: Password URLs Replaced. Continue?"  -DefaultResponse "continue to Asset Passwords Matching, please."

# Asset Passwords
$assetPasswordsUpdated = @()
foreach ($passwordFound in $UpdateAssetPasswords) {
    $passwordFound = Get-HuduPasswords -id $passwordFound.HuduID
    $NewContent = Convert-ITGlueLinksToHudu -Content $passwordFound.description -Type "plain"
    if ($NewContent -and $NewContent -ne $passwordFound.description)   {
        Write-Host "Updating Asset Password $($passwordFound.name) with updated description" -ForegroundColor 'Green'
        $assetPasswordsUpdated = $assetPasswordsUpdated + @{"original_password" = $passwordFound; "updated_password" = (Set-HuduPassword -Id $passwordFound.id -Description $NewContent).asset_password}
    }
    
}
$assetPasswordsUpdated | ConvertTo-Json -depth 100 |Out-file "$MigrationLogs\ReplacedAssetPasswordsURL.json"
Write-TimedMessage -Timeout 3 -Message  "Snapshot Point: Asset Passwords URLs Replaced. Continue?"  -DefaultResponse "continue to Company Notes, please."

# Company Notes
$companyNotesUpdated = @()
foreach ($companyFound in $UpdateCompanyNotes.HuduCompanyObject) {
    $NewContent = Convert-ITGlueLinksToHudu -Content $companyFound.notes -Type "rich"
    if ($NewContent -and $NewContent -ne $companyFound.notes) {
        Write-Host "Updating Company $($companyFound.name) with updated notes" -ForegroundColor 'Green'
        $companyNotesUpdated = $companyNotesUpdated + @{"original_company" = $companyFound; "updated_company" = (Set-HuduCompany -id $companyFound.id -Notes $NewContent).company}
    }

}
return $companyNotesUpdated
}
