# Main settings load
. $PSScriptRoot\Initialize-Module.ps1 -InitType 'Full'
# Use this to set the context of the script runs
$FirstTimeLoad = 1
############################### Functions ###############################
# Import ImageMagick for Invoke-ImageTest Function (Disabled)
 . $PSScriptRoot\Private\Initialize-ImageMagik.ps1
# Used to determine if a file is an image and what type of image
. $PSScriptRoot\Private\Invoke-ImageTest.ps1
# Confirm Object Import
. $PSScriptRoot\Private\Confirm-Import.ps1
# Matches items from IT Glue to Hudu and creates new items in Hudu
. $PSScriptRoot\Private\Import-Items.ps1
# Select Item Import Mode
. $PSScriptRoot\Private\Get-ImportMode.ps1
# Get Configurations Option
. $PSScriptRoot\Private\Get-ConfigurationsImportMode.ps1
# Get Flexible Asset Layout Option
. $PSScriptRoot\Private\Get-FlexLayoutImportMode.ps1
# Fetch Items from ITGlue
. $PSScriptRoot\Private\Import-ITGlueItems.ps1
# Find migrated items
. $PSScriptRoot\Private\Find-MigratedItem.ps1
# Lookup table to upgrade from Font Awesome 4 to 5
. $PSScriptRoot\Private\Get-FontAwesomeMap.ps1
$FontAwesomeUpgrade = Get-FontAwesomeMap
# Add Replace URL functions
. $PSScriptRoot\Private\ConvertTo-HuduURL.ps1
# Add Hudu Relations Function
. $PSScriptRoot\Public\Add-HuduRelation.ps1
# Add Timed (Noninteractive) Messages Helper
. $PSScriptRoot\Public\Write-TimedMessage.ps1
############################### End of Functions ###############################
###################### Initial Setup and Confirmations ###############################
Write-Host "#######################################################" -ForegroundColor Green
Write-Host "#                                                     #" -ForegroundColor Green
Write-Host "#          IT Glue to Hudu Migration Script           #" -ForegroundColor Green
Write-Host "#                                                     #" -ForegroundColor Green
Write-Host "#          Version: 2.0  -Beta                        #" -ForegroundColor Green
Write-Host "#          Date: 02/07/2023                           #" -ForegroundColor Green
Write-Host "#                                                     #" -ForegroundColor Green
Write-Host "#          Author: Luke Whitelock                     #" -ForegroundColor Green
Write-Host "#                  https://mspp.io                    #" -ForegroundColor Green
Write-Host "#          Contributors: John Duprey                  #" -ForegroundColor Green
Write-Host "#                        Mendy Green                  #" -ForegroundColor Green
Write-Host "#                  https://MSPGeek.org                #" -ForegroundColor Green
Write-Host "#                  https://mendyonline.com            #" -ForegroundColor Green
Write-Host "#                                                     #" -ForegroundColor Green
Write-Host "#######################################################" -ForegroundColor Green
Write-Host "# Note: This is an unofficial script, please do not   #" -ForegroundColor Green
Write-Host "# contact Hudu support if you run into issues.        #" -ForegroundColor Green
Write-Host "# For support please visit the Hudu Sub-Reddit:       #" -ForegroundColor Green
Write-Host "# https://www.reddit.com/r/hudu/                      #" -ForegroundColor Green
Write-Host "# The #v-hudu channel on the MSPGeek Slack/Discord:   #" -ForegroundColor Green
Write-Host "# https://join.mspgeek.com/                           #" -ForegroundColor Green
Write-Host "# Or log an issue in the Github Respository:          #" -ForegroundColor Green
Write-Host "# https://github.com/lwhitelock/ITGlue-Hudu-Migration #" -ForegroundColor Green
Write-Host "#######################################################" -ForegroundColor Green
Write-Host " Instructions:                                       " -ForegroundColor Green
Write-Host " Please view Luke's blog post:                       " -ForegroundColor Green
Write-Host " https://mspp.io/automated-it-glue-to-hudu-migration-script/     " -ForegroundColor Green
Write-Host " for detailed instructions                           " -ForegroundColor Green
Write-Host "#######################################################" -ForegroundColor Green
Write-Host "# Please keep ALL COPIES of the Migration Logs folder. This can save you." -ForegroundColor Gray
Write-Host "# Please DO NOT CHANGE ANYTHING in the Migration Logs folder. This can save you." -ForegroundColor Gray
# CMA
Write-Host "######################################################" -ForegroundColor Red
Write-Host "Have you taken a full backup of your Hudu Environment?" -ForegroundColor Red
Write-Host "Things could go wrong and you need to be able to " -ForegroundColor Red
Write-Host "recover to the state from before the script was run" -ForegroundColor Red
Write-Host "######################################################" -ForegroundColor Red
Write-Host "######################################################" -ForegroundColor Red
Write-Host "This Script has the potential to ruin your Hudu environment" -ForegroundColor Red
Write-Host "It is unofficial and you run it entirely at your own risk" -ForegroundColor Red
Write-Host "You accept full responsibility for any problems caused by running it" -ForegroundColor Red
Write-Host "######################################################" -ForegroundColor Red
$backups=$(if ($true -eq $NonInteractive) {"Y"} else {Read-Host "Y/n"})
$ScriptStartTime = $(Get-Date -Format "o")
if ($backups -ne "Y" -or $backups -ne "y") {
    Write-Host "Please take a backup and run the script again"
    exit 1
}
if ((get-host).version.major -ne 7) {
    Write-Host "Powershell 7 Required" -foregroundcolor Red
    exit 1
}
#Get the Hudu API Module if not installed
if ((Get-Module -ListAvailable -Name HuduAPI).version -ge '2.4.4') {
    Import-Module HuduAPI
} else {
    Install-Module HuduAPI -MinimumVersion 2.4.5 -Scope CurrentUser
    Import-Module HuduAPI
}
#Login to Hudu
New-HuduAPIKey $HuduAPIKey
New-HuduBaseUrl $HuduBaseDomain
# Check we have the correct version
$RequiredHuduVersion = "2.1.5.9"
$HuduAppInfo = Get-HuduAppInfo
If ([version]$HuduAppInfo.version -lt [version]$RequiredHuduVersion) {
    Write-Host "This script requires at least version $RequiredHuduVersion. Please update your version of Hudu and run the script again. Your version is $($HuduAppInfo.version)"
    exit 1
}
try {
    remove-module ITGlueAPI -ErrorAction SilentlyContinue
} catch {
}
#Grabbing ITGlue Module and installing.
If (Get-Module -ListAvailable -Name "ITGlueAPIv2") { 
    Import-module ITGlueAPIv2 
} Else { 
    Install-Module ITGlueAPIv2 -Force
    Import-Module ITGlueAPIv2
}
# override this method, since it's retry method fails
. $PSScriptRoot\Public\Invoke-HuduRequest.ps1
#Settings IT-Glue logon information
Add-ITGlueBaseURI -base_uri $ITGAPIEndpoint
Add-ITGlueAPIKey $ITGKey
# Check if we have a logs folder
if (Test-Path -Path "$MigrationLogs") {
    if ($ResumePrevious -eq $true) {
        Write-Host "A previous attempt has been found job will be resumed from the last successful section" -ForegroundColor Green
        $ResumeFound = $true
    } else {
        Write-Host "A previous attempt has been found, resume is disabled so this will be lost, if you haven't reverted to a snapshot, a resume is recommended" -ForegroundColor Red
        Write-TimedMessage -Timeout 12 -Message "Press any key to continue or ctrl + c to quit and edit the ResumePrevious setting" -DefaultResponse "proceed with new migration, do not resume"
        $ResumeFound = $false
    }
} else {
    Write-Host "No previous runs found creating log directory"
    $null = New-Item "$MigrationLogs" -ItemType "directory"
    $ResumeFound = $false
}
# Setup some variables
$ManualActions = [System.Collections.ArrayList]@()
############################### Companies ###############################
#Grab existing companies in Hudu
$HuduCompanies = Get-HuduCompanies
if ($ResumeFound -eq $true -and (Test-Path "$MigrationLogs\Companies.json")) {
    Write-Host "Loading Previous Companies Migration"
    $MatchedCompanies = Get-Content "$MigrationLogs\Companies.json" -raw | Out-String | ConvertFrom-Json
} else {
    . .\Public\Start-Companies.ps1
    # update huducompanies & Save the results to resume from if needed
    $CompaniesToMigrate = $MatchedCompanies | Sort-Object CompanyName | Where-Object { $_.Matched -eq $true }
    $HuduCompanies = Get-HuduCompanies
    $MatchedCompanies | ConvertTo-Json -depth 100 | Out-File "$MigrationLogs\Companies.json"
    Write-TimedMessage -Timeout 3 -Message "Snapshot Point: Companies Migrated Continue?"  -DefaultResponse "continue to Locations, please."
}
############################### Locations ###############################
#Check for Location Resume
if ($ResumeFound -eq $true -and (Test-Path "$MigrationLogs\Locations.json")) {
    Write-Host "Loading Previous Locations Migration"
    $MatchedLocations = Get-Content "$MigrationLogs\Locations.json" -raw | Out-String | ConvertFrom-Json -depth 100
} else {
    . .\Public\Start-Locations.ps1
    $MatchedLocations = Import-Items @LocImportSplat
    # Save the results to resume from if needed
    $MatchedLocations | ConvertTo-Json -depth 100 | Out-File "$MigrationLogs\Locations.json"
    Write-TimedMessage -Timeout 3 -Message "Snapshot Point: Locations Migrated Continue?"  -DefaultResponse "continue to Websites, please."
}
############################### Websites ###############################
#Check for Website Resume
if ($ResumeFound -eq $true -and (Test-Path "$MigrationLogs\Websites.json")) {
    Write-Host "Loading Previous Websites Migration"
    $MatchedWebsites = Get-Content "$MigrationLogs\Websites.json" -raw | Out-String | ConvertFrom-Json
} else {
    . .\Public\Start-Websites.ps1
    # Save the results to resume from if needed
    $MatchedWebsites | ConvertTo-Json -depth 100 | Out-File "$MigrationLogs\Websites.json"
    Write-TimedMessage -Timeout 3 -Message  "Snapshot Point: Websites Migrated Continue?"  -DefaultResponse "continue to Configurations, please."
}
if ($null -eq $UnmappedWebsiteCount -or $UnmappedWebsiteCount -eq 0) {
    Write-Host "All $MigrationName matched, no migration required" -foregroundcolor green
}
############################### Configurations ###############################
$ConfigMigrationName = "Configurations"
$ConfigImportAssetLayoutName = "Configurations"
	
