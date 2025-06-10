
$LocHuduItemFilter = { ($_.name -eq $itgimport.attributes.name -and $_.company_name -eq $itgimport.attributes."organization-name")`
        -or ($ITGPrimaryLocationNames -contains $itgimport.attributes.name -and $HuduPrimaryLocationNames -contains $_.name -and $_.company_name -eq $itgimport.attributes."organization-name")`
        -or ($itgimport.attributes.primary -eq $true -and $HuduPrimaryLocationNames -contains $_.name -and $_.company_name -eq $itgimport.attributes."organization-name") }

$LocImportEnabled = $ImportLocations

$LocMigrationName = "Locations"


$LocAssetLayoutFields = @(
    @{
        label        = 'Address 1'
        field_type   = 'Text'
        show_in_list = 'true'
        position     = 1
    },
    @{
        label        = 'Address 2'
        field_type   = 'Text'
        show_in_list = 'false'
        position     = 2
    },
    @{
        label        = 'City'
        field_type   = 'Text'
        show_in_list = 'true'
        position     = 3
    },
    @{
        label        = 'Postal Code'
        field_type   = 'Text'
        show_in_list = 'true'
        position     = 4
    },
    @{
        label        = 'Region'
        field_type   = 'Text'
        show_in_list = 'false'
        position     = 5
    },
    @{
        label        = 'Country'
        field_type   = 'Text'
        show_in_list = 'false'
        position     = 6
    },
    @{
        label        = 'Phone'
        field_type   = 'Text'
        show_in_list = 'false'
        position     = 7
    },
    @{
        label        = 'Fax'
        field_type   = 'Text'
        show_in_list = 'false'
        position     = 8
    },
    @{
        label        = 'Notes'
        field_type   = 'RichText'
        show_in_list = 'false'
        position     = 9
    }
)



$LocAssetFieldsMap = { @{ 
        'address_1'   = $unmatchedImport."ITGObject".attributes."address-1"
        'address_2'   = $unmatchedImport."ITGObject".attributes."address-2"
        'city'        = $unmatchedImport."ITGObject".attributes."city"
        'postal_code' = $unmatchedImport."ITGObject".attributes."postal-code"
        'region'      = $unmatchedImport."ITGObject".attributes."region-name"
        'country'     = $unmatchedImport."ITGObject".attributes."country-name"
        'phone'       = $unmatchedImport."ITGObject".attributes."phone"
        'fax'         = $unmatchedImport."ITGObject".attributes."fax"
        'notes'       = $unmatchedImport."ITGObject".attributes."notes"		
    } }


$LocImportSplat = @{
    AssetFieldsMap        = $LocAssetFieldsMap
    AssetLayoutFields     = $LocAssetLayoutFields
    ImportIcon            = $LocImportIcon
    ImportEnabled         = $LocImportEnabled
    HuduItemFilter        = $LocHuduItemFilter
    ImportAssetLayoutName = $LocImportAssetLayoutName
    ItemSelect            = $LocItemSelect
    MigrationName         = $LocMigrationName
    ITGImports            = $ITGLocations

}

#Import Locations
