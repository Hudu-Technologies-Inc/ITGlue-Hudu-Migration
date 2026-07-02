<#
.SYNOPSIS
    Comprehensively rewrite EVERY enstep.itglue.com URL in Hudu articles to its migrated Hudu URL,
    covering all entity types (docs, passwords, assets, contacts, locations, websites) and both
    <a href> and plain-text forms. URLs whose target was NOT migrated (deleted in IT Glue) are left
    in place and reported clearly as dead.

.DESCRIPTION
    The migration's rewriter only handled <a href> anchors of docs/passwords/configs/assets and used a
    pattern that missed anchors with attributes before href, so plain-text URLs, other entity types and
    many anchors were left pointing at IT Glue. This does a direct URL-string replacement using
    ITGlue-ID -> Hudu-URL maps built from the migration logs, so it catches all forms.

.PARAMETER DryRun   Report what would change; no writes.
.PARAMETER Report   Generate RemainingManualActions.html of the DEAD (unmapped) links; no writes.
.PARAMETER SkipFork Reuse the already-present HuduAPI fork.

## SENSITIVE KEYS ARE LOADED INTO MEMORY BY Initialize-Module - DO NOT SAVE OR SHARE OUTPUT
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$Report,
    [string]$MigrationLogsPath,
    [string]$SettingsJsonPath,
    [switch]$SkipFork
)

if (-not $SettingsJsonPath -and $MigrationLogsPath) { $SettingsJsonPath = Join-Path (Split-Path $MigrationLogsPath -Parent) 'settings\settings.json' }
if ($SettingsJsonPath -and (Test-Path -LiteralPath $SettingsJsonPath)) { $choice='I'; $importChoice='D'; $defaultSettingsPath=$SettingsJsonPath; Write-Host "Importing migration settings from $SettingsJsonPath" -ForegroundColor Yellow }
$resumeQuestion=$false; $reenterChoice='Continue'
. $PSScriptRoot\Initialize-Module.ps1 -InitType 'Lite'
. $PSScriptRoot\Public\Normalize-String.ps1   # Format-ManualActionsReport

$HuduBaseDomain = $HuduBaseDomain ?? $environmentSettings.HuduBaseDomain
$ITGURL         = $ITGURL         ?? $environmentSettings.ITGURL
if ($MigrationLogsPath) { $MigrationLogs = $MigrationLogsPath }
$MigrationLogs  = $MigrationLogs  ?? $environmentSettings.MigrationLogs
if (-not $HuduAPIKey) { $HuduAPIKey = ConvertSecureStringToPlainText -SecureString ($environmentSettings.HuduAPIKey | ConvertTo-SecureString) }

# --- ITGlue-ID -> Hudu-URL maps, built by the SHARED rewriter used by the migration too ---
. $PSScriptRoot\Private\Update-AllITGlueUrls.ps1

