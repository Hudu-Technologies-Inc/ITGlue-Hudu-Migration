#requires -Version 7.2
# Offline matching and create/recovery checks; no Hudu or IT Glue requests.
param([switch]$Benchmark)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
. "$repoRoot/Public/CompanyMatching.ps1"
$checks = 0
function Assert-CompanyMatch {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    $script:checks++
}
function Get-CompanyError {
    param([scriptblock]$Action)
    try { $null = & $Action } catch { return $_.Exception.Message }
    throw 'Expected company matching/creation to fail.'
}
function New-TestOrganization {
    param($Id, $Name, $Type = 'Client')
    [pscustomobject]@{ id = $Id; attributes = @{
        name = $Name; 'organization-type-name' = $Type; 'short-name' = 'short'
        'quick-notes' = ''; alert = ''
    } }
}

$hudu = @(@{ id = 1; name = 'Davis, Mike & Diane' }, @{ id = 2; name = 'Graham, Malise & Margaret' })
$huduLookup = New-HuduCompanyNameLookup $hudu
Assert-CompanyMatch ((Find-HuduCompanyNameMatch 'Davis, Mike &  Diane' $huduLookup).id -eq 1) 'Doubled spaces prevented matching Davis.'
Assert-CompanyMatch ((Find-HuduCompanyNameMatch 'Graham,  Malise & Margaret' $huduLookup).id -eq 2) 'Doubled spaces prevented matching Graham.'
Assert-CompanyMatch ((Find-HuduCompanyNameMatch 'davis, mike & diane' $huduLookup).id -eq 1) 'Case-insensitive matching was lost.'
Assert-CompanyMatch ((Find-HuduCompanyNameMatch " `tDavis,`u{a0}Mike &`nDiane  " $huduLookup).id -eq 1) 'Unicode whitespace, trim, or newline normalization failed.'
foreach ($pair in @(@('A&B', 'AB'), @('A&B', 'A and B'), @('Company, Inc.', 'Company Inc'), @('Café', 'Cafe'))) {
    Assert-CompanyMatch ($null -eq (Find-HuduCompanyNameMatch $pair[0] (New-HuduCompanyNameLookup @(@{ id = 4; name = $pair[1] })))) "Normalization merged distinct company names: $($pair -join ' / ')."
}
Assert-CompanyMatch ((Get-HuduCompanyNameKey '株式会社') -ceq '株式会社') 'Normalization stripped non-Latin names.'
Assert-CompanyMatch ($null -eq (Find-HuduCompanyNameMatch 'Missing' $huduLookup)) 'An unrelated company was selected.'
Assert-CompanyMatch ($null -eq (Find-HuduCompanyNameMatch 'Invalid' (New-HuduCompanyNameLookup @(@{ id = 0; name = 'Invalid' }, @{ name = 'Invalid' })))) 'A company without a valid ID was matched.'
$ambiguous = @(@{ id = 10; name = 'Acme  Services' }, @{ id = 20; name = 'Acme Services ' })
$ambiguousLookup = New-HuduCompanyNameLookup $ambiguous
$message = Get-CompanyError { Find-HuduCompanyNameMatch ' acme services' $ambiguousLookup }
Assert-CompanyMatch ($message -like '*Ambiguous*ID 10*' -or $message -like '*Ambiguous*ID 20*') 'Ambiguous normalized names did not produce an actionable error.'
Assert-CompanyMatch ((Find-HuduCompanyNameMatch 'Acme  Services' $ambiguousLookup).id -eq 10) 'A unique literal match was not preferred.'
$repeatedLookup = New-HuduCompanyNameLookup @(@{ id = 5; name = 'Same' }, @{ id = 5; name = 'Same' })
Assert-CompanyMatch ((Find-HuduCompanyNameMatch 'Same' $repeatedLookup).id -eq 5) 'Repeated API rows for the same ID caused ambiguity.'
$message = Get-CompanyError { Find-HuduCompanyNameMatch 'Same' (New-HuduCompanyNameLookup @(@{ id = 5; name = 'Same' }, @{ id = 6; name = 'SAME' })) }
Assert-CompanyMatch ($message -like '*Ambiguous*') 'Several literal matches silently selected one company.'

