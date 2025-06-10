Write-Host "The script will now migrate IT Glue Flexible Asset Layouts to Hudu"
Write-Host "Please select the option you would like"
Write-Host "1) Move all Flexible Asset Layouts to Hudu"
Write-Host "2) Determine on a layout by layout basis if you want to migrate"
$ImportOption = Get-FlexLayoutImportMode
$ConfigImportAssetLayoutName = ($MatchedConfigurations.HuduObject | Select-Object name, asset_type | group-object -property asset_type | sort-object count -descending | Select-Object -first 1).name

# Match to existing layouts
$MatchedLayouts = foreach ($ITGLayout in $FlexLayouts) {
    $HuduLayout = $HuduLayouts | where-object -filter { $_.name -eq "$($FlexibleLayoutPrefix)$($ITGLayout.attributes.name)" }
    
    if ($HuduLayout) {
        [PSCustomObject]@{
            "Name"       = $ITGLayout.attributes.name
            "ITGID"      = $ITGLayout.id
            "HuduID"     = $HuduLayout.id
            "Matched"    = $true
            "HuduObject" = $HuduLayout
            "ITGObject"  = $ITGLayout
            "ITGAssets"  = ""
            "Imported"   = "Pre-Existing"
        
        }
    } else {
        [PSCustomObject]@{
            "Name"       = $ITGLayout.attributes.name
            "ITGID"      = $ITGLayout.id
            "HuduID"     = ""
            "Matched"    = $false
            "HuduObject" = ""
            "ITGObject"  = $ITGLayout
            "ITGAssets"  = ""
            "Imported"   = ""
        }
    }
}


Write-Host "Matched Flexible Layouts (Already exist so will not be migrated)"
$MatchedLayouts | Sort-Object Name | Where-Object { $_.Matched -eq $true } | Select-Object Name | Format-Table

Write-Host "Unmatched Flexible Layouts"
$MatchedLayouts | Sort-Object Name | Where-Object { $_.Matched -eq $false } | Select-Object Name | Format-Table


