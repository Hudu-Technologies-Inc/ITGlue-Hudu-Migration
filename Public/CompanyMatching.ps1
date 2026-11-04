function Get-HuduCompanyNameKey {
    param([AllowNull()][string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) { return '' }
    return ([regex]::Replace($Name, '\s+', ' ').Trim()).ToUpperInvariant()
}

function Get-HuduCompanyProperty {
    param($Company, [string]$Name)

    if ($null -eq $Company) { return $null }
    if ($Company -is [System.Collections.IDictionary]) { return $Company[$Name] }
    $property = $Company.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    return $null
}

function New-HuduCompanyNameLookup {
    param(
        [AllowNull()][AllowEmptyCollection()][object[]]$Companies
    )

    $lookup = @{}
    foreach ($company in $Companies) {
        $id = Get-HuduCompanyProperty $company 'id'
        $numericId = 0L
        if (-not [long]::TryParse([string]$id, [ref]$numericId) -or $numericId -le 0) { continue }
        $key = Get-HuduCompanyNameKey ([string](Get-HuduCompanyProperty $company 'name'))
        if (-not $key) { continue }
        if (-not $lookup.ContainsKey($key)) {
            $lookup[$key] = @($company)
        } elseif ($lookup[$key].id -notcontains $id) {
            $lookup[$key] += $company
        }
    }
    return $lookup
}

function Find-HuduCompanyNameMatch {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][hashtable]$Lookup
    )

    $key = Get-HuduCompanyNameKey $Name
    if (-not $key) { throw 'A nonblank company name is required for matching.' }
    if (-not $Lookup.ContainsKey($key)) { return $null }
    $matches = $Lookup[$key]
    if ($matches.Count -gt 1) {
        # Only inspect literal names for a colliding bucket, never the full list.
        $exact = @($matches | Where-Object { [string]::Equals($Name, $_.name, [StringComparison]::OrdinalIgnoreCase) })
        if ($exact.Count -eq 1) { return $exact[0] }
        $candidates = ($matches | ForEach-Object { "'$(Get-HuduCompanyProperty $_ 'name')' (ID $(Get-HuduCompanyProperty $_ 'id'))" }) -join ', '
        throw "Ambiguous Hudu company match for '$Name': $candidates. Resolve the duplicate company names before migrating."
    }
    if ($matches.Count -eq 1) { return $matches[0] }
    return $null
}

function New-HuduMigrationCompany {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$CompanySplat,
        [Parameter(Mandatory)][hashtable]$CompanyLookup
    )

    $name = [string]$CompanySplat['Name']
    $existing = Find-HuduCompanyNameMatch -Name $name -Lookup $CompanyLookup
    if ($existing) { return [pscustomobject]@{ Company = $existing; Created = $false } }

    $response = $null
    $failure = 'New-HuduCompany returned no valid company ID.'
    try {
        $response = New-HuduCompany @CompanySplat -ErrorAction Stop
    } catch {
        $failure = $_.Exception.Message
    }
    $company = Get-HuduCompanyProperty $response 'company'
    $id = Get-HuduCompanyProperty $company 'id'
    $numericId = 0L
    if ([long]::TryParse([string]$id, [ref]$numericId) -and $numericId -gt 0) {
        $CompanyLookup[(Get-HuduCompanyNameKey $name)] = @($company)
        return [pscustomobject]@{ Company = $company; Created = $true }
    }

    # HuduAPI can log an API error and return null instead of throwing. Refresh
    # once to recover an existing name or a create whose response was lost.
    try {
        $freshCompanies = @(Get-HuduCompanies -ErrorAction Stop)
        $freshLookup = New-HuduCompanyNameLookup -Companies $freshCompanies
        $CompanyLookup.Clear()
        foreach ($key in $freshLookup.Keys) { $CompanyLookup[$key] = $freshLookup[$key] }
        $existing = Find-HuduCompanyNameMatch -Name $name -Lookup $CompanyLookup
    } catch {
        throw "Could not create or match Hudu company '$name': $failure Refresh failed: $($_.Exception.Message)"
    }
    if ($existing) {
        Write-Host "Matched existing Hudu company '$($existing.name)' (ID $($existing.id)) after refreshing companies." -ForegroundColor Cyan
        return [pscustomobject]@{ Company = $existing; Created = $false }
    }
    throw "Could not create or match Hudu company '$name': $failure No unique existing company was found after refreshing."
}