#Check for Configuration Resume
if ($ResumeFound -eq $true -and (Test-Path "$MigrationLogs\Configurations.json")) {
    Write-Host "Loading Previous Configurations Migration"
    $MatchedConfigurations = Get-Content "$MigrationLogs\Configurations.json" -raw | Out-String | ConvertFrom-Json -depth 100
} else {
    . .\Public\Start-Configurations.ps1
    # Save the results to resume from if needed
    $MatchedConfigurations | ConvertTo-Json -depth 100 | Out-File "$MigrationLogs\Configurations.json"
    Write-TimedMessage -Timeout 3 -Message "Snapshot Point: Configurations Migrated Continue?"  -DefaultResponse "continue to Contacts, please."
}
############################### Contacts ###############################
#Check for Location Resume
if ($ResumeFound -eq $true -and (Test-Path "$MigrationLogs\Contacts.json")) {
    Write-Host "Loading Previous Contacts Migration"
    $MatchedContacts = Get-Content "$MigrationLogs\Contacts.json" -raw | Out-String | ConvertFrom-Json -depth 100
} else {
    . .\Public\Start-Contacts.ps1
    # Save the results to resume from if needed
    $MatchedContacts | ConvertTo-Json -depth 100 | Out-File "$MigrationLogs\Contacts.json"
    Write-TimedMessage -Timeout 3 -Message "Snapshot Point: Contacts Migrated Continue?"  -DefaultResponse "continue to Flexible Asset Layouts, please."
}
	