if ($ImportFlexibleAssetLayouts -eq $true) {

    foreach ($UnmatchedLayout in $MatchedLayouts | Where-Object { $_.Matched -eq $false }) {
        if ($ImportOption -eq 2) {
            Confirm-Import -ImportObjectName "$($ITGLayout.attributes.name)" -ImportObject $null -ImportSetting $ImportOption
        }

        $TempLayoutFields = @(
            @{
                label        = 'Imported from ITGlue'
                field_type   = 'Date'
                show_in_list = 'false'
                position     = 500
            },
            @{
                label        = 'ITGlue URL'
                field_type   = 'Text'
                show_in_list = 'false'
                position     = 501
            },
            @{
                label        = 'ITGlue ID'
                field_type   = 'Text'
                show_in_list = 'false'
                position     = 502
            }

        )
        if ($null -eq $UnmatchedLayout.ITGObject.attributes.icon) {
            $NewIcon = 'circle'

        } elseif ($($FontAwesomeUpgrade."$($UnmatchedLayout.ITGObject.attributes.icon)")) {
            $NewIcon = $($FontAwesomeUpgrade."$($UnmatchedLayout.ITGObject.attributes.icon)")
        } else {
            $CurrentIcon = ($UnmatchedLayout.ITGObject.attributes.icon -replace "-o-", "-")
            $LastTwo = $CurrentIcon.Substring($CurrentIcon.get_Length() - 2)
            if ($LastTwo -eq "-o") {
                #strip last 2 digits
                $CurrentIcon = $CurrentIcon.Substring(0, $CurrentIcon.get_Length() - 2)
            }
            $NewIcon = $CurrentIcon
        }
    
    
        $NewLayout = New-HuduAssetLayout -name "$($FlexibleLayoutPrefix)$($UnmatchedLayout.ITGObject.attributes.name)" -icon "fas fa-$NewIcon" -color "00adef" -icon_color "#ffffff" -include_passwords $true -include_photos $true -include_comments $true -include_files $true -fields $TempLayoutFields 
        $MatchedNewLayout = Get-HuduAssetLayouts -layoutid $NewLayout.asset_layout.id

        $UnmatchedLayout.HuduObject = $MatchedNewLayout
        $UnmatchedLayout.HuduID = $NewLayout.asset_layout.id
        $UnmatchedLayout.Imported = "Created-By-Script"



    }


    foreach ($UpdateLayout in $MatchedLayouts) {
        Write-Host "Starting $($UpdateLayout.Name)" -ForegroundColor Green

        # Grab the fields for the layout
        Write-Host "Fetching Flexible Asset Fields from IT Glue"
        $FlexLayoutFieldsSelect = { (Get-ITGlueFlexibleAssetFields -page_size 1000 -page_number $i -flexible_asset_type_id $UpdateLayout.ITGID).data }
        $FlexLayoutFields = Import-ITGlueItems -ItemSelect $FlexLayoutFieldsSelect

            
        # Grab all the Assets for the layout
        Write-Host "Fetching Flexible Assets from IT Glue (This may take a while)"
        $FlexAssetsSelect = { (Get-ITGlueFlexibleAssets -page_size 1000 -page_number $i -filter_flexible_asset_type_id $UpdateLayout.ITGID -include related_items).data }
        $FlexAssets = Import-ITGlueItems -ItemSelect $FlexAssetsSelect
    
            
    
        $UpdateLayoutFields = foreach ($ITGField in $FlexLayoutFields) {
            $LayoutField = @{
                label        = $ITGField.Attributes.name
                show_in_list = $ITGField.Attributes."show-in-list"
                position     = $ITGField.Attributes.order
                required     = $ITGField.Attributes.required
                hint         = $ITGField.Attributes.hint
            }

            $supported = $true
    

            switch ($ITGField.Attributes.kind) {
                "Checkbox" {
                    $LayoutField.add("field_type", "CheckBox")
                }
                "Date" {
                    $LayoutField.add("field_type", "Date")
                    $LayoutField.add("expiration", $($ITGField.Attributes.expiration))
                }
                "Header" {
                    $LayoutField.add("field_type", "Heading")
                }
                "Number" {
                    $LayoutField.add("field_type", "Number")
                }
                "Select" {
                    $LayoutField.add("field_type", "Dropdown")
                    $LayoutField.add("options", $($ITGField.Attributes."default-value"))
                }
                "Text" {
                    $LayoutField.add("field_type", "Text")
                }
                "Textbox" {
                    $LayoutField.add("field_type", "RichText")
                }
                "Upload" {
                    Write-Host "Upload fields are not supported $($ITGField.Attributes.name) in $($UpdateLayout.name) this will be added when the Hudu API supports it, Sorry!"
                    $supported = $false
                }
                "Tag" {
                    switch (($ITGField.Attributes."tag-type").split(":")[0]) {
                        "AccountsUsers" { Write-Host "Tags to Account Users are not supported $($ITGField.Attributes.name) in $($UpdateLayout.name) will need to be manually migrated, Sorry!" ; $supported = $false }
                        "Checklists" { Write-Host "Tags to Checklists are not supported $($ITGField.Attributes.name) in $($UpdateLayout.name) will need to be manually migrated, Sorry!"; $supported = $false }
                        "ChecklistTemplates" { Write-Host "Tags to Checklists Templates are not supported $($ITGField.Attributes.name) in $($UpdateLayout.name) will need to be manually migrated, Sorry!"; $supported = $false }
                        "Contacts" {
                            $ContactLayout = Get-HuduAssetLayouts -name $ConImportAssetLayoutName
                            $LayoutField.add("field_type", "AssetTag")
                            $LayoutField.add("linkable_id", $ContactLayout.ID)
                        }
                        "Configurations" {
                            $ConfigLayout = Get-HuduAssetLayouts -name $ConfigImportAssetLayoutName
                            $LayoutField.add("field_type", "AssetTag")
                            $LayoutField.add("linkable_id", $ConfigLayout.ID)
                        }
                        "Documents" { Write-Host "Tags to Documents are not supported $($ITGField.Attributes.name) in $($UpdateLayout.name) will need to be manually migrated, Sorry!"; $supported = $false } 
                        "Domains" { Write-Host "Tags to Websites are not supported $($ITGField.Attributes.name) in $($UpdateLayout.name) will need to be manually migrated, Sorry!"; $supported = $false }
                        "Passwords" { Write-Host "Tags to Passwords are not supported $($ITGField.Attributes.name) in $($UpdateLayout.name) will need to be manually migrated, Sorry!"; $supported = $false }
                        "Locations" {
                            $LocationLayout = Get-HuduAssetLayouts -name $LocImportAssetLayoutName
                            $LayoutField.add("field_type", "AssetTag")
                            $LayoutField.add("linkable_id", $LocationLayout.ID)
                        }
                        "Organizations" { Write-Host "Tags to Companies are not supported $($ITGField.Attributes.name) in $($UpdateLayout.name) will need to be manually migrated, Sorry!"; $supported = $false }
                        "SslCertificates" { Write-Host "Tags to SSL Certificates are not supported $($ITGField.Attributes.name) in $($UpdateLayout.name) will need to be manually migrated, Sorry!"; $supported = $false }
                        "Tickets" { Write-Host "Tags to Tickets are not supported $($ITGField.Attributes.name) in $($UpdateLayout.name) will need to be manually migrated, Sorry!"; $supported = $false }
                        "FlexibleAssetType" {	
                            $MatchedLayoutID = ($MatchedLayouts | where-object -filter { $_.ITGID -eq ($ITGField.Attributes."tag-type").split(" ")[1] }).HuduID
                            $LayoutField.add("field_type", "AssetTag")
                            $LayoutField.add("linkable_id", $MatchedLayoutID)
                        }
                                

                    }
                }
                "Percent" {
                    $LayoutField.add("field_type", "Number")
                }
                "Password" {
                    $LayoutField.add("field_type", "Password")
                }
            }


            #Populate Global Field List
            if ($ITGField.Attributes.kind -eq "Tag") {
                $SubKind = ($ITGField.Attributes."tag-type").split(":")[0]
            } else {
                $SubKind = ""
            }

            $FieldDetails = [PSCustomObject]@{
                LayoutName      = $UpdateLayout.Name
                FieldName       = $ITGField.Attributes.name
                FieldType       = $ITGField.Attributes.kind
                FieldSubType    = $SubKind
                HuduLayoutID    = $UpdateLayout.HuduID
                IGLayoutID      = $UpdateLayout.ITGID
                ITGParsedName   = $ITGField.Attributes."name-key"
                HuduParsedName  = ($ITGField.Attributes.name -replace " ", "_").ToLower()
                Supported       = $supported
                HuduLayoutField = $LayoutField
            }
            $null = $AllFields.add($FieldDetails)


            if ($supported -eq $true) {
                $LayoutField
            }

        }

        $null = Set-HuduAssetLayout -id $UpdateLayout.HuduID  -name $UpdateLayout.HuduObject.Name -icon $UpdateLayout.HuduObject.icon -color $UpdateLayout.HuduObject.color -icon_color $UpdateLayout.HuduObject.icon_color -include_passwords $true -include_photos $true -include_comments $true -include_files $true -fields @($UpdateLayoutFields)
        $UpdatedLayout = Get-HuduAssetLayouts -layoutid $UpdateLayout.HuduID
        Write-Host "Finished $($UpdateLayout.HuduObject.Name)"
        $UpdateLayout.HuduObject = $UpdatedLayout
        $UpdateLayout.ITGAssets = $FlexAssets
        $UpdateLayout.Matched = $true

    }

}