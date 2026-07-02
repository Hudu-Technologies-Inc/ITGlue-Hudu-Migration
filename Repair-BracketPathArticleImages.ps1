<#
.SYNOPSIS
    Re-migrates article images that were wrongly skipped during the main migration because their
    export path contained square brackets (e.g. "[ADP] MyCase - Installation", "[Restricted]").

.DESCRIPTION
    The main migration resolved image files with Get-Item -Path "<path>*". PowerShell's -Path treats
    the argument as a wildcard, so bracketed folder names are read as character classes and never match
    the literal folder - the image exists but is reported "Missing image, file not found". Those articles
    therefore had ALL of their images skipped (the bracket sits in the shared article folder), so zero
    images were uploaded for them and their Hudu bodies point at unresolved local paths.

    This script re-processes ONLY those bracketed-path articles (safe: they had no images uploaded first
    time, so no duplicates), re-reads the pristine export HTML, uploads each image once and overwrites
    the Hudu article body. Non-bracket articles migrated fine and are never touched.

    Upload is NOT idempotent - run the real pass ONCE. Use -DryRun freely (no uploads, no article writes).

.PARAMETER DryRun
    Preview only: report resolvable / still-missing image counts per article. No uploads, no Set-HuduArticle.

.PARAMETER OnlyHuduIds
    Optional. Narrow to specific Hudu article IDs.

.PARAMETER SkipFork
    Reuse the already-present HuduAPI fork instead of re-downloading it.

## SENSITIVE KEYS ARE LOADED INTO MEMORY BY Initialize-Module - DO NOT SAVE OR SHARE OUTPUT
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [string[]]$OnlyHuduIds,
    [switch]$SkipFork,
    # Explicit path to the completed migration's logs folder (contains Articles.json / ManualActions.json).
    # Overrides the value Initialize-Module derives - use this to point at the timestamped debug\...\logs folder.
    [string]$MigrationLogsPath,
    # Explicit path to the completed migration's settings.json (defaults to the 'settings' folder next to the logs).
    [string]$SettingsJsonPath
)

# The GUI writes settings.json under debug-<timestamp>\settings (sibling of \logs), not %APPDATA%.
# Point Initialize-Module at it and pre-answer its prompts so Lite init imports it non-interactively.
if (-not $SettingsJsonPath -and $MigrationLogsPath) {
    $SettingsJsonPath = Join-Path (Split-Path $MigrationLogsPath -Parent) 'settings\settings.json'
}
if ($SettingsJsonPath -and (Test-Path -LiteralPath $SettingsJsonPath)) {
    $choice = 'I'; $importChoice = 'D'; $defaultSettingsPath = $SettingsJsonPath
    Write-Host "Importing migration settings from $SettingsJsonPath" -ForegroundColor Yellow
} else {
    Write-Warning "No settings.json found (looked for '$SettingsJsonPath'). Initialize-Module will prompt for settings."
}
# Suppress the "resume previous migration?" / re-enter prompts from Lite init
$resumeQuestion = $false
$reenterChoice  = 'Continue'

# --- Load settings + helper functions (Lite init: settings/keys, no Hudu auth) ---
. $PSScriptRoot\Initialize-Module.ps1 -InitType 'Lite'
. $PSScriptRoot\Private\Invoke-ImageTest.ps1
. $PSScriptRoot\Public\Normalize-String.ps1
. $PSScriptRoot\Public\Normalize-And-ConvertImage.ps1
. $PSScriptRoot\Private\ConvertTo-HuduURL.ps1   # Update-StringWithCaptureGroups + $ImgRegexPatternToMatch

# ImageMagick assembly - Invoke-ImageTest and Normalize-And-ConvertImage rely on it. The main migration
# loads this via Initialize-ImageMagik.ps1; load it here (absolute path, cwd-independent) or every image
# silently fails Invoke-ImageTest and nothing uploads.
if (-not ('ImageMagick.MagickImage' -as [type])) {
    Add-Type -Path (Join-Path $PSScriptRoot 'Magick.NET-Q16-AnyCPU.dll')
}
if (-not ('ImageMagick.MagickImage' -as [type])) {
    throw "ImageMagick (Magick.NET-Q16-AnyCPU.dll) failed to load from $PSScriptRoot - image validation would fail for every file. Aborting."
}

# --- Resolve settings variables defensively (in case Lite left any unset) ---
# Explicit override wins (Initialize-Module overwrites $MigrationLogs at load, so apply after dot-sourcing)
if ($MigrationLogsPath) { $MigrationLogs = $MigrationLogsPath }
$MigrationLogs  = $MigrationLogs  ?? $environmentSettings.MigrationLogs
if (-not (Test-Path -LiteralPath "$MigrationLogs\Articles.json")) {
    throw "Articles.json not found under '$MigrationLogs'. Pass -MigrationLogsPath pointing at the completed migration's logs folder (e.g. the debug-<timestamp>\logs directory)."
}
$ITGURL         = $ITGURL         ?? $environmentSettings.ITGURL
$HuduBaseDomain = $HuduBaseDomain ?? $environmentSettings.HuduBaseDomain
if (-not $HuduAPIKey) {
    $HuduAPIKey = ConvertSecureStringToPlainText -SecureString ($environmentSettings.HuduAPIKey | ConvertTo-SecureString)
}