############################### Flexible Asset Layouts and Assets ###############################
#Check for Layouts Resume
if ($ResumeFound -eq $true -and (Test-Path "$MigrationLogs\AssetLayouts.json")) {
    Write-Host "Loading Previous Asset Layouts Migration"
    $MatchedLayouts = Get-Content "$MigrationLogs\AssetLayouts.json" -raw | Out-String | ConvertFrom-Json -depth 100
    $AllFields = Get-Content "$MigrationLogs\AssetLayoutsFields.json" -raw | Out-String | ConvertFrom-Json -depth 100
} else {
    Write-Host "Fetching Flexible Asset Layouts from IT Glue" -ForegroundColor Green
    $FlexLayoutSelect = { (Get-ITGlueFlexibleAssetTypes -page_size 1000 -page_number $i -include related_items).data }
    $FlexLayouts = Import-ITGlueItems -ItemSelect $FlexLayoutSelect
    $HuduLayouts = Get-HuduAssetLayouts
    $AllFields = [System.Collections.ArrayList]@()
    . .\Public\Start-FlexAssetLayouts.ps1
    $AllFields | ConvertTo-Json -depth 100 | Out-File "$MigrationLogs\AssetLayoutsFields.json"
    $MatchedLayouts | ConvertTo-Json -depth 100 | Out-File "$MigrationLogs\AssetLayouts.json"
    Write-TimedMessage -Timeout 3 -Message "Snapshot Point: Layouts Migrated Continue?"  -DefaultResponse "continue to Flexible Assets, please."
}
############################### Flexible Assets ###############################
#Check for Assets Resume
if ($ResumeFound -eq $true -and (Test-Path "$MigrationLogs\Assets.json")) {
    Write-Host "Loading Previous Asset Migration"
    $MatchedAssets = Get-Content "$MigrationLogs\Assets.json" -raw | Out-String | ConvertFrom-Json -depth 100
    $MatchedAssetPasswords = Get-Content "$MigrationLogs\AssetPasswords.json" -raw | Out-String | ConvertFrom-Json -depth 100
    $RelationsToCreate = [System.Collections.ArrayList](Get-Content "$MigrationLogs\RelationsToCreate.json" -raw | Out-String | ConvertFrom-Json -depth 100)
    $ManualActions = [System.Collections.ArrayList](Get-Content "$MigrationLogs\ManualActions.json" -raw | Out-String | ConvertFrom-Json -depth 100)
} else {
    # Load raw passwords for embedded fields and future use
    $ITGPasswordsRaw = Import-CSV -Path "$ITGLueExportPath\passwords.csv"
    . .\Public\Start-PasswordsImport.ps1
    $MatchedAssets | ConvertTo-Json -depth 100 | Out-File "$MigrationLogs\Assets.json"
    $MatchedAssetPasswords | ConvertTo-Json -depth 100 | Out-File "$MigrationLogs\AssetPasswords.json"
    $ManualActions | ConvertTo-Json -depth 100 | Out-File "$MigrationLogs\ManualActions.json"
    $RelationsToCreate | ConvertTo-Json -Depth 20 | Out-File "$MigrationLogs\RelationsToCreate.json"
    Write-TimedMessage -Timeout 3 -Message "Snapshot Point: Assets Migrated Continue?" -DefaultResponse "continue to Documents/Articles, please."
}
############################### Documents / Articles ###############################
#Check for Article Resume
if ($ResumeFound -eq $true -and (Test-Path "$MigrationLogs\ArticleBase.json")) {
    Write-Host "Loading Article Migration"
    $MatchedArticles = Get-Content "$MigrationLogs\ArticleBase.json" -raw | Out-String | ConvertFrom-Json -depth 100
} else {
    . .\public\Start-ArticleStubs.ps1
    $MatchedArticles | ConvertTo-Json -depth 100 | Out-File "$MigrationLogs\ArticleBase.json"
    $ManualActions | ConvertTo-Json -depth 100 | Out-File "$MigrationLogs\ManualActions.json"
    Write-TimedMessage -Timeout 3 -Message "Snapshot Point: Stub Articles Created Continue?"  -DefaultResponse "continue to Document/Article Bodies, please."
}
############################### Documents / Articles Bodies ###############################
#Check for Articles Resume
if ($ResumeFound -eq $true -and (Test-Path "$MigrationLogs\Articles.json")) {
    Write-Host "Loading Article Content Migration"
    $MatchedArticles = Get-Content "$MigrationLogs\Articles.json" -raw | Out-String | ConvertFrom-Json -depth 100
} else {
    . .\Public\Start-ArticleContent.ps1
	$MatchedArticles | ConvertTo-Json -depth 100 | Out-File "$MigrationLogs\Articles.json"
    $ArticleErrors | ConvertTo-Json -depth 100 | Out-File "$MigrationLogs\ArticleErrors.json"
    $ManualActions | ConvertTo-Json -depth 100 | Out-File "$MigrationLogs\ManualActions.json"
    Write-TimedMessage -Timeout 3 -Message "Snapshot Point: Articles Created Continue?" -DefaultResponse "continue to Passwords, please."
}
############################### Passwords ###############################
#Check for Passwords Resume
if ($ResumeFound -eq $true -and (Test-Path "$MigrationLogs\Passwords.json")) {
    Write-Host "Loading Previous Paswords Migration"
    $MatchedPasswords = Get-Content "$MigrationLogs\Passwords.json" -raw | Out-String | ConvertFrom-Json
} else {
    Write-Host "Fetching Passwords from IT Glue" -ForegroundColor Green
    $PasswordSelect = { (Get-ITGluePasswords -page_size 1000 -page_number $i).data }
    $ITGPasswords = Import-ITGlueItems -ItemSelect $PasswordSelect -MigrationName 'Passwords'    
    . .\Public\Start-PasswordsMatching.ps1
    # Save the results to resume from if needed
    $MatchedPasswords | ConvertTo-Json -depth 100 | Out-File "$MigrationLogs\Passwords.json"
    $ManualActions | ConvertTo-Json -depth 100 | Out-File "$MigrationLogs\ManualActions.json"
    Write-TimedMessage -Timeout 3 -Message "Snapshot Point: Passwords Finished. Continue?"  -DefaultResponse "continue to Document/Article Updates, please."
}
############################## Update ITGlue URLs on All Areas to Hudu #######################
$UpdateArticles = (Get-HuduArticles | Where-Object {$_.content -like "*$ITGURL*"})
$UpdateAssets = $MatchedAssets | Where-Object {$_.HuduObject.fields.value -like "*$ITGURL*"}
$UpdatePasswords = $MatchedPasswords | Where-Object {$_.HuduObject.description -like "*$ITGURL*"}
$UpdateAssetPasswords = $MatchedAssetPasswords | Where-Object {$_.ITGObject.attributes.notes -like "*$ITGURL*"}
$UpdateCompanyNotes = $MatchedCompanies | Where-Object {$_.HuduCompanyObject.notes -like "*$ITGURL*"}
. .\Public\UpdateFields.ps1