function Import-Log($file) {
    $p = "$MigrationLogs\$file"
    if (Test-Path -LiteralPath $p) { @(Get-Content -LiteralPath $p -Raw | ConvertFrom-Json -Depth 100) } else { @() }
}
$MatchedArticles = Import-Log 'Articles.json'
$itgUrlMaps = Get-ITGlueUrlMaps -HuduBaseDomain $HuduBaseDomain -Articles $MatchedArticles `
    -Passwords (Import-Log 'Passwords.json') -AssetPasswords (Import-Log 'AssetPasswords.json') `
    -Configurations (Import-Log 'Configurations.json') -Assets (Import-Log 'Assets.json') `
    -Contacts (Import-Log 'Contacts.json') -Locations (Import-Log 'Locations.json') -Websites (Import-Log 'Websites.json')
$ItgDomain = ($ITGURL -replace '^https?://', '').TrimEnd('/')
Write-Host ("Maps: " + (($itgUrlMaps.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value.Count)" }) -join '  ')) -ForegroundColor DarkGray
$byHudu = @{}; foreach ($x in $MatchedArticles) { if ($x.HuduID) { $byHudu["$($x.HuduID)"] = $x } }

# Company (IT Glue org id) -> full Hudu company URL. This standalone remediation goes FURTHER than the
# migration's default (leave-and-report): links to DELETED items and index/list pages are re-pointed to
# the owning company page, and anything with no company either is stripped, so ZERO enstep.itglue.com
# survives in the instance.
$companyMap = @{}
foreach ($c in (Import-Log 'Companies.json')) {
    if ($c.ITGID -and $c.HuduCompanyObject.url) {
        $u = [string]$c.HuduCompanyObject.url
        $companyMap["$($c.ITGID)"] = if ($u -match '^https?://') { $u } else { $HuduBaseDomain.TrimEnd('/') + '/' + $u.TrimStart('/') }
    }
}
Write-Host ("Company map: {0}" -f $companyMap.Count) -ForegroundColor DarkGray

# Talk to the Hudu API DIRECTLY for both reads and writes, bypassing the HuduAPI module. This avoids
# the module's noisy Write-APIErrorObject retry logging on transient errors and gives us precise
# control over rate-limit backoff and the full-article PUT body.
$plainHuduKey = if ($HuduAPIKey -is [securestring]) { (New-Object System.Management.Automation.PSCredential('user', $HuduAPIKey)).GetNetworkCredential().Password } else { [string]$HuduAPIKey }
$script:HuduHeaders = @{ 'x-api-key' = $plainHuduKey }
$script:HuduApiBase = $HuduBaseDomain.TrimEnd('/')
function Get-HuduArticleDirect {
    param($ArticleId)
    for ($try = 0; $try -lt 5; $try++) {
        try {
            return Invoke-RestMethod -Method Get -Uri ("{0}/api/v1/articles/{1}" -f $script:HuduApiBase, $ArticleId) -Headers $script:HuduHeaders -ContentType 'application/json'
        } catch {
            $msg = "$($_.Exception.Message)"
            if ($msg -match '404|Not Found') { return $null }
            if ($msg -match '429|Too Many|Retry later') { Start-Sleep -Seconds 20; continue }
            Start-Sleep -Seconds 3
        }
    }
    Write-Warning "read id $ArticleId failed after retries"
    return $null
}
function Set-HuduArticleDirect {
    param($ArticleId, $NewContent, $Name)
    $cur = Get-HuduArticleDirect $ArticleId
    if (-not $cur.article) { Write-Warning "write ${ArticleId} - could not refetch"; return $false }
    $cur.article.content = $NewContent
    if ($Name) { $cur.article.name = $Name }
    $body = @{ article = $cur.article } | ConvertTo-Json -Depth 25
    for ($try = 0; $try -lt 5; $try++) {
        try {
            $null = Invoke-RestMethod -Method Put -Uri ("{0}/api/v1/articles/{1}" -f $script:HuduApiBase, $ArticleId) -Headers $script:HuduHeaders -ContentType 'application/json; charset=utf-8' -Body $body
            return $true
        } catch {
            $msg = "$($_.Exception.Message)"
            if ($msg -match '429|Too Many|Retry later') { Start-Sleep -Seconds 20; continue }
            Write-Warning "write $ArticleId failed: $msg"; return $false
        }
    }
    return $false
}

$deadRecords = [System.Collections.ArrayList]::new()
$ids = @($MatchedArticles | Where-Object { $_.HuduID } | ForEach-Object { "$($_.HuduID)" } | Select-Object -Unique)
Write-Host ("Scanning {0} migrated articles (full-fetch each)..." -f $ids.Count) -ForegroundColor Cyan

$scan=0; $totMapped=0; $totDead=0
# NOTE: named $rewriteReport, NOT $report - PowerShell variable names are case-insensitive, so a
# plain $report here would alias the [switch]$Report parameter and assigning this array to it throws
# "Cannot convert Object[] to SwitchParameter" (ArgumentTransformationMetadataException).
$rewriteReport = foreach ($hid in $ids) {
    $scan++
    if ($scan % 150 -eq 0) { Write-Host ("  ...scanned {0}/{1}" -f $scan, $ids.Count) -ForegroundColor DarkGray }
  try {
    $resp = Get-HuduArticleDirect $hid
    $a = if ($resp.article) { $resp.article } else { $resp }
    if (-not $a -or -not $a.id) { continue }
    $orig = [string]$a.content
    if ($orig -notmatch 'itglue\.com') { continue }   # any itglue.com form: enstep, kb, encoded, wrapped
    $art = $byHudu["$($a.id)"]

    # Shared comprehensive rewrite: mapped IT Glue URLs -> Hudu (all types, plain-text + anchors,
    # encoded, kb). Everything it can't map comes back as a dead link for this tool to redirect/strip.
    $sweep = Update-AllITGlueUrls -Content $orig -Maps $itgUrlMaps -ItgDomain $ItgDomain
    $new = $sweep.Content
    $mapped = $sweep.Rewritten
    $deadUrls = @{}
    # Aggressive cleanup layer (standalone only): re-point dead links to the owning company page, or
    # strip them, so no enstep.itglue.com survives. Group by URL so each is handled once.
    foreach ($dl in $sweep.DeadLinks) {
        $u = $dl.Url
        if ($deadUrls.ContainsKey($u)) { continue }
        $org = ([regex]::Match([uri]::UnescapeDataString($u), "$([regex]::Escape($ItgDomain))/(\d+)", 'IgnoreCase')).Groups[1].Value
        if ($org -and $companyMap.ContainsKey($org)) {
            $deadUrls[$u] = @{ type=$dl.Type; id=$dl.Id; disp='company' }
            $new = $new.Replace($u, $companyMap[$org])
        } else {
            $deadUrls[$u] = @{ type=$dl.Type; id=$dl.Id; disp='stripped' }
            $new = $new.Replace($u, '')
        }
    }

    $changed = ($new -ne $orig)
    $totMapped += $mapped; $totDead += $deadUrls.Count

    if ($changed) {
        Write-Host ("  {0} (id {1}): {2} IT Glue URL(s) resolved ({3} re-pointed to company / removed)" -f $a.name, $a.id, $mapped, $deadUrls.Count) -ForegroundColor Green
        if (-not $DryRun -and -not $Report) { $null = Set-HuduArticleDirect -ArticleId $a.id -NewContent $new -Name $a.name }
    }
    foreach ($u in $deadUrls.Keys) {
        $d = $deadUrls[$u]
        $what = if ($d.type -eq 'index') { "IT Glue $((($u.TrimEnd('/') -split '/')[-1])) index/list page" } else { "a deleted IT Glue $($d.type) (#$($d.id))" }
        $act  = if ($d.disp -eq 'company') { "Link pointed to $what which is not in Hudu; re-pointed to the company page so no IT Glue URL remains." }
                else { "Link pointed to $what and the company itself is not in Hudu; the link was removed." }
        [void]$deadRecords.Add([pscustomobject]@{
            Document_Name=$a.name; Company_Name=$art.Company.CompanyName; HuduID=$a.id
            Type='Article - Redirected/Removed Link'; Field_Name='Link'
            Notes=$(if ($d.disp -eq 'company') { 'IT Glue target missing - re-pointed to company page' } else { 'IT Glue target + company missing - link removed' })
            Action="$act  Original URL: $u"
            Data=$u; Hudu_URL=$art.HuduObject.url; ITG_URL=$u
        })
    }
    [pscustomobject]@{ id=$a.id; name=$a.name; MappedToHudu=$mapped; DeadLeft=$deadUrls.Count }
  } catch { Write-Warning ("id {0} failed: {1}" -f $hid, $_) }
}

$redir = @($deadRecords | Where-Object { $_.Notes -like '*company page*' }).Count
$strip = @($deadRecords).Count - $redir
Write-Host ("`nTotals: {0} IT Glue URLs resolved  |  {1} re-pointed to company (deleted/index)  |  {2} removed  |  across {3} articles" -f `
    $totMapped, $redir, $strip, @($deadRecords|Group-Object HuduID).Count) -ForegroundColor Cyan
$stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
$rewriteReport | ConvertTo-Json -Depth 5 | Out-File -LiteralPath (Join-Path $MigrationLogs "AllUrlRewrite-$stamp.json")

if ($Report -or $DryRun) {
    Write-Host "`nRe-pointed/removed links by IT Glue type:" -ForegroundColor Yellow
    $deadRecords | Group-Object { $_.Action -replace '.*deleted IT Glue (\w+).*','$1' -replace '.*IT Glue (\w+) index.*','$1-index' } | Sort-Object Count -Descending | ForEach-Object { "  {0,-16} {1}" -f $_.Name, $_.Count }
}
if ($Report) {
    $summary = "IT Glue links whose target was DELETED or an index/list page (no direct Hudu equivalent). These were re-pointed to the company page (or removed) so no enstep.itglue.com URL remains. Links to migrated items were rewritten to their Hudu URL. Total: $($deadRecords.Count) across $(@($deadRecords|Group-Object HuduID).Count) articles."
    Format-ManualActionsReport -ManualActions $deadRecords -OutputPath (Join-Path $MigrationLogs 'RemainingManualActions.html') -Summary $summary
    Write-Host ("Report: {0}" -f (Join-Path $MigrationLogs 'RemainingManualActions.html'))
}
if ($DryRun) { Write-Host 'DRY RUN - no article changes were made.' -ForegroundColor Green }
