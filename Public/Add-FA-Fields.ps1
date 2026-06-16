function Import-MigrationLog {
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    $path = Join-Path -Path $MigrationLogs -ChildPath $Name
    if (-not (Test-Path -LiteralPath $path)) {
        return $null
    }

    Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -Depth 100
}

function Test-IsNullOrEmptyCollection {
    param(
        [AllowNull()]
        [object]$Value
    )

    $null -eq $Value -or @($Value).Count -eq 0
}

function New-MatchIndex {
    param(
        [AllowNull()]
        [object[]]$Matches
    )

    $index = @{}
    foreach ($match in @($Matches)) {
        if ($null -eq $match -or [string]::IsNullOrWhiteSpace("$($match.ITGID)")) {
            continue
        }

        $index["$($match.ITGID)"] = $match
    }

    $index
}

function ConvertTo-HuduLinkedJson {
    param(
        [AllowNull()]
        [object[]]$ITGValues,

        [Parameter(Mandatory)]
        [hashtable]$MatchIndex
    )

    $linked = foreach ($itgValue in @($ITGValues)) {
        $match = $MatchIndex["$($itgValue.id)"]
        if ($match) {
            [PSCustomObject]@{
                id   = $match.HuduID
                name = $match.Name
            }
        }
    }

    $linked | ConvertTo-Json -Compress -AsArray
}

function Add-AssetField {
    param(
        [Parameter(Mandatory)]
        [hashtable]$AssetFields,

        [Parameter(Mandatory)]
        [object]$Field,

        [AllowNull()]
        [object]$Value
    )

    $label = "$($Field.HuduParsedName)" -replace '_', ' '
    if ([string]::IsNullOrWhiteSpace($label)) {
        return
    }

    $AssetFields[$label] = $Value
}

function Convert-ITGTraitsToHuduFields {
    param(
        [Parameter(Mandatory)]
        [object]$UpdateAsset,

        [Parameter(Mandatory)]
        [hashtable]$FieldIndex,

        [Parameter(Mandatory)]
        [hashtable]$ContactIndex,

        [Parameter(Mandatory)]
        [hashtable]$ConfigurationIndex,

        [Parameter(Mandatory)]
        [hashtable]$LocationIndex,

        [Parameter(Mandatory)]
        [hashtable]$AssetIndex
    )

    $assetFields = @{
        'Imported From ITGlue' = Get-Date -Format 'o'
        'ITGlue URL'           = $UpdateAsset.ITGObject.attributes.'resource-url'
        'ITGlue ID'            = $UpdateAsset.ITGID
    }

    if ($UpdateAsset.ITGObject.attributes.'created-at') {
        $assetFields['ITG Date Created'] = Get-CoercedDate $UpdateAsset.ITGObject.attributes.'created-at'
    }

    if ($UpdateAsset.ITGObject.attributes.'updated-at') {
        $assetFields['ITG Date Last Updated'] = Get-CoercedDate $UpdateAsset.ITGObject.attributes.'updated-at'
    }

    $traits = $UpdateAsset.ITGObject.attributes.traits
    if ($null -eq $traits) {
        return $assetFields
    }

    $layoutId = "$($UpdateAsset.ITGObject.attributes.'flexible-asset-type-id')"
    foreach ($trait in $traits.PSObject.Properties) {
        $itgParsed = $trait.Name
        $itgValues = $trait.Value
        $field = $FieldIndex["$layoutId|$itgParsed"]

        if (-not $field) {
            Write-Host "Warning: $itgParsed on $($UpdateAsset.Name) could not be mapped to a Hudu field" -ForegroundColor Yellow
            continue
        }

        switch ($field.FieldType) {
            'Date' {
                $raw = ($itgValues.values ?? $itgValues) -as [string]
                $returnData = Get-CoercedDate -InputDate $raw -Cutoff '1000-01-01' -OutputFormat 'MM/DD/YYYY'
                if (-not $returnData) {
                    if ($field.HuduLayoutField.required) {
                        $returnData = (Get-Date).ToString('MM/dd/yyyy', [System.Globalization.CultureInfo]::InvariantCulture)
                    } else {
                        continue
                    }
                }

                Add-AssetField -AssetFields $assetFields -Field $field -Value "$returnData"
            }
            'Tag' {
                switch ($field.FieldSubType) {
                    'Contacts' {
                        Add-AssetField -AssetFields $assetFields -Field $field -Value (ConvertTo-HuduLinkedJson -ITGValues $itgValues.values -MatchIndex $ContactIndex)
                    }
                    'Configurations' {
                        Add-AssetField -AssetFields $assetFields -Field $field -Value (ConvertTo-HuduLinkedJson -ITGValues $itgValues.values -MatchIndex $ConfigurationIndex)
                    }
                    'Locations' {
                        Add-AssetField -AssetFields $assetFields -Field $field -Value (ConvertTo-HuduLinkedJson -ITGValues $itgValues.values -MatchIndex $LocationIndex)
                    }
                    'FlexibleAssetType' {
                        Add-AssetField -AssetFields $assetFields -Field $field -Value (ConvertTo-HuduLinkedJson -ITGValues $itgValues.values -MatchIndex $AssetIndex)
                    }
                    default {
                        Write-Host "Skipping relation-only or unsupported tag field $($field.FieldName) on $($UpdateAsset.Name)" -ForegroundColor DarkYellow
                    }
                }
            }
            'Password' {
                Write-Host "Skipping password field $($field.FieldName) on $($UpdateAsset.Name); reapply does not re-fetch ITGlue secrets" -ForegroundColor DarkYellow
            }
            'Number' {
                $coerced = Get-CastIfNumeric ($trait.Value -replace '[^\x09\x0A\x0D\x20-\x7E]', '')
                Add-AssetField -AssetFields $assetFields -Field $field -Value "$coerced"
            }
            'Upload' {
                Write-Host "Skipping upload field $($field.FieldName) on $($UpdateAsset.Name); uploads are handled separately" -ForegroundColor DarkYellow
            }
            default {
                Add-AssetField -AssetFields $assetFields -Field $field -Value "$($trait.Value)"
            }
        }
    }

    $assetFields
}

