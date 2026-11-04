############################## Update ITGlue URLs on All Areas to Hudu #######################

Reset-HuduURLReplacementLookup
$null = Initialize-HuduURLReplacementLookup -Force

$UpdatePasswords = $MatchedPasswords | Where-Object { Test-ITGlueURLReplacementCandidate -Content ([string]$_.HuduObject.description) }
$UpdateAssetPasswords = $MatchedAssetPasswords | Where-Object { Test-ITGlueURLReplacementCandidate -Content ([string]$_.ITGObject.attributes.notes) }
$UpdateCompanyNotes = $MatchedCompanies | Where-Object { Test-ITGlueURLReplacementCandidate -Content ([string]$_.HuduCompanyObject.notes) }

Write-Host "Article content link replacement will run after attachments are uploaded so IT Glue URLs, hard-coded images, attachment links, and hosted image anchors can be applied in one article update." -ForegroundColor Cyan

Write-Host "Asset rich text link replacement will run after attachments are uploaded so IT Glue links, image links, and attachment links can be handled in one asset update." -ForegroundColor Cyan

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
$companyNotesUpdated | ConvertTo-Json -depth 100 |Out-file "$MigrationLogs\ReplacedCompaniesURL.json"
