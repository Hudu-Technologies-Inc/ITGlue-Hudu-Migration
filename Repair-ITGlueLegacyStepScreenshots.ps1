<#
.SYNOPSIS
    Optional repair of legacy ITGlue step screenshots in an existing migration.
.DESCRIPTION
    Run explicitly after article migration. Reads current Hudu article content,
    downloads missing screenshots by step ID, and replaces matched image tags.
    Removed tags can be restored at their original HTML locations when the saved
    source and current article structure agree. A pre-repair source snapshot is
    retained in logs/LegacyScreenshotSources for partial repairs and retries.
    Reuses the checklist $ITGlueJWT variable when -JWTAuthToken is omitted.
    A bearer JWT and a browser cookie session are different authentication methods.
    Uses that JWT to read signed screenshot URLs from the tenant's published
    document editor response when the public API omits them. Matches screenshots
    by step ID, including documents with repeated image filenames.
    Tokens, cookies, and signed query strings are never written to repair logs.
.PARAMETER JWTBaseUri
    Optional ITGlue API base from the browser request that issued the JWT.
    Defaults to the migration's regional API endpoint, like the checklist helpers.
.PARAMETER DownloadOnly
    Cache screenshots and record provenance without uploading or editing Hudu.
.EXAMPLE
    . .\Repair-ITGlueLegacyStepScreenshots.ps1 -DocumentId 58145 -JWTAuthToken $ITGlueJWT
.EXAMPLE
    . .\Repair-ITGlueLegacyStepScreenshots.ps1 -SettingsFile 'C:\migration\settings\settings.json' -JWTAuthToken $ITGlueJWT -DownloadOnly
.EXAMPLE
    . .\Repair-ITGlueLegacyStepScreenshots.ps1 -DocumentId 58145 -WebSession $ITGlueWebSession
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$SettingsFile,
    [Alias('ITGlueJWT')][string]$JWTAuthToken,
    [string]$JWTBaseUri,
    [string[]]$DocumentId = @(),
    [Microsoft.PowerShell.Commands.WebRequestSession]$WebSession,
    [switch]$DownloadOnly
)

$legacyRepairJwt = if ($PSBoundParameters.ContainsKey('JWTAuthToken')) { $JWTAuthToken } else { Get-Variable -Name ITGlueJWT -ValueOnly -ErrorAction Ignore }
$knownRun = Get-Variable -Name ITGlueHuduMigrationRun -Scope Local -ValueOnly -ErrorAction Ignore
$loadedRunPath = Get-Variable -Name MigrationLogs -Scope Local -ValueOnly -ErrorAction Ignore
$loadedRunFlag = Get-Variable -Name FirstTimeLoad -Scope Local -ValueOnly -ErrorAction Ignore
if ($loadedRunFlag -ne 1 -or -not $knownRun -or $loadedRunPath -ne $knownRun.LogsFolder -or $SettingsFile) {
    . "$PSScriptRoot/Initialize-Module.ps1" -InitType Lite -SettingsFile $SettingsFile
}
. "$PSScriptRoot/Public/Repair-ITGlueLegacyStepScreenshots.ps1"

$legacyArticlesPath = Join-Path $MigrationLogs 'Articles.json'
if (-not (Test-Path -LiteralPath $legacyArticlesPath)) { throw 'Articles.json is required. Complete the article migration before running this repair.' }
$legacyRepairArticles = @(Get-Content -LiteralPath $legacyArticlesPath -Raw | ConvertFrom-Json -Depth 100)
foreach ($legacyArticle in $legacyRepairArticles) {
    if ([string]$legacyArticle.ITGID -notmatch '^\d+$') { continue }
    $legacySidecar = Join-Path $MigrationLogs "DocumentImageRecovery/$($legacyArticle.ITGID).json"
    if (Test-Path -LiteralPath $legacySidecar) {
        $savedRecoveries = @(Get-Content -LiteralPath $legacySidecar -Raw | ConvertFrom-Json -Depth 30)
        $savedKeys = @($savedRecoveries.RecoveryKey)
        $combinedRecoveries = @(Get-ITGlueDocumentImageProperty $legacyArticle 'ImageRecoveries' | Where-Object { $_.RecoveryKey -notin $savedKeys }) + $savedRecoveries
        $legacyArticle | Add-Member -NotePropertyName ImageRecoveries -NotePropertyValue $combinedRecoveries -Force
    }
}
$legacyRepairContext = New-ITGlueLegacyScreenshotRecoveryContext -ApiBase $ITGAPIEndpoint -ApiKey $ITGKey -MigrationLogsPath $MigrationLogs -TenantBase $ITGURL -JWTAuthToken $legacyRepairJwt -JWTBaseUri $JWTBaseUri -WebSession $WebSession
try {
    $legacyRepairResults = @(Invoke-ITGlueLegacyScreenshotRepair -Articles $legacyRepairArticles -Context $legacyRepairContext -DocumentId $DocumentId -DownloadOnly:$DownloadOnly -WhatIf:$WhatIfPreference)
    $legacyRepairResults | ConvertTo-Json -Depth 20 -AsArray | Set-Content -LiteralPath (Join-Path $MigrationLogs 'LegacyStepScreenshotRecovery.json') -Encoding utf8
    $legacyRepairResults
} finally {
    $legacyRepairArticles | ConvertTo-Json -Depth 100 -AsArray | Set-Content -LiteralPath $legacyArticlesPath -Encoding utf8
    $legacyRepairContext.JWTAuthToken = $null
    $legacyRepairContext.WebSession = $null
    $legacyRepairJwt = $null
}
