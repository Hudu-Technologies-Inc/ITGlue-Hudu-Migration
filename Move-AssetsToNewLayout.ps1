
$workdir=$PSScriptRoot
[version]$RequiredPSversion = [version]"7.5.1"
$currentPSVersion = (Get-Host).Version
Write-Host "Required PowerShell version: $RequiredPSversion" -ForegroundColor Blue
if ($currentPSVersion -lt $RequiredPSversion) {Write-Host "PowerShell $RequiredPSversion or higher is required. You have $currentPSVersion." -ForegroundColor Red; exit 1} else {Write-Host "PowerShell version $currentPSVersion is compatible." -ForegroundColor Green}
. "$workdir\public\Init-OptionsAndLogs.ps1"
. "$workdir\public\CustomMapping.ps1"
$HuduAPIKey = $HuduAPIKey ?? $(Read-Host "Please enter Hudu API Key"); clear-host;
$HuduBaseURL = $HuduBaseURL ?? $(Read-Host "Please enter your Hudu base url")
Set-ExternalModulesInitialized
Write-Host "Getting some initial layout information."
$huduAssetLayouts = $(get-huduassetlayouts)

$sourceLayout = $(Select-ObjectFromList -objects $huduAssetLayouts -message "What will be your source layout?" -allownull $false)
$destLayout = $(Select-ObjectFromList -objects $($huduAssetLayouts | Where-Object {$_.id -ne $sourceLayout.id}) -message "What will be your dest layout?" -allownull $false)
Write-Host "Getting some initial source assets"
$sourceAssets =get-huduassets -LayoutId $sourceLayout.id
Write-Host "Getting some initial dest assets"
$destAssets =get-huduassets -LayoutId $destLayout.id
Write-Host "Getting some initial relations data"
$relations =get-hudurelations
$MigrationName = "Migrate-$($sourcelayout.name)-$($destlayout.name)"

$result = Set-AssetsToHuduLayout -desiredMapFileName "$MigrationName.json" `
                       -sourceAssets $sourceAssets -destAssets $destAssets `
                       -sourceassetlayout $sourceLayout -destLayout $destLayout `
                       -PromptOnMatch $(Selec-ObjectFromList -objects @($true,$false) -message "Would you like to be prompted of a match is found in the destination layout?") `
                       -allRelations $relations
$result | ConvertTo-Json -depth 99 | Out-File "$MigrationName.results.json"