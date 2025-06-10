

#Check for Company Resume


#Import Companies
Write-Host "Fetching Companies from IT Glue" -ForegroundColor Green
$CompanySelect = { (Get-ITGlueOrganizations -page_size 1000 -page_number $i).data }
$ITGCompanies = Import-ITGlueItems -ItemSelect $CompanySelect
$ITGCompaniesFromCSV = Import-CSV (Join-Path -Path $ITGlueExportPath -ChildPath "organizations.csv")

Write-Host "$($ITGCompanies.count) ITG Glue Companies Found" 




$MatchedCompanies = foreach ($itgcompany in $ITGCompanies ) {
    $HuduCompany = $HuduCompanies | where-object -filter { $_.name -eq $itgcompany.attributes.name }
    if ($InternalCompany -eq $itgcompany.attributes.name) {
        $intCompany = $true
    } else {
        $intCompany = $false
    }

    if ($HuduCompany) {
        [PSCustomObject]@{
            "CompanyName"       = $itgcompany.attributes.name
            "ITGID"             = $itgcompany.id
            "HuduID"            = $HuduCompany.id
            "Matched"           = $true
            "InternalCompany"   = $intCompany
            "HuduCompanyObject" = $HuduCompany
            "ITGCompanyObject"  = $itgcompany
            "Imported"          = "Pre-Existing"
        
        }
    } else {
        [PSCustomObject]@{
            "CompanyName"       = $itgcompany.attributes.name
            "ITGID"             = $itgcompany.id
            "HuduID"            = ""
            "Matched"           = $false
            "InternalCompany"   = $intCompany
            "HuduCompanyObject" = ""
            "ITGCompanyObject"  = $itgcompany
            "Imported"          = ""
        }
    }
}

# Check if the internal company was found and that there was only 1 of them
$PrimaryCompany = $MatchedCompanies | Sort-Object CompanyName | Where-Object { $_.InternalCompany -eq $true } | Select-Object CompanyName

if (($PrimaryCompany | measure-object).count -ne 1) {
    Write-Host "A single Internal Company was not found please run the script again and check the company name entered exactly matches what is in ITGlue" -foregroundcolor red
    exit 1
}

# Lets confirm it is the correct one
Write-Host ""
Write-Host "Your Internal Company has been matched to: $(($MatchedCompanies | Sort-Object CompanyName | Where-Object {$_.InternalCompany -eq $true} | Select-Object CompanyName).companyname) in IT Glue"
Write-Host "The documents under this customer will be migrated to the Global KB in Hudu"
Write-Host ""
Write-TimedMessage -Message "Internal Company Correct? Press Return to continue or CTRL+C to quit if this is not correct" -Timeout 12 -DefaultResponse "Assuming found match on '$(($MatchedCompanies | Sort-Object CompanyName | Where-Object {$_.InternalCompany -eq $true} | Select-Object CompanyName).companyname)' is correct."

Write-Host "Matched Companies (Already exist so will not be migrated)"
$MatchedCompanies | Sort-Object CompanyName | Where-Object { $_.Matched -eq $true } | Select-Object CompanyName | Format-Table

Write-Host "Unmatched Companies"
$MatchedCompanies | Sort-Object CompanyName | Where-Object { $_.Matched -eq $false } | Select-Object CompanyName | Format-Table

#Import Locations
Write-Host "Fetching Locations from IT Glue" -ForegroundColor Green
$LocationsSelect = { (Get-ITGlueLocations -page_size 1000 -page_number $i -include related_items).data }
$ITGLocations = Import-ITGlueItems -ItemSelect $LocationsSelect