Write-Host "MigrationLogs : $MigrationLogs"
Write-Host "Hudu          : $HuduBaseDomain"
Write-Host "ITGlue        : $ITGURL"
Write-Host ("Mode          : {0}" -f $(if ($DryRun) { 'DRY RUN (no changes)' } else { 'LIVE (uploads + article updates)' })) -ForegroundColor Cyan

# --- Identify affected articles: bracket in export path AND a logged "missing image" on that file ---
$MatchedArticles = Get-Content -LiteralPath "$MigrationLogs\Articles.json" -Raw | ConvertFrom-Json -Depth 100
$ManualActions   = if (Test-Path -LiteralPath "$MigrationLogs\ManualActions.json") {
    Get-Content -LiteralPath "$MigrationLogs\ManualActions.json" -Raw | ConvertFrom-Json -Depth 100
} else { @() }

$missingFiles = $ManualActions |
    Where-Object { $_.Type -eq 'Article - Image' -and $_.Notes -eq 'Missing image, file not found' } |
    Select-Object -ExpandProperty Data -Unique

$affected = $MatchedArticles | Where-Object { $_.FullPath -match '[\[\]]' -and $_.FullPath -in $missingFiles }
if ($OnlyHuduIds) { $affected = $affected | Where-Object { "$($_.HuduID)" -in $OnlyHuduIds } }

Write-Host ("Affected articles (bracket path + logged missing image): {0}" -f @($affected).Count) -ForegroundColor Cyan
if (-not $affected) { Write-Host 'Nothing to do.' -ForegroundColor Green; return }

# --- Duplicate-upload guard: skip HuduIDs already processed by a previous real run ---
$stateFile = Join-Path $MigrationLogs 'BracketImageRepair-processed.json'
$processed = if (Test-Path -LiteralPath $stateFile) { @(Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json) } else { @() }

# --- Authenticate Hudu (Lite init does not) - only needed for a live run ---
if (-not $DryRun) {
    $null = Set-ExternalModulesInitialized -HuduBaseURL $HuduBaseDomain -HuduAPIKey $HuduAPIKey -RefreshHuduApiForkEachRun:(!$SkipFork)
}

function Resolve-ImageFile {
    param([string]$Path)
    if (-not $Path) { return $null }
    # Fixed resolution: escape wildcard metachars ([ ] ? *) in the real path, keep a trailing * for missing extensions
    @(Get-Item -Path ([System.Management.Automation.WildcardPattern]::Escape($Path) + '*') -ErrorAction SilentlyContinue) |
        Select-Object -First 1
}

