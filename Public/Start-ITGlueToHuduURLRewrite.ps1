function Start-ITGlueToHuduURLRewrite {

$UpdateArticles = (Get-HuduArticles | Where-Object {$_.content -like "*$ITGURL*"})
$UpdateAssets = $MatchedAssets | Where-Object {$_.HuduObject -and $_.HuduObject.fields}
$UpdatePasswords = $MatchedPasswords | Where-Object {$_.HuduObject.description -like "*$ITGURL*"}
$UpdateAssetPasswords = $MatchedAssetPasswords | Where-Object {$_.ITGObject.attributes.notes -like "*$ITGURL*"}
$UpdateCompanyNotes = $MatchedCompanies | Where-Object {$_.HuduCompanyObject.notes -like "*$ITGURL*"}


# Articles
$articlesUpdated = @()
foreach ($articleFound in $UpdateArticles) {
    if ($NewContent = Update-StringWithCaptureGroups -inputString $articleFound.content -pattern $RichRegexPatternToMatchSansAssets -type "rich") {
        $NewContent = Update-StringWithCaptureGroups -inputString $NewContent -pattern $RichRegexPatternToMatchWithAssets -type "rich"
	$NewContent = Update-StringWithCaptureGroups -inputString $NewContent -pattern $RichDocLocatorUrlPatternToMatch -type "rich"
 	$NewContent = Update-StringWithCaptureGroups -inputString $NewContent -pattern $RichDocLocatorRelativeURLPatternToMatch -type "rich"
        Write-Host "Updating Article $($articleFound.name) with replaced Content" -ForegroundColor 'Green'
	try {
        $ArticlePost = Set-HuduArticle -Name $articleFound.name -id $articleFound.id -Content $NewContent -ErrorAction Stop
        $articlesUpdated = $articlesUpdated + @{"status" = "replaced"; "original_article" = $articleFound; "updated_article" = $ArticlePost}
	} catch { $articlesUpdated = $articlesUpdated + @{"status" = "failed"; "original_article" = $articleFound; "attempted_changes" = $newContent} }
        }
    else {
        Write-Warning "Article $articleFound.id found ITGlue URL but didn't match"
        $articlesUpdated = $articlesUpdated + @{"status" = "clean"; "original_article" = $articleFound}
    }
}

$articlesUpdated | ConvertTo-Json -depth 100 |Out-file "$MigrationLogs\ReplacedArticlesURL.json"
Write-TimedMessage -Timeout 3 -Message "Snapshot Point: Article URLs Replaced. Continue?"  -DefaultResponse "continue to Assets, please."

# Assets
$assetsUpdated = @()
$AssetLayoutCache = @{}
foreach ($assetFound in $UpdateAssets.HuduObject) {
    $originalAsset = $assetFound
    $AssetPost = $null
    $replacedStatus = 'clean'
    $customFields = @()

    foreach ($field in $assetFound.fields) {
        $FieldEntry = Get-HuduAssetFieldEntry -Field $field
        $label = $FieldEntry.Key
        $FieldValue = $FieldEntry.Value
        if ([string]::IsNullOrWhiteSpace($label)) { continue }

        if (Test-HuduAssetFieldIsRichText -Asset $assetFound -Field $field -AssetLayoutCache $AssetLayoutCache) {
            $NewContent = Update-StringWithCaptureGroups -inputString "$FieldValue" -pattern $RichRegexPatternToMatchSansAssets -type "rich"
            $NewContent = Update-StringWithCaptureGroups -inputString $NewContent -pattern $RichRegexPatternToMatchWithAssets -type "rich"
            $NewContent = Update-StringWithCaptureGroups -inputString $NewContent -pattern $RichDocLocatorUrlPatternToMatch -type "rich"
            $NewContent = Update-StringWithCaptureGroups -inputString $NewContent -pattern $RichDocLocatorRelativeURLPatternToMatch -type "rich"

            if ($NewContent -and $NewContent -ne $FieldValue) {
                Write-Host "Replacing Asset $($assetFound.name) field $($FieldEntry.Label) with updated content" -ForegroundColor 'Red'
                $customFields += @{ $label = $NewContent }
                $replacedStatus = 'replaced'
            }
        }
    }

    if ($replacedStatus -eq 'replaced') {
        Write-Host "Updating Asset $($assetFound.name) with changed rich text field(s)" -ForegroundColor 'Green'
        $AssetPost = set-huduasset -companyId $assetFound.company_id -ID $assetFound.id -fields @($customFields)
        $assetPost = $assetPost.asset ?? $assetPost   
    }

    $assetsUpdated += @{
        status         = $replacedStatus
        original_asset = $originalAsset
        updated_asset  = $AssetPost
    }
}
$assetsUpdated | ConvertTo-Json -depth 100 |Out-file "$MigrationLogs\ReplacedAssetsURL.json"
Write-TimedMessage -Timeout 3 -Message  "Snapshot Point: Assets URLs Replaced. Continue?" -DefaultResponse "continue to Passwords Matching, please."

# Passwords
$passwordsUpdated = @()
foreach ($passwordFound in $UpdatePasswords.HuduObject) {
    $NewContent = Update-StringWithCaptureGroups -inputString $passwordFound.description -pattern $TextRegexPatternToMatchSansAssets -type "plain"
    $NewContent = Update-StringWithCaptureGroups -inputString $NewContent -pattern $TextRegexPatternToMatchWithAssets -type "plain"
    if ($NewContent) {
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
    $NewContent = Update-StringWithCaptureGroups -inputString $passwordFound.description -pattern $TextRegexPatternToMatchSansAssets -type "plain"
    $NewContent = Update-StringWithCaptureGroups -inputString $NewContent -pattern $TextRegexPatternToMatchWithAssets -type "plain"
    if ($NewContent)   {
        Write-Host "Updating Asset Password $($passwordFound.name) with updated description" -ForegroundColor 'Green'
        $assetPasswordsUpdated = $assetPasswordsUpdated + @{"original_password" = $passwordFound; "updated_password" = (Set-HuduPassword -Id $passwordFound.id -Description $NewContent).asset_password}
    }
    
}
$assetPasswordsUpdated | ConvertTo-Json -depth 100 |Out-file "$MigrationLogs\ReplacedAssetPasswordsURL.json"
Write-TimedMessage -Timeout 3 -Message  "Snapshot Point: Asset Passwords URLs Replaced. Continue?"  -DefaultResponse "continue to Company Notes, please."

# Company Notes
$companyNotesUpdated = @()
foreach ($companyFound in $UpdateCompanyNotes.HuduCompanyObject) {
    $NewContent = Update-StringWithCaptureGroups -inputString $companyFound.notes -pattern $RichRegexPatternToMatchSansAssets -type "rich"
    $NewContent = Update-StringWithCaptureGroups -inputString $NewContent -pattern $RichRegexPatternToMatchWithAssets -type "rich"
    if ($NewContent) {
        Write-Host "Updating Company $($companyFound.name) with updated notes" -ForegroundColor 'Green'
        $companyNotesUpdated = $companyNotesUpdated + @{"original_company" = $companyFound; "updated_company" = (Set-HuduCompany -id $companyFound.id -Notes $NewContent).company}
    }

}
return $companyNotesUpdated
}