$companyNotesUpdated | ConvertTo-Json -depth 100 |Out-file "$MigrationLogs\ReplacedCompaniesURL.json"
Write-TimedMessage -Timeout 3 -Message "Snapshot Point: Company Notes URLs Replaced. Continue?"  -DefaultResponse "continue to Manual Actions, please."
############################### Generate Manual Actions Report ###############################
$ManualActions | ForEach-Object {
    if ($_.Hudu_URL -notmatch "http:" -and $_.Hudu_URL -notmatch "https:") {
        $_.Hudu_URL = "$HuduBaseDomain$($_.Hudu_URL)"
    }
}
$Head = @"
<html>
<head>
<Title>Manual Actions Required Report</Title>
<link href="https://cdn.jsdelivr.net/npm/bootstrap@5.0.1/dist/css/bootstrap.min.css" rel="stylesheet" integrity="sha384-+0n0xVW2eSR5OomGNYDnhzAbDsOXxcvSN1TPprVMTNDbiYZCxYbOOl7+AMvyTG2x" crossorigin="anonymous">
<style type="text/css">
<!–
body {
    font-family: Verdana, Geneva, Arial, Helvetica, sans-serif;
}
h2{ clear: both; font-size: 100%;color:#354B5E; }
h3{
    clear: both;
    font-size: 75%;
    margin-left: 20px;
    margin-top: 30px;
    color:#475F77;
}
table{
	border-collapse: collapse;
	margin: 5px 0;
	font-size: 0.8em;
	font-family: sans-serif;
	min-width: 400px;
	box-shadow: 0 0 20px rgba(0, 0, 0, 0.15);
}
th, td {
	padding: 5px 5px;
	max-width: 400px;
	width:auto;
}
thead tr {
	background-color: #009879;
	color: #ffffff;
	text-align: left;
}
tr {
	border-bottom: 1px solid #dddddd;
}
tr:nth-of-type(even) {
	background-color: #f3f3f3;
}
->
</style>
</head>
<body>
<div style="padding:40px">
"@
$MigrationReport = @"
<h1> Migration Report </h1>
Started At: $ScriptStartTime <br />
Completed At: $(Get-Date -Format "o") <br />
$(($MatchedCompanies | Measure-Object).count) : Companies Migrated <br />
$(($MatchedLocations | Measure-Object).count) : Locations Migrated <br />
$(($MatchedWebsites | Measure-Object).count) : Websites Migrated <br />
$(($MatchedConfigurations | Measure-Object).count) : Configurations Migrated <br />
$(($MatchedContacts | Measure-Object).count) : Contacts Migrated <br />
$(($MatchedLayouts | Measure-Object).count) : Layouts Migrated <br />
$(($MatchedAssets | Measure-Object).count) : Assets Migrated <br />
$(($MatchedArticles | Measure-Object).count) : Articles Migrated <br />
$(($MatchedPasswords | Measure-Object).count) : Passwords Migrated <br />
If you found this script useful please consider sponsoring me at: <a href=https://github.com/sponsors/lwhitelock?frequency=one-time>https://github.com/sponsors/lwhitelock?frequency=one-time</a>
<hr>
<h1>Manual Actions Required Report</h1>
"@
$footer = "</div></body></html>"
$UniqueItems = $ManualActions | Select-Object huduid, hudu_url -unique
$ManualActionsReport = foreach ($item in $UniqueItems) {
    $items = $ManualActions | where-object { $_.huduid -eq $item.huduid -and $_.hudu_url -eq $item.Hudu_url }
    $core_item = $items | Select-Object -First 1
    $Header = "<h2><strong>Name: $($core_item.Document_Name)</strong></h2>
				<h2>Type: $($core_item.Asset_Type)</h2>
				<h2>Company: $($core_item.Company_name)</h2>
				<h2>Hudu URL: <a href=$($core_item.Hudu_URL)>$($core_item.Hudu_URL)</a></h2>
				<h2>IT Glue URL: <a href=$($core_item.ITG_URL)>$($core_item.ITG_URL)</a></h2>
				"
    $Actions = $items | Select-Object Field_Name, Notes, Action, Data | ConvertTo-Html -fragment | Out-String
    $OutHTML = "$Header $Actions <hr>"
    $OutHTML
}
$FinalHtml = "$Head $MigrationReport $ManualActionsReport $footer"
$FinalHtml | Out-File ManualActions.html
############################### End ###############################
Write-Host "#######################################################" -ForegroundColor Green
Write-Host "#                                                     #" -ForegroundColor Green
Write-Host "#        IT Glue to Hudu Migration Complete           #" -ForegroundColor Green
Write-Host "#                                                     #" -ForegroundColor Green
Write-Host "#######################################################" -ForegroundColor Green
Write-Host "Started At: $ScriptStartTime"
Write-Host "Completed At: $(Get-Date -Format "o")"
Write-Host "$(($MatchedCompanies | Measure-Object).count) : Companies Migrated" -ForegroundColor Green
Write-Host "$(($MatchedLocations | Measure-Object).count) : Locations Migrated" -ForegroundColor Green
Write-Host "$(($MatchedWebsites | Measure-Object).count) : Websites Migrated" -ForegroundColor Green
Write-Host "$(($MatchedConfigurations | Measure-Object).count) : Configurations Migrated" -ForegroundColor Green
Write-Host "$(($MatchedContacts | Measure-Object).count) : Contacts Migrated" -ForegroundColor Green
Write-Host "$(($MatchedLayouts | Measure-Object).count) : Layouts Migrated" -ForegroundColor Green
Write-Host "$(($MatchedAssets | Measure-Object).count) : Assets Migrated" -ForegroundColor Green
Write-Host "$(($MatchedArticles | Measure-Object).count) : Articles Migrated" -ForegroundColor Green
Write-Host "$(($MatchedPasswords | Measure-Object).count) : Passwords Migrated" -ForegroundColor Green
Write-Host "#######################################################" -ForegroundColor Green
Write-Host "Manual Actions report can be found in ManualActions.html in the folder the script was run from"
Write-Host "Logs of what was migrated can be found in the MigrationLogs folder"
Write-TimedMessage -Message "Press any key to view the manual actions report or Ctrl+C to end" -Timeout 120  -DefaultResponse "continue, view generative Manual Actions webpage, please."
Start-Process ManualActions.html
