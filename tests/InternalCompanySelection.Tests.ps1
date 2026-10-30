#requires -Version 7.2
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
. "$repoRoot/Public/Normalize-String.ps1"
$checks = 0
function Assert-CompanySelection {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    $script:checks++
}
function New-TestCompany {
    param([string]$Name, [string]$Id, [bool]$Internal = $false)
    [pscustomobject]@{CompanyName=$Name; ITGID=$Id; InternalCompany=$Internal; HuduID=100}
}
$pickerCalls = 0; $pickIndex = 0; $invalidSelection = $false
$lastOptions = @(); $lastMessage = ''; $lastAllowNull = $true
function Select-ObjectFromList {
    param($objects, $message, $allowNull)
    $script:pickerCalls++
    $script:lastOptions = @($objects)
    $script:lastMessage = $message
    $script:lastAllowNull = $allowNull
    if ($invalidSelection) { return $null }
    return $objects[$pickIndex]
}

$message = (& { Write-InternalCompanyValidationError -Matches $null -InternalCompany 'Internal' } 6>&1 | Out-String)
Assert-CompanySelection ($message -match '0 matches' -and $message -notmatch 'found 1') 'Null matches were not reported as zero.'
$message = (& { Write-InternalCompanyValidationError -Matches @($null, $null) -InternalCompany 'Internal' } 6>&1 | Out-String)
Assert-CompanySelection ($message -match '0 matches') 'Null entries were counted as organizations.'
$single = New-TestCompany 'Internal' '10' $true
$message = (& { Write-InternalCompanyValidationError -Matches @($null, $single) -InternalCompany 'Internal' } 6>&1 | Out-String)
Assert-CompanySelection ([string]::IsNullOrWhiteSpace($message)) 'One actual match was incorrectly reported as a validation failure.'
$resolved = Resolve-InternalCompany -Companies @($null, $single) -InternalCompany 'Internal' -NonInteractive
Assert-CompanySelection ([object]::ReferenceEquals($resolved, $single) -and $pickerCalls -eq 0) 'One matching company prompted unnecessarily or lost the original mapping.'

$first = New-TestCompany 'Internal' '10' $true
$second = New-TestCompany 'Internal-1' '20' $true
$other = New-TestCompany 'Client' '30'
$companies = @($first, $other, $second)
$lookup = @{'10'=$first; '20'=$second; '30'=$other}
$pickIndex = 1
$resolved = Resolve-InternalCompany -Companies $companies -InternalCompany 'Internal' 6>$null
Assert-CompanySelection ($lastOptions.Count -eq 2 -and @($lastOptions.Company.ITGID | Where-Object { $_ -eq '30' }).Count -eq 0) 'Duplicate-name selection included an unrelated company.'
Assert-CompanySelection ($lastOptions[0].OptionMessage -match 'ITGlue ID: 10' -and $lastOptions[1].OptionMessage -match 'ITGlue ID: 20' -and -not $lastAllowNull) 'Picker labels did not distinguish duplicates by ITGlue ID or permitted an empty choice.'
Assert-CompanySelection ([object]::ReferenceEquals($resolved, $second) -and @($companies | Where-Object InternalCompany).Count -eq 1 -and $second.InternalCompany) 'The selected duplicate did not become the only internal company.'
Assert-CompanySelection (-not $lookup['10'].InternalCompany -and $lookup['20'].InternalCompany) 'Existing company lookup references did not receive the corrected internal flags.'

