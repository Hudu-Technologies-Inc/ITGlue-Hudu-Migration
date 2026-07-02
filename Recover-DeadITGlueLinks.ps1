<#
.SYNOPSIS
    Re-runs the IT Glue -> Hudu article link rewrite with the fixed anchor patterns, to repair
    <a href> links that still point at IT Glue (dead once IT Glue is decommissioned).

.DESCRIPTION
    The migration's link-rewrite pattern required href to be the FIRST attribute (`<a href=...`).
    The COM HTML parser reorders attributes, so IT Glue auto-linkified URLs (`<A class=linkified
    href="...">`) were skipped and left as live IT Glue links. ConvertTo-HuduURL.ps1 is now fixed to
    allow attributes before href; this script applies that fix to the already-migrated Hudu articles.

    Reuses the migration's Update-StringWithCaptureGroups + the matched-object logs for URL lookups.

.PARAMETER DryRun
    Report which articles would change (and residual itglue refs), no writes.
.PARAMETER SkipFork
    Reuse the already-present HuduAPI fork instead of re-downloading it.

## SENSITIVE KEYS ARE LOADED INTO MEMORY BY Initialize-Module - DO NOT SAVE OR SHARE OUTPUT
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [string]$MigrationLogsPath,
    [string]$SettingsJsonPath,
    [switch]$SkipFork
)

if (-not $SettingsJsonPath -and $MigrationLogsPath) {
    $SettingsJsonPath = Join-Path (Split-Path $MigrationLogsPath -Parent) 'settings\settings.json'
}
if ($SettingsJsonPath -and (Test-Path -LiteralPath $SettingsJsonPath)) {
    $choice = 'I'; $importChoice = 'D'; $defaultSettingsPath = $SettingsJsonPath
    Write-Host "Importing migration settings from $SettingsJsonPath" -ForegroundColor Yellow
}
$resumeQuestion = $false
$reenterChoice  = 'Continue'
. $PSScriptRoot\Initialize-Module.ps1 -InitType 'Lite'

$HuduBaseDomain = $HuduBaseDomain ?? $environmentSettings.HuduBaseDomain
$ITGURL         = $ITGURL         ?? $environmentSettings.ITGURL
if ($MigrationLogsPath) { $MigrationLogs = $MigrationLogsPath }
$MigrationLogs  = $MigrationLogs  ?? $environmentSettings.MigrationLogs
if (-not $HuduAPIKey) { $HuduAPIKey = ConvertSecureStringToPlainText -SecureString ($environmentSettings.HuduAPIKey | ConvertTo-SecureString) }

# Matched-object lookups used by the switch inside Update-StringWithCaptureGroups
$MatchedArticles       = @(Get-Content -LiteralPath "$MigrationLogs\Articles.json" -Raw | ConvertFrom-Json -Depth 100)
$MatchedPasswords      = if (Test-Path -LiteralPath "$MigrationLogs\Passwords.json")       { @(Get-Content -LiteralPath "$MigrationLogs\Passwords.json" -Raw | ConvertFrom-Json -Depth 100) } else { @() }
$MatchedConfigurations = if (Test-Path -LiteralPath "$MigrationLogs\Configurations.json")  { @(Get-Content -LiteralPath "$MigrationLogs\Configurations.json" -Raw | ConvertFrom-Json -Depth 100) } else { @() }
$MatchedAssets         = if (Test-Path -LiteralPath "$MigrationLogs\Assets.json")          { @(Get-Content -LiteralPath "$MigrationLogs\Assets.json" -Raw | ConvertFrom-Json -Depth 100) } else { @() }

# Fixed patterns + Update-StringWithCaptureGroups (uses $ITGURL / $environmentSettings)
. $PSScriptRoot\Private\ConvertTo-HuduURL.ps1

$null = Set-ExternalModulesInitialized -HuduBaseURL $HuduBaseDomain -HuduAPIKey $HuduAPIKey -RefreshHuduApiForkEachRun:(!$SkipFork)

# Get-HuduArticles (list) returns .content directly; -id nests under .article - handle both
$articles = @(Get-HuduArticles | Where-Object { ([string]$_.content) -like "*$ITGURL*" })
Write-Host ("Articles still containing an IT Glue URL: {0}" -f $articles.Count) -ForegroundColor Cyan

$report = foreach ($a in $articles) {
    $orig = [string]$a.content
    $new = Update-StringWithCaptureGroups -inputString $orig -pattern $RichRegexPatternToMatchSansAssets    -type 'rich'
    $new = Update-StringWithCaptureGroups -inputString $new  -pattern $RichRegexPatternToMatchWithAssets    -type 'rich'
    $new = Update-StringWithCaptureGroups -inputString $new  -pattern $RichDocLocatorUrlPatternToMatch       -type 'rich'
    $new = Update-StringWithCaptureGroups -inputString $new  -pattern $RichDocLocatorRelativeURLPatternToMatch -type 'rich'
    $changed = ($new -ne $orig)
    $before = ([regex]::Matches($orig, [regex]::Escape($ITGURL), 'IgnoreCase')).Count
    $after  = ([regex]::Matches($new,  [regex]::Escape($ITGURL), 'IgnoreCase')).Count

    if ($changed) {
        Write-Host ("  {0} (id {1}): itglue links {2} -> {3}" -f $a.name, $a.id, $before, $after) -ForegroundColor Green
        if (-not $DryRun) { $null = Set-HuduArticle -Name $a.name -id $a.id -Content $new }
    }
    [pscustomobject]@{ id=$a.id; name=$a.name; Changed=$changed; ITGlueBefore=$before; ITGlueAfter=$after }
}

$changedRep = @($report | Where-Object { $_.Changed })
$stuck = @($report | Where-Object { $_.ITGlueAfter -gt 0 })
Write-Host ("`nChanged: {0}   Still have IT Glue refs after: {1}" -f $changedRep.Count, $stuck.Count) -ForegroundColor Cyan
if ($stuck) {
    Write-Host "Articles still containing IT Glue URLs (likely plain-text URLs or non-doc links - review):" -ForegroundColor Yellow
    $stuck | Select-Object id, name, ITGlueAfter | Format-Table -AutoSize | Out-Host
}
$stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
$report | ConvertTo-Json -Depth 5 | Out-File -LiteralPath (Join-Path $MigrationLogs "DeadLinkRewrite-$stamp.json")
if ($DryRun) { Write-Host 'DRY RUN - no article changes were made.' -ForegroundColor Green }
