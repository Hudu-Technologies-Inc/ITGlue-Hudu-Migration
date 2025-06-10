#Grab existing Websites in Hudu
$HuduWebsites = Get-HuduWebsites

#Import Websites
Write-Host "Fetching Domains from IT Glue" -ForegroundColor Green
$DomainSelect = { (Get-ITGlueDomains -page_size 1000 -page_number $i).data }
$ITGDomains = Import-ITGlueItems -ItemSelect $DomainSelect

Write-Host "$($ITGDomains.count) ITG Glue Domains Found" 

$MatchedWebsites = foreach ($itgdomain in $ITGDomains ) {
    $HuduWebsite = $HuduWebsites | where-object -filter { ($_.name -eq "https://$($itgdomain.attributes.name)" -and $_.company_name -eq $itgdomain.attributes."organization-name") }

    if ($HuduWebsite) {
        [PSCustomObject]@{
            "Name"       = $itgdomain.attributes.name
            "ITGID"      = $itgdomain.id
            "HuduID"     = $HuduWebsite.id
            "Matched"    = $true
            "HuduObject" = $HuduWebsite
            "ITGObject"  = $itgdomain
            "Imported"   = "Pre-Existing"

        }
    } else {
        [PSCustomObject]@{
            "Name"       = $itgdomain.attributes.name
            "ITGID"      = $itgdomain.id
            "HuduID"     = ""
            "Matched"    = $false
            "HuduObject" = ""
            "ITGObject"  = $itgdomain
            "Imported"   = ""
        }
    }
}


Write-Host "Matched Websites / Domains (Already exist so will not be migrated)"
$MatchedWebsites | Sort-Object Name | Where-Object { $_.Matched -eq $true } | Select-Object Name | Format-Table

Write-Host "Unmatched Websites / Domains"
$MatchedWebsites | Sort-Object Name | Where-Object { $_.Matched -eq $false } | Select-Object Name | Format-Table

$UnmappedWebsiteCount = ($MatchedWebsites | Where-Object { $_.Matched -eq $false } | measure-object).count

if ($ImportDomains -eq $true -and $UnmappedWebsiteCount -gt 0) {

    $importOption = Get-ImportMode -ImportName "Websites / Domains"

    if (($importOption -eq "A") -or ($importOption -eq "S") ) {		

        foreach ($company in $CompaniesToMigrate) {
            Write-Host "Migrating $($company.CompanyName)" -ForegroundColor Green

            foreach ($unmatchedWebsite in ($MatchedWebsites | Where-Object { $_.Matched -eq $false -and $company.ITGCompanyObject.id -eq $_."ITGObject".attributes."organization-id" })) {
            

                Confirm-Import -ImportObjectName "$($unmatchedWebsite.Name)" -ImportObject $unmatchedWebsite -ImportSetting $ImportOption

                Write-Host "Starting $($unmatchedWebsite.Name);"
                $HuduNewWebsite = New-HuduWebsite -name "https://$($unmatchedWebsite.ITGObject.attributes.name)" `
                                            -notes $unmatchedWebsite.ITGObject.attributes.notes `
                                            -paused $DisableWebsiteMonitoring `
                                            -companyid $company.HuduCompanyObject.ID `
                                            -DisableDNS $DisableWebsiteMonitoring.ToString().ToLower() `
                                            -DisableSSL $DisableWebsiteMonitoring.ToString().ToLower() `
                                            -DisableWhois $DisableWebsiteMonitoring.ToString().ToLower()


                $unmatchedWebsite.matched = $true
                $unmatchedWebsite.HuduID = $HuduNewWebsite.id
                $unmatchedWebsite."HuduObject" = $HuduNewWebsite
                $unmatchedWebsite.Imported = "Created-By-Script"

                $ImportsMigrated = $ImportsMigrated + 1

                Write-host "$($unmatchedWebsite.Name) Has been created in Hudu"
            }
        }
    }
}