$createCalls = [Collections.Generic.List[object]]::new()
$refreshCalls = [int[]]@(0)
$createMode = 'success'; $freshCompanies = @(); $refreshFails = $false
function New-HuduCompany {
    [CmdletBinding()]
    param($Name, $Nickname, $Notes, $CompanyType, $address_line_1, $address_line_2, $city, $state, $zip, $country_name, $phone_number, $fax_number)
    $createCalls.Add(@{} + $PSBoundParameters)
    switch ($createMode) {
        'success' { @{ company = @{ id = 101; name = $Name } } }
        'null' { return $null }
        'missing-id' { @{ company = @{ name = $Name } } }
        'zero-id' { @{ company = @{ id = 0; name = $Name } } }
        'throw' { throw 'Name has already been taken' }
    }
}
function Get-HuduCompanies {
    [CmdletBinding()]
    param()
    $refreshCalls[0]++
    if ($refreshFails) { throw 'offline refresh failure' }
    return $freshCompanies
}
$result = New-HuduMigrationCompany -CompanySplat @{ Name = 'Davis, Mike &  Diane' } -CompanyLookup $huduLookup
Assert-CompanyMatch (-not $result.Created -and $result.Company.id -eq 1 -and $createCalls.Count -eq 0 -and $refreshCalls[0] -eq 0) 'A known company triggered a create or refresh.'
$createdLookup = @{}
$result = New-HuduMigrationCompany -CompanySplat @{ Name = 'New Company' } -CompanyLookup $createdLookup
Assert-CompanyMatch ($result.Created -and $result.Company.id -eq 101 -and $createCalls.Count -eq 1 -and $refreshCalls[0] -eq 0) 'A valid create was lost or refreshed unnecessarily.'
Assert-CompanyMatch ((Find-HuduCompanyNameMatch 'new  company' $createdLookup).id -eq 101) 'A new company was not added to the shared lookup.'
foreach ($createMode in @('null', 'missing-id', 'zero-id', 'throw')) {
    $freshCompanies = $hudu; $before = $refreshCalls[0]
    $recoveryLookup = @{}
    $result = New-HuduMigrationCompany -CompanySplat @{ Name = 'Graham,  Malise & Margaret' } -CompanyLookup $recoveryLookup 6>$null
    Assert-CompanyMatch (-not $result.Created -and $result.Company.id -eq 2 -and $refreshCalls[0] -eq $before + 1) "A $createMode response did not recover exactly once from refreshed companies."
    $freshCompanies = @(); $before = $refreshCalls[0]
    Assert-CompanyMatch ((Find-HuduCompanyNameMatch 'Davis, Mike &  Diane' $recoveryLookup).id -eq 1) 'A recovery discarded the other refreshed company names.'
    $message = Get-CompanyError { New-HuduMigrationCompany -CompanySplat @{ Name = 'Unrecoverable' } -CompanyLookup @{} }
    Assert-CompanyMatch ($message -like "*Could not create or match Hudu company 'Unrecoverable'*" -and $refreshCalls[0] -eq $before + 1) "A $createMode response was silently accepted or retried indefinitely."
}
$createMode = 'null'; $freshCompanies = $ambiguous
$message = Get-CompanyError { New-HuduMigrationCompany -CompanySplat @{ Name = ' acme services' } -CompanyLookup @{} }
Assert-CompanyMatch ($message -like '*Ambiguous*') 'Recovery adopted an ambiguous company.'
$refreshFails = $true
$message = Get-CompanyError { New-HuduMigrationCompany -CompanySplat @{ Name = 'Unavailable' } -CompanyLookup @{} }
Assert-CompanyMatch ($message -like '*Refresh failed*offline refresh failure*') 'A refresh failure was hidden.'
$refreshFails = $false

