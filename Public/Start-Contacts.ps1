

Write-Host "Fetching Contacts from IT Glue" -ForegroundColor Green
$ContactsSelect = { (Get-ITGlueContacts -page_size 1000 -page_number $i -include related_items).data }
$ITGContacts = Import-ITGlueItems -ItemSelect $ContactsSelect

#($ITGContacts.attributes | sort-object -property name, "organization-name" -Unique)

$ConHuduItemFilter = { ($_.name -eq $itgimport.attributes.name -and $_.company_name -eq $itgimport.attributes."organization-name") }

$ConImportEnabled = $ImportContacts

$ConMigrationName = "Contacts"

$LocationLayout = Get-HuduAssetLayouts -name $LocImportAssetLayoutName

$ConAssetLayoutFields = @(
    @{
        label        = 'First Name'
        field_type   = 'Text'
        show_in_list = 'true'
        position     = 1
    },
    @{
        label        = 'Last Name'
        field_type   = 'Text'
        show_in_list = 'false'
        position     = 2
    },
    @{
        label        = 'Title'
        field_type   = 'Text'
        show_in_list = 'true'
        position     = 3
    },
    @{
        label        = 'Contact Type'
        field_type   = 'Text'
        show_in_list = 'true'
        position     = 4
    },
    @{
        label        = 'Location'
        field_type   = 'AssetTag'
        show_in_list = 'false'
        linkable_id  = $LocationLayout.ID
        position     = 5
    },
    @{
        label        = 'Important'
        field_type   = 'Text'
        show_in_list = 'false'
        position     = 6
    },
    @{
        label        = 'Notes'
        field_type   = 'RichText'
        show_in_list = 'false'
        position     = 7
    },
    @{
        label        = 'Emails'
        field_type   = 'RichText'
        show_in_list = 'false'
        position     = 8
    },
    @{
        label        = 'Phones'
        field_type   = 'RichText'
        show_in_list = 'false'
        position     = 9
    }
)



$ConAssetFieldsMap = { @{ 
        'first_name'   = $unmatchedImport."ITGObject".attributes."first-name"
        'last_name'    = $unmatchedImport."ITGObject".attributes."last-name"
        'title'        = $unmatchedImport."ITGObject".attributes."title"
        'contact_type' = $unmatchedImport."ITGObject".attributes."contact-type-name"
        'location'     = "[$($MatchedLocations | where-object -filter {$_.ITGID -eq $unmatchedImport."ITGObject".attributes."location-id"} | Select-Object @{N='id';E={$_.HuduID}}, @{N='name';E={$_.Name}} | convertto-json -compress | out-string)]" -replace "`r`n", ""
        'important'    = $unmatchedImport."ITGObject".attributes."important"
        'notes'        = $unmatchedImport."ITGObject".attributes."notes"
        'emails'       = $unmatchedImport."ITGObject".attributes."contact-emails" | convertto-html -fragment | out-string
        'phones'       = $unmatchedImport."ITGObject".attributes."contact-phones"	| convertto-html -fragment | out-string
    } }


$ConImportSplat = @{
    AssetFieldsMap        = $ConAssetFieldsMap
    AssetLayoutFields     = $ConAssetLayoutFields
    ImportIcon            = $ConImportIcon
    ImportEnabled         = $ConImportEnabled
    HuduItemFilter        = $ConHuduItemFilter
    ImportAssetLayoutName = $ConImportAssetLayoutName
    ItemSelect            = $ConItemSelect
    MigrationName         = $ConMigrationName
    ITGImports            = $ITGContacts

}

#Import Locations
$MatchedContacts = Import-Items @ConImportSplat

Write-Host "Contacts Complete" 