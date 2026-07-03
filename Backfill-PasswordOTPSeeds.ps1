<#
.SYNOPSIS
    Backfill TOTP/OTP seeds onto Hudu passwords that lost them during migration.

.DESCRIPTION
    The migration validated each IT Glue OTP seed and silently dropped any that wasn't pure base32 or
    fell outside 16-80 chars (only a Write-Warning, no manual action), so some Hudu passwords have an
    empty otp_secret while IT Glue held a valid seed. This audits the completed migration's Passwords
    log, finds every password whose IT Glue seed is present but whose Hudu seed is empty, normalises the
    seed (otpauth:// URIs, padding, display spaces, long-but-valid base32) via the shared
    ConvertTo-NormalizedOtpSecret, and pushes it with Set-HuduPassword -OTPSecret. Seeds that are still
    not valid base32 after normalisation are reported for manual confirmation - never guessed.

    The Passwords.json log alone drives this (it carries HuduID + the original IT Glue seed), so no
    re-run of the migration is required. Re-running is safe: only empty Hudu seeds are filled.

.PARAMETER DryRun
    Report which passwords WOULD be backfilled (and which need manual confirmation); no writes.
.PARAMETER MigrationLogsPath
    Path to the completed migration's \logs folder (contains Passwords.json).
.PARAMETER SettingsJsonPath
    Path to settings.json (defaults to <MigrationLogsParent>\settings\settings.json).
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

# --- Non-interactive settings import (same pattern as the other remediation scripts) ---
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
. $PSScriptRoot\Private\ConvertTo-NormalizedOtpSecret.ps1

$HuduBaseDomain = $HuduBaseDomain ?? $environmentSettings.HuduBaseDomain
if ($MigrationLogsPath) { $MigrationLogs = $MigrationLogsPath }
$MigrationLogs  = $MigrationLogs ?? $environmentSettings.MigrationLogs
if (-not $HuduAPIKey) { $HuduAPIKey = ConvertSecureStringToPlainText -SecureString ($environmentSettings.HuduAPIKey | ConvertTo-SecureString) }

# Hudu auth is required to WRITE seeds (and to re-read for confirmation). Reads are needed for dry-run too.
$null = Set-ExternalModulesInitialized -HuduBaseURL $HuduBaseDomain -HuduAPIKey $HuduAPIKey -RefreshHuduApiForkEachRun:(!$SkipFork)

# --- Load the migrated password records (standalone + asset-embedded) ---
function Import-PwLog($file) {
    $p = "$MigrationLogs\$file"
    if ((Test-Path -LiteralPath $p) -and (Get-Item -LiteralPath $p).Length -gt 0) {
        @(Get-Content -LiteralPath $p -Raw | ConvertFrom-Json -Depth 100)
    } else { @() }
}
$records = @(Import-PwLog 'Passwords.json') + @(Import-PwLog 'AssetPasswords.json')
Write-Host ("Loaded {0} password records" -f $records.Count) -ForegroundColor Cyan

# Suggest an obvious base32 transcription fix for reporting (never auto-applied): 1->I, 0->O, 8->B.
function Get-Base32Suggestion($raw) {
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    $try = ((($raw.Trim().ToUpperInvariant()) -replace '\s','') -replace '=+$','') `
        -replace '1','I' -replace '0','O' -replace '8','B'
    if ($try -match '^[A-Z2-7]+$' -and $try.Length -ge 16) { return $try } else { return $null }
}

$fixed = [System.Collections.Generic.List[object]]::new()
$needsConfirm = [System.Collections.Generic.List[object]]::new()
$alreadyOk = 0; $noItgSeed = 0; $failed = 0

foreach ($p in $records) {
    $srcRaw = [string]$p.ITGObject.attributes.otp_secret
    if ([string]::IsNullOrWhiteSpace($srcRaw)) { $noItgSeed++; continue }      # nothing to migrate
    $huduSeed = [string]$p.HuduObject.otp_secret
    if (-not [string]::IsNullOrWhiteSpace($huduSeed)) { $alreadyOk++; continue } # Hudu already has a seed

    # IT Glue had a seed, Hudu is empty -> a drop. Try to normalise it.
    $hid  = if ($p.HuduObject.id) { $p.HuduObject.id } else { $p.HuduID }
    $name = [string]$p.Name
    $url  = [string]$p.HuduObject.url
    $norm = ConvertTo-NormalizedOtpSecret $srcRaw

    if (-not $norm) {
        $needsConfirm.Add([pscustomobject]@{
            Name = $name; HuduID = $hid; Hudu_URL = $url
            RawSeedPreview = if ($srcRaw.Length -gt 60) { $srcRaw.Substring(0,60) + '...' } else { $srcRaw }
            Suggestion = Get-Base32Suggestion $srcRaw
            Note = 'IT Glue seed is not valid base32 after normalisation - confirm the correct seed before pushing.'
        })
        continue
    }

    if ($DryRun) {
        $fixed.Add([pscustomobject]@{ Name=$name; HuduID=$hid; Hudu_URL=$url; SeedLength=$norm.Length; Status='would-backfill' })
        continue
    }

    try {
        $upd = Set-HuduPassword -Id $hid -OTPSecret $norm
        $landed = [string]$upd.asset_password.otp_secret
        if (-not [string]::IsNullOrWhiteSpace($landed)) {
            $fixed.Add([pscustomobject]@{ Name=$name; HuduID=$hid; Hudu_URL=$url; SeedLength=$norm.Length; Status='backfilled' })
            Write-Host ("  backfilled OTP for {0} (id {1})" -f $name, $hid) -ForegroundColor Green
        } else {
            $failed++
            $needsConfirm.Add([pscustomobject]@{ Name=$name; HuduID=$hid; Hudu_URL=$url; RawSeedPreview=''; Suggestion=$null
                Note = "Push returned an empty otp_secret - Hudu may have rejected the seed (length $($norm.Length)?). Verify manually." })
            Write-Host ("  WARNING: seed did not stick for {0} (id {1})" -f $name, $hid) -ForegroundColor Red
        }
    } catch {
        $failed++
        Write-Warning ("  failed to set OTP for {0} (id {1}): {2}" -f $name, $hid, $_)
    }
}

# --- Report ---
Write-Host ("`nPasswords with an IT Glue seed already in Hudu: {0}" -f $alreadyOk) -ForegroundColor DarkGray
Write-Host ("$(if($DryRun){'Would backfill'}else{'Backfilled'}): {0}   Need manual confirmation: {1}   Failed: {2}" -f $fixed.Count, $needsConfirm.Count, $failed) -ForegroundColor Cyan

if ($fixed.Count) {
    Write-Host "`n--- Verify each of these against your authenticator (name -> Hudu URL) ---" -ForegroundColor Yellow
    $fixed | ForEach-Object { Write-Host ("  {0,-45} {1}" -f $_.Name, $_.Hudu_URL) }
}
if ($needsConfirm.Count) {
    Write-Host "`n--- Need manual confirmation (NOT changed) ---" -ForegroundColor Yellow
    $needsConfirm | ForEach-Object {
        Write-Host ("  {0,-45} {1}" -f $_.Name, $_.Hudu_URL)
        if ($_.Suggestion) { Write-Host ("      likely-correct seed: {0}" -f $_.Suggestion) -ForegroundColor DarkYellow }
    }
}

$stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
[pscustomobject]@{ Fixed=$fixed; NeedsConfirmation=$needsConfirm; AlreadyOk=$alreadyOk; Failed=$failed; DryRun=[bool]$DryRun } |
    ConvertTo-Json -Depth 6 | Out-File -LiteralPath (Join-Path $MigrationLogs "OTPSeedBackfill-$stamp.json")
Write-Host ("`nReport: {0}" -f (Join-Path $MigrationLogs "OTPSeedBackfill-$stamp.json"))
if ($DryRun) { Write-Host 'DRY RUN - no passwords were changed.' -ForegroundColor Green }