# Exercise the actual main-script matching loop, including source duplicates,
# real suffix names, internal-company routing, and explicit organization merges.
$source = Get-Content -LiteralPath "$repoRoot/ITGlue-Hudu-Migration.ps1" -Raw
$start = $source.IndexOf('    $nameTracker = @{}')
$end = $source.IndexOf('    foreach ($ITGC in $MatchedCompanies)', $start)
$matching = [scriptblock]::Create($source.Substring($start, $end - $start))

# A lookup must read destination names only once, even across repeated searches.
$script:companyNameReads = 0
$countedCompanies = @(1..100 | ForEach-Object {
    $company = [pscustomobject]@{ id = $_; SourceName = "Company $_" }
    $company | Add-Member -MemberType ScriptProperty -Name name -Value { $script:companyNameReads++; $this.SourceName }
    $company
})
$countedLookup = New-HuduCompanyNameLookup $countedCompanies
foreach ($round in 1..3) {
    foreach ($id in 1..100) { $null = Find-HuduCompanyNameMatch " company  $id " $countedLookup }
}
Assert-CompanyMatch ($script:companyNameReads -eq 100) 'Matching rescanned or renormalized destination company names.'
& {
    $InternalCompany = ' DAVIS, MIKE & DIANE '
    $MergedOrganizationSettings = @{ Types = @(); TargetCompany = $null }
    $HuduCompanies = @($hudu) + @(@{ id = 3; name = 'Acme' }, @{ id = 4; name = 'Acme-1' }, @{ id = 5; name = 'Acme-2' })
    $ITGCompanies = @(
        (New-TestOrganization 1 'Davis, Mike &  Diane'), (New-TestOrganization 2 'Graham,  Malise & Margaret'),
        (New-TestOrganization 3 'Acme'), (New-TestOrganization 4 ' acme '), (New-TestOrganization 5 'Acme-1')
    )
    . $matching
    Assert-CompanyMatch ($MatchedCompanies.Count -eq 5 -and @($MatchedCompanies | Where-Object { -not $_.Matched }).Count -eq 0) 'The main loop missed an existing normalized company.'
    Assert-CompanyMatch (($MatchedCompanies.HuduID -join ',') -ceq '1,2,3,5,4') 'Duplicate source names were merged or suffixes collided with a real source name.'
    Assert-CompanyMatch ($MatchedCompanies[0].InternalCompany -and -not $MatchedCompanies[1].InternalCompany) 'Internal-company matching used different normalization.'
    Assert-CompanyMatch ($MatchedCompanies[0].ITGCompanyObject.attributes.name -ceq 'Davis, Mike &  Diane') 'Matching changed the source name.'
    $MergedOrganizationSettings = @{ Types = @('Client'); TargetCompany = @{ id = 88; name = 'Merge Target' } }
    $HuduCompanies = $ambiguous
    $ITGCompanies = @((New-TestOrganization 6 ' acme services'))
    . $matching
    Assert-CompanyMatch ($MatchedCompanies[0].HuduID -eq 88) 'An explicit organization merge was overridden by name matching.'
}

