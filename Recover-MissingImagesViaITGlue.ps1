<#
.SYNOPSIS
    Uploads article images that were missing from the IT Glue export (fetched separately from IT Glue
    via an authenticated browser) into Hudu, and rewrites the affected article bodies to point at them.

.DESCRIPTION
    Companion to the bracket-path repair. Some article images were not included in the IT Glue export
    (they live in IT Glue but the export omitted them). Those bytes were pulled from IT Glue with an
    authenticated browser session and saved to recovered-images.json ({ imgId: { b64, mime, bytes } }).

    This script decodes them, uploads each to the relevant Hudu article record, and replaces the still-
    unmigrated <img> src (any src referencing that image id) with the new Hudu photo URL. It only touches
    img tags that still reference an IT Glue image id, so re-running is safe (already-fixed imgs are skipped).

.PARAMETER DryRun
    Read Hudu article bodies and report which img srcs would be replaced. No uploads, no article writes.

.PARAMETER RecoveredJson
    Path to recovered-images.json (default: next to this script).

.PARAMETER WorklistJson
    Path to the recovery worklist (article<->image map) built by Build-RecoveryWorklist.ps1.

.PARAMETER SkipFork
    Reuse the already-present HuduAPI fork instead of re-downloading it.

## SENSITIVE KEYS ARE LOADED INTO MEMORY BY Initialize-Module - DO NOT SAVE OR SHARE OUTPUT
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [string]$RecoveredJson = "$PSScriptRoot\recovered-images.json",
    [string]$WorklistJson  = 'C:\tmp\recover-worklist.json',
    [string]$MigrationLogsPath,
    [string]$SettingsJsonPath,
    [switch]$SkipFork
)

# Import the completed migration's settings non-interactively (same pattern as the repair script)
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
if (-not $HuduAPIKey) { $HuduAPIKey = ConvertSecureStringToPlainText -SecureString ($environmentSettings.HuduAPIKey | ConvertTo-SecureString) }

# --- Load recovered images (double-JSON-encoded by the browser save) + the worklist ---
$rawRec = Get-Content -LiteralPath $RecoveredJson -Raw | ConvertFrom-Json
if ($rawRec -is [string]) { $rawRec = $rawRec | ConvertFrom-Json }   # unwrap the stringified JSON
$imgById = @{}
foreach ($p in $rawRec.PSObject.Properties) { $imgById[$p.Name] = $p.Value }
$work = @(Get-Content -LiteralPath $WorklistJson -Raw | ConvertFrom-Json)
Write-Host ("Recovered images: {0}   Worklist pairs: {1}   Articles: {2}" -f $imgById.Count, $work.Count, (@($work|Group-Object HuduID).Count))

# --- Decode recovered images to temp files (once) ---
$imgDir = 'C:\tmp\recovered-files'
if (-not (Test-Path -LiteralPath $imgDir)) { New-Item -ItemType Directory -Path $imgDir -Force | Out-Null }
$fileById = @{}
foreach ($id in $imgById.Keys) {
    $ext = switch -Regex ($imgById[$id].mime) { 'png' {'png'} 'jpe?g' {'jpg'} 'gif' {'gif'} 'webp' {'webp'} default {'png'} }
    $fp = Join-Path $imgDir "$id.$ext"
    if (-not (Test-Path -LiteralPath $fp)) { [IO.File]::WriteAllBytes($fp, [Convert]::FromBase64String($imgById[$id].b64)) }
    $fileById[$id] = $fp
}

# Hudu auth is required to READ article bodies too (Get-HuduArticles), so authenticate for dry-run as well.
# Only the write calls (New-HuduPublicPhoto / Set-HuduArticle) are gated behind -not $DryRun below.
$null = Set-ExternalModulesInitialized -HuduBaseURL $HuduBaseDomain -HuduAPIKey $HuduAPIKey -RefreshHuduApiForkEachRun:(!$SkipFork)

$report = foreach ($grp in ($work | Group-Object HuduID)) {
    $huduId = $grp.Name
    $imgIds = @($grp.Group | Select-Object -ExpandProperty ImgId -Unique) | Where-Object { $imgById.ContainsKey($_) }
    $articleName = ($grp.Group | Select-Object -First 1).Article
    if (-not $imgIds) { continue }

    Write-Host "`n=== $articleName (HuduID $huduId) : $(@($imgIds).Count) image(s) ===" -ForegroundColor Green
    $resp = Get-HuduArticles -id $huduId
    $article = if ($resp.article) { $resp.article } else { $resp }   # single-article fetch nests under .article
    if (-not $article -or -not $article.id) { Write-Host "  article not found" -ForegroundColor Red; continue }
    $body = [string]$article.content
    Write-Host ("  body: {0} chars | <img:{1} itglue:{2} images/:{3} public_photo:{4}" -f `
        $body.Length, [bool]($body -imatch '<img'), [bool]($body -match 'itglue'), [bool]($body -match 'images/'), [bool]($body -match 'public_photo')) -ForegroundColor DarkGray
    $replaced = 0; $notFound = @(); $uploaded = 0

    foreach ($imgId in $imgIds) {
        # Match an <img ...> whose src references this image id (IT Glue URL or relative path), not already a Hudu photo
        $pattern = "(?is)<img\b[^>]*?\bsrc\s*=\s*(['""])(?<src>[^'""]*?/images/$imgId(?![0-9])[^'""]*?)\1[^>]*>"
        $m = [regex]::Match($body, $pattern)
        if (-not $m.Success) { $notFound += $imgId; continue }

        if ($DryRun) {
            Write-Host ("  would replace img {0}  (current src: {1})" -f $imgId, $m.Groups['src'].Value)
            $replaced++
            continue
        }
        $upload = New-HuduPublicPhoto -FilePath $fileById[$imgId].ToLower() -record_id $huduId -record_type 'Article'
        $newUrl = $upload.public_photo.url.replace($HuduBaseDomain, '')
        $uploaded++
        # replace every src referencing this id in the body
        $body = [regex]::Replace($body, "(?<=src=[""'])([^""']*?/images/$imgId(?![0-9])[^""']*?)(?=[""'])", [System.Text.RegularExpressions.MatchEvaluator]{ param($x) $newUrl })
        $replaced++
        Write-Host ("  uploaded img {0} -> {1}" -f $imgId, $newUrl)
    }

    if (-not $DryRun -and $uploaded -gt 0) {
        $splat = @{ article_id = [int]$huduId; name = $article.name; content = $body }
        if ($article.company_id) { $splat.company_id = $article.company_id }
        $null = Set-HuduArticle @splat
        Write-Host "  article body updated." -ForegroundColor Green
    }

    [pscustomobject]@{ HuduID=$huduId; Article=$articleName; ImagesNeeded=@($imgIds).Count; Replaced=$replaced; Uploaded=$uploaded; NotFoundInBody=($notFound -join ',') }
}

$report | Format-Table HuduID, Article, ImagesNeeded, Replaced, Uploaded, NotFoundInBody -AutoSize | Out-Host
$stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
$outDir = if ($MigrationLogsPath) { $MigrationLogsPath } else { $imgDir }
$report | ConvertTo-Json -Depth 6 | Out-File -LiteralPath (Join-Path $outDir "ImageRecovery-$stamp.json")
Write-Host ("`nTotals: articles={0} uploaded={1} replaced={2}" -f @($report).Count, (@($report)|Measure-Object Uploaded -Sum).Sum, (@($report)|Measure-Object Replaced -Sum).Sum) -ForegroundColor Cyan
if ($DryRun) { Write-Host 'DRY RUN - no uploads or article changes were made.' -ForegroundColor Green }