$alpha = New-TestCompany 'Alpha' '1'
$beta = New-TestCompany 'Beta' '2'
$resolved = Resolve-InternalCompany -Companies @($beta, $null, $alpha) -InternalCompany 'Missing' 6>$null
Assert-CompanySelection ($lastOptions.Count -eq 2 -and $lastOptions[0].Company.ITGID -eq '1' -and $lastOptions[1].Company.ITGID -eq '2') 'Zero matches did not offer every company in scope, excluding nulls.'
Assert-CompanySelection ([object]::ReferenceEquals($resolved, $beta) -and $beta.InternalCompany -and -not $alpha.InternalCompany -and $lastMessage -like '*organizations in this migration*') 'A missing-name choice did not update the selected company correctly.'
$before = $pickerCalls
$resumed = @($alpha, $beta) | ConvertTo-Json | ConvertFrom-Json
$resolved = Resolve-InternalCompany -Companies $resumed -InternalCompany 'Missing' -NonInteractive
Assert-CompanySelection ($resolved.ITGID -eq '2' -and $pickerCalls -eq $before) 'A saved company selection was lost when reloading company mappings.'

foreach ($duplicate in @($false, $true)) {
    $companies = @(New-TestCompany 'Internal' '10' $duplicate; New-TestCompany 'Internal-1' '20' $duplicate)
    $message = ''
    try { $null = Resolve-InternalCompany -Companies $companies -InternalCompany 'Internal' -NonInteractive 6>$null } catch { $message = $_.Exception.Message }
    $expected = if ($duplicate) { 2 } else { 0 }
    Assert-CompanySelection ($message -like "*has $expected matches*Run interactively*" -and $pickerCalls -eq $before) 'Noninteractive resolution prompted or misreported the match count.'
    Assert-CompanySelection (@($companies | Where-Object InternalCompany).Count -eq $expected) 'A noninteractive failure changed internal-company routing.'
}
$message = ''
try { $null = Resolve-InternalCompany -Companies @($null) -InternalCompany 'Internal' 6>$null } catch { $message = $_.Exception.Message }
Assert-CompanySelection ($message -like '*No companies are available*' -and $pickerCalls -eq $before) 'An empty scope opened an unusable picker.'
$invalidSelection = $true
$company = New-TestCompany 'Client' '30'
$message = ''
try { $null = Resolve-InternalCompany -Companies @($company) -InternalCompany 'Missing' 6>$null } catch { $message = $_.Exception.Message }
Assert-CompanySelection ($message -like '*No valid internal company*' -and -not $company.InternalCompany) 'A cancelled selection changed internal-company routing.'
$invalidSelection = $false; $pickIndex = 0

# Exercise the actual migration validation block without running API/import work.
$migration = Get-Content -LiteralPath "$repoRoot/ITGlue-Hudu-Migration.ps1" -Raw
$validation = [regex]::Match($migration, '(?s)# Check if the internal company was found.*?\r?\n(?<block>.*?)\s*# Lets confirm it is the correct one').Groups['block'].Value
Assert-CompanySelection (-not [string]::IsNullOrWhiteSpace($validation)) 'Could not locate the migration internal-company validation block.'
$MatchedCompanies = @(New-TestCompany 'Chosen' '40'; New-TestCompany 'Other' '50')
$InternalCompany = 'Missing'; $PlaceInternalDocsInInternalCompany = $false; $NonInteractive = $false
& ([scriptblock]::Create($validation)) 6>$null
Assert-CompanySelection ($MatchedCompanies[0].InternalCompany -and -not $MatchedCompanies[1].InternalCompany) 'The main migration did not invoke selection for a missing internal company.'
$MatchedCompanies = @(New-TestCompany 'Internal' '10' $true; New-TestCompany 'Internal-1' '20' $true)
$InternalCompany = 'Internal'; $pickIndex = 1
& ([scriptblock]::Create($validation)) 6>$null
Assert-CompanySelection (-not $MatchedCompanies[0].InternalCompany -and $MatchedCompanies[1].InternalCompany) 'The main migration did not resolve duplicate internal-company flags.'
$MatchedCompanies = @(New-TestCompany 'Other' '50')
$PlaceInternalDocsInInternalCompany = $true; $before = $pickerCalls
& ([scriptblock]::Create($validation)) 6>$null
Assert-CompanySelection ($pickerCalls -eq $before) 'Optional internal-company matching became mandatory when documents stay company-scoped.'

Write-Output "Passed $checks internal-company selection checks (offline)."