$report = foreach ($Article in $affected) {
    $InFile = $Article.FullPath
    $huduId = $Article.HuduID

    if ((-not $DryRun) -and ("$huduId" -in $processed)) {
        Write-Host "Skipping already-processed HuduID $huduId ($($Article.Name))" -ForegroundColor Yellow
        continue
    }
    if (-not (Test-Path -LiteralPath $InFile)) {
        [pscustomobject]@{ HuduID=$huduId; Article=$Article.Name; Company=$Article.Company.CompanyName; Status='InFile missing'; ImgTotal=0; Uploaded=0; StillMissing=0; HuduURL=$Article.HuduObject.url }
        continue
    }

    Write-Host "`n=== $($Article.Name) [$($Article.Company.CompanyName)] (HuduID $huduId) ===" -ForegroundColor Green

    $imgTotal = 0; $uploaded = 0; $stillMissing = 0
    $html = New-Object -ComObject 'HTMLFile'
    $rawsource = Get-Content -Encoding UTF8 -LiteralPath $InFile -Raw
    if ($rawsource.Length -gt 0) {
        $source = [regex]::replace($rawsource, '\xa0+', ' ')
        $srcBytes = [System.Text.Encoding]::Unicode.GetBytes($source)
        $html.write($srcBytes)
        $images = @($html.Images)

        foreach ($imageObject in $images) {
            # Reset per image so nothing carries over from a previous image/article
            $fullImgUrl = $null; $fullImgPath = $null; $tnImgUrl = $null; $tnImgPath = $null
            $matchedImage = $null; $foundFile = $null; $imagePath = $null

            if (($imageObject.src -notmatch '^http[s]?://') -or ($imageObject.src -match [regex]::Escape($ITGURL))) {
                $imgTotal++
                $imgHTML = $imageObject.outerHTML

                if ($imageObject.src -match [regex]::Escape($ITGURL)) {
                    $matchedImage = Update-StringWithCaptureGroups -inputString $imgHTML -type 'img' -pattern $ImgRegexPatternToMatch
                    if ($matchedImage) { $tnImgUrl = $matchedImage.url; $tnImgPath = $matchedImage.path }
                    else { $tnImgPath = $imageObject.src }
                } else {
                    $basepath = Split-Path $InFile
                    if ($fullImgUrl = ($imgHTML -split 'data-src-original="')[1]) { $fullImgUrl = ($fullImgUrl -split '"')[0] }
                    $tnImgUrl = ($imgHTML -split 'src="')[1].split('"')[0]
                    if ($fullImgUrl) { $fullImgPath = Join-Path -Path $basepath -ChildPath $fullImgUrl.replace('/', '\') }
                    $tnImgPath = Join-Path -Path $basepath -ChildPath $tnImgUrl.replace('/', '\')
                }

                if ($fullImgUrl) { $foundFile = Resolve-ImageFile -Path $fullImgPath }
                if (-not $foundFile -and $tnImgUrl) { $foundFile = Resolve-ImageFile -Path $tnImgPath }

                if (-not $foundFile) {
                    $stillMissing++
                    Write-Host "  STILL MISSING (genuine): $tnImgPath" -ForegroundColor Red
                    continue
                }
                $imagePath = $foundFile.FullName

                if ($DryRun) { Write-Host "  resolves: $($foundFile.Name)"; continue }

                # Live: validate it is an image, normalize, upload, rewrite the <img> src (and wrapping <a> href)
                if (-not (Invoke-ImageTest $imagePath)) {
                    $stillMissing++
                    Write-Host "  not detected as an image (skipped): $imagePath" -ForegroundColor Yellow
                    continue
                }
                $imageInfo = Normalize-And-ConvertImage -InputPath $imagePath
                $imagePath = $imageInfo.FinalPath ?? $imagePath
                $UploadImage = New-HuduPublicPhoto -FilePath $imagePath.ToLower() -record_id $huduId -record_type 'Article'
                $NewImageURL = $UploadImage.public_photo.url.replace($HuduBaseDomain, '')
                $imageObject.src = [string]$NewImageURL
                $ImgLink = ($html.Links | Where-Object { $imageObject.innerHTML -eq $imgHTML }) | Select-Object -First 1
                if ($ImgLink -and $ImgLink.PSObject.Properties.Match('href')) { $ImgLink.href = [string]$NewImageURL }
                $uploaded++
                Write-Host "  uploaded -> $NewImageURL"
            }
        }
    }

    if (-not $DryRun -and $uploaded -gt 0) {
        $page_out = [regex]::replace($html.documentelement.outerhtml, '\xa0+', ' ')
        $useGlobalKB = if ($null -ne $Article.PSObject.Properties['IsGlobalKBArticle']) {
            [bool]$Article.IsGlobalKBArticle
        } else {
            [bool]($Article.company.InternalCompany -and -not $PlaceInternalDocsInInternalCompany)
        }
        $ArticleSplat = @{ article_id = $huduId; name = $Article.name; content = $page_out }
        if (-not $useGlobalKB) { $ArticleSplat.company_id = $Article.company.HuduID }
        $null = Set-HuduArticle @ArticleSplat
        $processed += "$huduId"
        Write-Host "  article body updated." -ForegroundColor Green
    }

    [pscustomobject]@{
        HuduID       = $huduId
        Article      = $Article.Name
        Company      = $Article.Company.CompanyName
        Status       = $(if ($DryRun) { 'dry-run' } else { 'processed' })
        ImgTotal     = $imgTotal
        Uploaded     = $uploaded
        StillMissing = $stillMissing
        HuduURL      = $Article.HuduObject.url
    }
}

# --- Summary + report ---
$report | Format-Table HuduID, Company, Article, Status, ImgTotal, Uploaded, StillMissing -AutoSize | Out-Host
$stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
$reportPath = Join-Path $MigrationLogs "BracketImageRepair-$stamp.json"
$report | ConvertTo-Json -Depth 10 | Out-File -LiteralPath $reportPath
if (-not $DryRun) { $processed | Select-Object -Unique | ConvertTo-Json | Out-File -LiteralPath $stateFile }

Write-Host ("`nTotals: articles={0}  images={1}  uploaded={2}  stillMissing={3}" -f `
    @($report).Count,
    (@($report) | Measure-Object -Property ImgTotal -Sum).Sum,
    (@($report) | Measure-Object -Property Uploaded -Sum).Sum,
    (@($report) | Measure-Object -Property StillMissing -Sum).Sum) -ForegroundColor Cyan
Write-Host "Report: $reportPath"
if ($DryRun) { Write-Host 'DRY RUN complete - no uploads or article changes were made.' -ForegroundColor Green }
