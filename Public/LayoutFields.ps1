# Build fresh field definitions at each migration phase, matching the original
# inline assignments. No request or previous run can mutate a later layout.
function New-MigrationLayoutFields {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Locations', 'Configurations', 'Contacts', 'FlexibleAssets')]
        [string]$LayoutType
    )

    switch ($LayoutType) {
        'Locations' {
            return @(
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
                },
                @{
                    label        = 'ITG Date Created'
                    field_type   = 'Date'
                    show_in_list = 'true'
                    position     = 10
                },
                @{
                    label        = 'ITG Date Last Updated'
                    field_type   = 'Date'
                    show_in_list = 'true'
                    position     = 11
                }
            )
        }
        'Configurations' {
            return @(
                @{
                    label        = 'Hostname'
                    field_type   = 'Text'
                    show_in_list = 'true'
                    position     = 1
                },
                @{
                    label        = 'Primary IP'
                    field_type   = 'Text'
                    show_in_list = 'false'
                    position     = 2
                },
                @{
                    label        = 'MAC Address'
                    field_type   = 'Text'
                    show_in_list = 'true'
                    position     = 3
                },
                @{
                    label        = 'Default Gateway'
                    field_type   = 'Text'
                    show_in_list = 'true'
                    position     = 4
                },
                @{
                    label        = 'Serial Number'
                    field_type   = 'Text'
                    show_in_list = 'false'
                    position     = 5
                },
                @{
                    label        = 'Asset Tag'
                    field_type   = 'Text'
                    show_in_list = 'false'
                    position     = 6
                },
                @{
                    label        = 'Position'
                    field_type   = 'Text'
                    show_in_list = 'false'
                    position     = 7
                },
                @{
                    label        = 'Installed By'
                    field_type   = 'Text'
                    show_in_list = 'false'
                    position     = 8
                },
                @{
                    label        = 'Purchased By'
                    field_type   = 'Text'
                    show_in_list = 'false'
                    position     = 9
                },
                @{
                    label        = 'Notes'
                    field_type   = 'RichText'
                    show_in_list = 'false'
                    position     = 10
                },
                @{
                    label        = 'Operating System Notes'
                    field_type   = 'RichText'
                    show_in_list = 'false'
                    position     = 11
                },
                @{
                    label        = 'Warranty Expires At'
                    field_type   = 'Date'
                    expiration   = 'true'
                    show_in_list = 'false'
                    position     = 12
                },
                @{
                    label        = 'Installed At'
                    field_type   = 'Date'
                    show_in_list = 'false'
                    position     = 13
                },
                @{
                    label        = 'Purchased At'
                    field_type   = 'Date'
                    show_in_list = 'false'
                    position     = 14
                },
                @{
                    label        = 'Configuration Type Name'
                    field_type   = 'Text'
                    show_in_list = 'false'
                    position     = 15
                },
                @{
                    label        = 'Configuration Type Kind'
                    field_type   = 'Text'
                    show_in_list = 'false'
                    position     = 16
                },
                # @{
                #     label        = 'Configuration Status Name'
                #     field_type   = 'Text'
                #     show_in_list = 'false'
                #     position     = 17
                # },
                @{
                    label        = 'Manufacturer Name'
                    field_type   = 'Text'
                    show_in_list = 'false'
                    position     = 18
                },
                @{
                    label        = 'Model ID'
                    field_type   = 'Text'
                    show_in_list = 'false'
                    position     = 19
                },
                @{
                    label        = 'Operating System Name'
                    field_type   = 'Text'
                    show_in_list = 'false'
                    position     = 20
                },
                @{
                    label        = 'Model Name'
                    field_type   = 'Text'
                    show_in_list = 'false'
                    position     = 22
                },
                @{
                    label        = 'Contact Name'
                    field_type   = 'Text'
                    show_in_list = 'false'
                    position     = 23
                },
                @{
                    label        = 'ITG Date Created'
                    field_type   = 'Date'
                    show_in_list = 'true'
                    position     = 24
                },
                @{
                    label        = 'ITG Date Last Updated'
                    field_type   = 'Date'
                    show_in_list = 'true'
                    position     = 25
                }
            )
        }
        'Contacts' {
            return @(
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
                # @{
                #     label        = 'Important'
                #     field_type   = 'Text'
                #     show_in_list = 'false'
                #     position     = 6
                # },
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
                },
                @{
                    label        = 'ITG Date Created'
                    field_type   = 'Date'
                    show_in_list = 'true'
                    position     = 10
                }
                @{
                    label        = 'ITG Date Last Updated'
                    field_type   = 'Date'
                    show_in_list = 'true'
                    position     = 11
                }
            )
        }
        'FlexibleAssets' {
            return @(
                @{
                    label        = 'ITG Date Created'
                    field_type   = 'Date'
                    show_in_list = 'true'
                    position     = 498
                },
                @{
                    label        = 'ITG Date Last Updated'
                    field_type   = 'Date'
                    show_in_list = 'true'
                    position     = 499
                },
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
        }
    }
}