if ([string]::IsNullOrWhiteSpace($MigrationLogs)) {
    throw '$MigrationLogs must be set before running this script.'
}

if (Test-IsNullOrEmptyCollection $MatchedAssets) { $MatchedAssets = Import-MigrationLog -Name 'Assets.json' }
if (Test-IsNullOrEmptyCollection $MatchedContacts) { $MatchedContacts = Import-MigrationLog -Name 'Contacts.json' }
if (Test-IsNullOrEmptyCollection $matchedConfigurations) { $matchedConfigurations = Import-MigrationLog -Name 'Configurations.json' }
if (Test-IsNullOrEmptyCollection $MatchedLocations) { $MatchedLocations = Import-MigrationLog -Name 'Locations.json' }

if (Test-IsNullOrEmptyCollection $AllFields) {
    if (Test-IsNullOrEmptyCollection $MatchedAssetLayoutFields) {
        $MatchedAssetLayoutFields = Import-MigrationLog -Name 'AssetLayoutsFields.json'
    }

    $AllFields = $MatchedAssetLayoutFields
}

if (Test-IsNullOrEmptyCollection $MatchedAssets) {
    throw "Could not load matched assets from $MigrationLogs\Assets.json."
}

if (Test-IsNullOrEmptyCollection $AllFields) {
    throw "Could not load asset field mappings. Set `$AllFields or provide $MigrationLogs\AssetLayoutsFields.json."
}

$fieldIndex = @{}
foreach ($field in @($AllFields)) {
    if ([string]::IsNullOrWhiteSpace("$($field.IGLayoutID)") -or [string]::IsNullOrWhiteSpace("$($field.ITGParsedName)")) {
        continue
    }
    $fieldIndex["$($field.IGLayoutID)|$($field.ITGParsedName)"] = $field
}

$contactIndex = New-MatchIndex -Matches $MatchedContacts
$configurationIndex = New-MatchIndex -Matches $matchedConfigurations
$locationIndex = New-MatchIndex -Matches $MatchedLocations
$assetIndex = New-MatchIndex -Matches $MatchedAssets

$updatedCount = 0
$skippedCount = 0

foreach ($updateAsset in @($MatchedAssets)) {
    if ($updateAsset.HuduObject.archived -eq $true) {
        Write-Host "Skipping archived asset $($updateAsset.Name)"
        $skippedCount++
        continue
    }

    if (-not $updateAsset.HuduID -or -not $updateAsset.ITGObject) {
        Write-Host "Skipping $($updateAsset.Name): missing HuduID or ITG object" -ForegroundColor Yellow
        $skippedCount++
        continue
    }

    Write-Host "Reapplying ITGlue field values for $($updateAsset.Name)"
    $assetFields = Convert-ITGTraitsToHuduFields `
        -UpdateAsset $updateAsset `
        -FieldIndex $fieldIndex `
        -ContactIndex $contactIndex `
        -ConfigurationIndex $configurationIndex `
        -LocationIndex $locationIndex `
        -AssetIndex $assetIndex

    if ($assetFields.Count -eq 0) {
        Write-Host "Skipping $($updateAsset.Name): no fields to apply" -ForegroundColor Yellow
        $skippedCount++
        continue
    }


    if ($WhatIf) {
        Write-Host "WhatIf: would update asset $($updateAsset.HuduID) with fields: $($assetFields.Keys -join ', ')" -ForegroundColor Cyan
        continue
    }

    try {
    $updatedHuduAsset = (Set-HuduAsset `
        -asset_id $updateAsset.HuduID `
        -name $updateAsset.Name `
        -company_id $updateAsset.HuduObject.company_id `
        -asset_layout_id $updateAsset.HuduObject.asset_layout_id `
        -fields $assetFields).asset
    } catch {
        Write-Host "Error updating asset $($updateAsset.Name): $_" -ForegroundColor Red
        continue
    }


    $updateAsset.HuduObject = $updatedHuduAsset
    $updateAsset.Imported = 'Created-By-Script'
    $updatedCount++
}