# Execute the real create body. Successful creation/recovery must update the
# caller mapping, while a failed create must never mark it matched or reuse a
# previous company's ID, increment its count, or announce success.
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'ITGlue-Hudu-Migration.ps1'), [ref]$tokens, [ref]$errors)
$loop = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.ForEachStatementAst] -and $node.Variable.VariablePath.UserPath -eq 'unmatchedcompany' }, $true))
Assert-CompanyMatch ($errors.Count -eq 0 -and $loop.Count -eq 1) 'Could not locate the main company creation body.'
$createBody = [scriptblock]::Create($loop[0].Body.Extent.Text.Trim().Substring(1).TrimEnd().TrimEnd('}'))
foreach ($withLocation in @($false, $true)) {
    foreach ($scenario in @('success', 'recovered', 'failed')) {
        & {
            $unmatchedcompany = [pscustomobject]@{
                CompanyName = 'Graham,  Malise & Margaret'; ITGID = 7; HuduID = ''; Matched = $false; HuduCompanyObject = ''; Imported = ''
                ITGCompanyObject = (New-TestOrganization 7 'Graham,  Malise & Margaret')
            }
            $ITGCompaniesFromCSV = @(@{ id = 7; quick_notes = 'notes'; alert = 'alert' })
            $ITGLocations = if ($withLocation) { @([pscustomobject]@{ attributes = @{ 'organization-id' = 7; primary = $true; 'address-1' = '123 Main St' } }) } else { @() }
            $HuduCompanies = @(); $HuduCompanyNameLookup = @{}; $CompaniesMigrated = 0; $HuduNewCompany = @{ id = 9999 }
            $importCOption = 'A'
            function Confirm-Import { param($ImportObjectName, $ImportObject, $ImportSetting) }
            $createMode = if ($scenario -eq 'success') { 'success' } else { 'null' }
            $freshCompanies = if ($scenario -eq 'recovered') { $hudu } else { @() }
            $failed = $false
            try {
                Set-StrictMode -Off
                $output = (. $createBody 6>&1 | Out-String)
            } catch { $failed = $true } finally { Set-StrictMode -Version Latest }
            if ($scenario -eq 'failed') {
                Assert-CompanyMatch ($failed -and -not $unmatchedcompany.Matched -and $unmatchedcompany.HuduID -eq '' -and $CompaniesMigrated -eq 0 -and $null -eq $HuduNewCompany) 'A failed create acquired a stale ID or was recorded as successful.'
            } else {
                $expectedId = if ($scenario -eq 'success') { 101 } else { 2 }
                Assert-CompanyMatch (-not $failed -and $unmatchedcompany.Matched -and $unmatchedcompany.HuduID -eq $expectedId) 'The main create body did not retain the correct company ID.'
                Assert-CompanyMatch ($CompaniesMigrated -eq [int]($scenario -eq 'success')) 'A recovered existing company was counted as created.'
                Assert-CompanyMatch ($output.Contains('Has been created in Hudu') -eq ($scenario -eq 'success')) 'The main script announced a recovered match as a new create.'
                Assert-CompanyMatch ($createCalls[-1].CompanyType -eq 'Client' -and $createCalls[-1].notes -like '*alert*notes*') 'Company notes or type were lost in a create branch.'
                Assert-CompanyMatch ($createCalls[-1].ContainsKey('address_line_1') -eq $withLocation) 'Address data was lost or added without a primary location.'
            }
        }
    }
}
if ($Benchmark) {
    & {
        $InternalCompany = 'Company 1'
        $MergedOrganizationSettings = @{ Types = @(); TargetCompany = $null }
        $HuduCompanies = @(1..2588 | ForEach-Object { [pscustomobject]@{ id = $_; name = "Company $_" } })
        $ITGCompanies = @(1..2588 | ForEach-Object { New-TestOrganization $_ " company  $_ " })
        $watch = [Diagnostics.Stopwatch]::StartNew()
        . $matching
        $watch.Stop()
        Assert-CompanyMatch ($MatchedCompanies.Count -eq 2588 -and @($MatchedCompanies | Where-Object { $_.HuduID -ne $_.ITGID }).Count -eq 0) 'The large matching workload lost or misrouted companies.'
        Write-Output ('Matched 2,588 IT Glue companies against 2,588 Hudu companies in {0:N3}s, including lookup construction (synthetic, offline).' -f $watch.Elapsed.TotalSeconds)
    }
}
Write-Output "Passed $checks company matching and create/recovery checks (offline)."
