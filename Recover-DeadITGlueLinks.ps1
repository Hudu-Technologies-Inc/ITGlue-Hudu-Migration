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
    # Generate an accurate RemainingManualActions.html of the DEAD links from the live Hudu bodies.
    # Implies no writes.
    [switch]$Report,
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
. $PSScriptRoot\Public\Normalize-String.ps1   # Format-ManualActionsReport (for -Report)

$null = Set-ExternalModulesInitialized -HuduBaseURL $HuduBaseDomain -HuduAPIKey $HuduAPIKey -RefreshHuduApiForkEachRun:(!$SkipFork)

# Resolvability sets + article lookup (for -Report classification)
$byHudu = @{}; foreach ($x in $MatchedArticles) { if ($x.HuduID) { $byHudu["$($x.HuduID)"] = $x } }
$artIds = @{}; foreach ($x in $MatchedArticles) { $artIds["$($x.ITGID)"] = $true }
$pwIds  = @{}; foreach ($x in $MatchedPasswords) { $pwIds["$($x.ITGID)"] = $true }
$cfgIds = @{}; foreach ($x in $MatchedConfigurations) { $cfgIds["$($x.ITGID)"] = $true }
$asIds  = @{}; foreach ($x in $MatchedAssets) { $asIds["$($x.ITGID)"] = $true }
$deadRecords = [System.Collections.ArrayList]::new()

# IMPORTANT: the list endpoint (Get-HuduArticles) omits company-scoped / paginated articles - it
# returned only 977 of ~1097 here and dropped article 943 entirely. So iterate EVERY migrated
# article by HuduID and full-fetch its body (nested under .article). Robust and complete.
$ids = @($MatchedArticles | Where-Object { $_.HuduID } | ForEach-Object { "$($_.HuduID)" } | Select-Object -Unique)
Write-Host ("Scanning {0} migrated articles (full-fetch each)..." -f $ids.Count) -ForegroundColor Cyan
$scan = 0
# $rewriteReport, NOT $report: case-insensitive var names make $report alias the [switch]$Report
# parameter, so assigning this foreach array throws "Cannot convert Object[] to SwitchParameter".
$rewriteReport = foreach ($hid in $ids) {
    $scan++
    if ($scan % 150 -eq 0) { Write-Host ("  ...scanned {0}/{1}" -f $scan, $ids.Count) -ForegroundColor DarkGray }
    $resp = Get-HuduArticles -id $hid
    $a = if ($resp.article) { $resp.article } else { $resp }
    if (-not $a.id) { continue }
    $orig = [string]$a.content
    if ($orig -notlike "*$ITGURL*") { continue }
    $new = Update-StringWithCaptureGroups -inputString $orig -pattern $RichRegexPatternToMatchSansAssets    -type 'rich'
    $new = Update-StringWithCaptureGroups -inputString $new  -pattern $RichRegexPatternToMatchWithAssets    -type 'rich'
    $new = Update-StringWithCaptureGroups -inputString $new  -pattern $RichDocLocatorUrlPatternToMatch       -type 'rich'
    $new = Update-StringWithCaptureGroups -inputString $new  -pattern $RichDocLocatorRelativeURLPatternToMatch -type 'rich'
    $changed = ($new -ne $orig)
    $before = ([regex]::Matches($orig, [regex]::Escape($ITGURL), 'IgnoreCase')).Count
    $after  = ([regex]::Matches($new,  [regex]::Escape($ITGURL), 'IgnoreCase')).Count

    if ($changed) {
        Write-Host ("  {0} (id {1}): itglue links {2} -> {3}" -f $a.name, $a.id, $before, $after) -ForegroundColor Green
        if (-not $DryRun -and -not $Report) { $null = Set-HuduArticle -Name $a.name -id $a.id -Content $new }
    }

    # For -Report: capture the residual (unrewritten) IT Glue references from the LIVE body
    if ($Report -and $after -gt 0) {
        $art = $byHudu["$($a.id)"]
        $seen = @{}
        foreach ($m in [regex]::Matches($new, "$([regex]::Escape($ITGURL))/([0-9]{1,20})/(docs|passwords|configurations|assets)/([0-9]{1,20})", 'IgnoreCase')) {
            $url = $m.Value; if ($seen.ContainsKey($url)) { continue }; $seen[$url] = $true
            $type = $m.Groups[2].Value; $eid = $m.Groups[3].Value
            $resolvable = switch ($type) { 'docs' {$artIds.ContainsKey($eid)} 'passwords' {$pwIds.ContainsKey($eid)} 'configurations' {$cfgIds.ContainsKey($eid)} 'assets' {$asIds.ContainsKey($eid)} default {$false} }
            [void]$deadRecords.Add([pscustomobject]@{
                Document_Name = $a.name; Company_Name = $art.Company.CompanyName; HuduID = $a.id
                Type = 'Article - Dead Link'; Field_Name = 'Link'
                Notes = if ($resolvable) { 'Plain-text IT Glue URL (target migrated - not auto-linked)' } else { 'IT Glue link to an item not migrated to Hudu' }
                Action = "$(if($resolvable){'Plain-text URL to'}else{'Dead link to'}) IT Glue $type #$eid. URL: $url"
                Data = $url; Hudu_URL = $art.HuduObject.url; ITG_URL = $url
            })
        }
    }
    [pscustomobject]@{ id=$a.id; name=$a.name; Changed=$changed; ITGlueBefore=$before; ITGlueAfter=$after }
}

$changedRep = @($rewriteReport | Where-Object { $_.Changed })
$stuck = @($rewriteReport | Where-Object { $_.ITGlueAfter -gt 0 })
Write-Host ("`nChanged: {0}   Still have IT Glue refs after: {1}" -f $changedRep.Count, $stuck.Count) -ForegroundColor Cyan
if ($stuck) {
    Write-Host "Articles still containing IT Glue URLs (likely plain-text URLs or non-doc links - review):" -ForegroundColor Yellow
    $stuck | Select-Object id, name, ITGlueAfter | Format-Table -AutoSize | Out-Host
}
$stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
$rewriteReport | ConvertTo-Json -Depth 5 | Out-File -LiteralPath (Join-Path $MigrationLogs "DeadLinkRewrite-$stamp.json")

if ($Report) {
    $deadArticles = @($deadRecords | Group-Object HuduID).Count
    $dead = @($deadRecords | Where-Object { $_.Notes -like '*not migrated*' }).Count
    $plain = @($deadRecords).Count - $dead
    Write-Host ("`nDead links (target not in Hudu): {0}   plain-text-to-migrated: {1}   across {2} articles" -f $dead, $plain, $deadArticles) -ForegroundColor Cyan
    $summary = "Remaining IT Glue links after rewrite (from live Hudu). Dead links (target not migrated): $dead; plain-text URLs to migrated docs: $plain; across $deadArticles articles."
    Format-ManualActionsReport -ManualActions $deadRecords -OutputPath (Join-Path $MigrationLogs 'RemainingManualActions.html') -Summary $summary
    Write-Host ("Report: {0}" -f (Join-Path $MigrationLogs 'RemainingManualActions.html'))
} elseif ($DryRun) { Write-Host 'DRY RUN - no article changes were made.' -ForegroundColor Green }