# Import Companies
$UnmappedCompanyCount = ($MatchedCompanies | Where-Object { $_.Matched -eq $false } | measure-object).count
if ($ImportCompanies -eq $true -and $UnmappedCompanyCount -gt 0) {

    $importCOption = Get-ImportMode -ImportName "Companies"

    if (($importCOption -eq "A") -or ($importCOption -eq "S") ) {		
        foreach ($unmatchedcompany in ($MatchedCompanies | Where-Object { $_.Matched -eq $false })) {
            $unmatchedcompany.ITGCompanyObject.attributes.'quick-notes' = ($ITGCompaniesFromCSV | Where-Object {$_.id -eq $unmatchedcompany.ITGID}).quick_notes
            $unmatchedcompany.ITGCompanyObject.attributes.alert = ($ITGCompaniesFromCSV | Where-Object {$_.id -eq $unmatchedcompany.ITGID}).alert
            Confirm-Import -ImportObjectName $unmatchedcompany.CompanyName -ImportObject $unmatchedcompany -ImportSetting $importCOption
                    
            Write-Host "Starting $($unmatchedcompany.CompanyName)"
            $PrimaryLocation = $ITGLocations | Where-Object { $unmatchedcompany.ITGID -eq $_.attributes."organization-id" -and $_.attributes.primary -eq $true }
            
            #Check for alerts in ITGlue on the organization
            if ($ITGlueAlert = $unmatchedcompany.ITGCompanyObject.attributes.alert) {
                $CompanyNotes = "<div class='callout callout-warning'>$ITGlueAlert</div>" + $unmatchedcompany.ITGCompanyObject.attributes."quick-notes"
            } else {
                $CompanyNotes = $unmatchedcompany.ITGCompanyObject.attributes."quick-notes"
            }

            if ($PrimaryLocation -and $PrimaryLocation.count -eq 1) {
                $CompanySplat = @{
                    "name"           = $unmatchedcompany.CompanyName
                    "nickname"       = $unmatchedcompany.ITGCompanyObject.attributes."short-name"
                    "address_line_1" = $PrimaryLocation.attributes."address-1"
                    "address_line_2" = $PrimaryLocation.attributes."address-2"
                    "city"           = $PrimaryLocation.attributes.city
                    "state"          = $PrimaryLocation.attributes."region-name"
                    "zip"            = $PrimaryLocation.attributes."postal-code"
                    "country_name"   = $PrimaryLocation.attributes."country-name"
                    "phone_number"   = $PrimaryLocation.attributes.phone
                    "fax_number"     = $PrimaryLocation.attributes.fax
                    "notes"          = $CompanyNotes
                    "CompanyType"    = $unmatchedcompany.ITGCompanyObject.attributes.'organization-type-name'
                }
                $HuduNewCompany = (New-HuduCompany @CompanySplat).company
                $CompaniesMigrated = $CompaniesMigrated + 1
            } else {
                Write-Host "No Location Found, creating company without address details"
                $HuduNewCompany = (New-HuduCompany -name $unmatchedcompany.CompanyName -nickname $unmatchedcompany.ITGCompanyObject.attributes."short-name" -notes $CompanyNotes -CompanyType $unmatchedcompany.attributes.'organization-type-name').company
                $CompaniesMigrated = $CompaniesMigrated + 1
            }
        
            $unmatchedcompany.matched = $true
            $unmatchedcompany.HuduID = $HuduNewCompany.id
            $unmatchedcompany.HuduCompanyObject = $HuduNewCompany
            $unmatchedcompany.Imported = "Created-By-Script"
        
            Write-host "$($unmatchedcompany.CompanyName) Has been created in Hudu"
            Write-Host ""
        }
    
    }
    

} else {
    if ($UnmappedCompanyCount -eq 0) {
        Write-Host "All Companies matched, no migration required" -foregroundcolor green
    } else {
        Write-Host "Warning Import Companies is set to disabled so the above unmatched companies will not have data migrated" -foregroundcolor red
        Write-TimedMessage -Message "Press any key to continue or CTRL+C to quit" -DefaultResponse "continue and wrap-up companies, please." -Timeout 6
    }
}

