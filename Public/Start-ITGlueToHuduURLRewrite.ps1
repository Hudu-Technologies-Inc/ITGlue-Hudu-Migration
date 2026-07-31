function Start-ITGlueToHuduURLRewrite {

Reset-HuduURLReplacementLookup
$null = Initialize-HuduURLReplacementLookup -Force
if (-not $AllFields -and -not [string]::IsNullOrWhiteSpace([string]$MigrationLogs) -and (Test-Path "$MigrationLogs\AssetLayoutsFields.json")) {
    $AllFields = Get-Content "$MigrationLogs\AssetLayoutsFields.json" -Raw | ConvertFrom-Json -Depth 100
}
$RichTextFieldsByLayout = New-HuduRichTextFieldLookup -LayoutFields $AllFields

$UpdateArticles = Get-HuduArticles | Where-Object { Test-ITGlueURLReplacementCandidate -Content ([string]$_.content) }
$UpdateAssets = $MatchedAssets | Where-Object {
    $assetLayoutId = $_.HuduObject.asset_layout_id
    @($_.HuduObject.fields | Where-Object {
        (Test-HuduAssetFieldIsRichText -Field $_ -RichTextFieldLookup $RichTextFieldsByLayout -AssetLayoutId $assetLayoutId) -and
        -not (Test-HuduAssetFieldIsITGlueMetadata -Field $_) -and
        (Test-ITGlueURLReplacementCandidate -Content ([string]$_.value))
    }).Count -gt 0
}
$UpdatePasswords = $MatchedPasswords | Where-Object { Test-ITGlueURLReplacementCandidate -Content ([string]$_.HuduObject.description) }
$UpdateAssetPasswords = $MatchedAssetPasswords | Where-Object {
    (Test-ITGlueURLReplacementCandidate -Content ([string]$_.HuduObject.description)) -or
    (Test-ITGlueURLReplacementCandidate -Content ([string]$_.ITGObject.attributes.notes))
}
$UpdateCompanyNotes = $MatchedCompanies | Where-Object { Test-ITGlueURLReplacementCandidate -Content ([string]$_.HuduCompanyObject.notes) }


# Articles
$articlesUpdated = @()
foreach ($articleFound in $UpdateArticles) {
    $NewContent = Convert-ITGlueLinksToHudu -Content $articleFound.content -Type "rich"
    if ($NewContent -and $NewContent -ne $articleFound.content) {
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
foreach ($assetFound in $UpdateAssets.HuduObject) {
    $customFields = @()
    $replacementSets = @()

    foreach ($field in $assetFound.fields) {
        if (-not (Test-HuduAssetFieldIsRichText -Field $field -RichTextFieldLookup $RichTextFieldsByLayout -AssetLayoutId $assetFound.asset_layout_id)) {
            continue
        }

        if (Test-HuduAssetFieldIsITGlueMetadata -Field $field) {
            continue
        }

        $fieldContent = [string]$field.value
        if (-not (Test-ITGlueURLReplacementCandidate -Content $fieldContent)) {
            continue
        }

        $NewContent = Convert-ITGlueLinksToHudu -Content $fieldContent -Type "rich"
        if (-not ($NewContent -and $NewContent -ne $fieldContent)) {
            continue
        }

        $label = Get-HuduAssetFieldLabel -Field $field
        if ([string]::IsNullOrWhiteSpace([string]$label)) {
            Write-Warning "Skipping changed rich text field on asset $($assetFound.name) because Hudu did not return a field label."
            continue
        }

        Write-Host "Replacing Asset $($assetFound.name) field $label with updated content" -ForegroundColor 'Red'
        $customFields += @{ $label = $NewContent }
        $replacementSets += [pscustomobject]@{
            Field = $label
            Type  = 'ITGlueLinks'
        }
    }

    if ($customFields.Count -lt 1) {
        $assetsUpdated += @{
            status           = 'clean'
            original_asset   = $assetFound
            updated_asset    = $null
            replacement_sets = @()
        }
        continue
    }

    Write-Host "Updating Asset $($assetFound.name) with rich text link replacement(s)" -ForegroundColor 'Green'
    try {
        $AssetPost = Set-HuduAsset -Id $assetFound.id -CompanyId $assetFound.company_id -Fields $customFields
        $assetsUpdated += @{
            status           = 'replaced'
            original_asset   = $assetFound
            updated_asset    = $AssetPost.asset ?? $AssetPost
            replacement_sets = $replacementSets
        }
    } catch {
        $assetsUpdated += @{
            status            = 'failed'
            original_asset    = $assetFound
            attempted_fields  = $customFields
            replacement_sets  = $replacementSets
            error             = $_.Exception.Message
        }
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
