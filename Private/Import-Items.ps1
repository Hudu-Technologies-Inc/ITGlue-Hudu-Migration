function Import-Items {
    Param(
        $AssetFieldsMap,
        $AssetLayoutFields,
        $ImportIcon,
        $ImportEnabled,
        $HuduItemFilter,
        $ImportAssetLayoutName,
        $ItemSelect,
        $MigrationName,
        $ITGImports
    )


    $ImportsMigrated = 0

    $ImportLayout = $null





    Write-Host "Processing $ImportAssetLayoutName"

    # Lets try to match Asset Layouts
    $ImportLayout = Get-HuduAssetLayouts -name $ImportAssetLayoutName
	
    if ($ImportLayout) {
		
        $HuduImports = Get-HuduAssets -assetlayoutid $ImportLayout.id
        Write-Host "$MigrationName layout found attempting to match existing entries"
        $MatchedImports = foreach ($itgimport in $ITGImports ) {

            $HuduImport = $HuduImports | where-object -filter $HuduItemFilter
			
	
            if ($HuduImport) {
                [PSCustomObject]@{
                    "Name"        = $itgimport.attributes.name
                    "CompanyName" = $itgimport.attributes."organization-name"
                    "ITGID"       = $itgimport.id
                    "HuduID"      = $HuduImport.id
                    "Matched"     = $true
                    "HuduObject"  = $HuduImport
                    "ITGObject"   = $itgimport
                    "Imported"    = "Pre-Existing"
					
                }
            } else {
                [PSCustomObject]@{
                    "Name"        = $itgimport.attributes.name
                    "CompanyName" = $itgimport.attributes."organization-name"
                    "ITGID"       = $itgimport.id
                    "HuduID"      = ""
                    "Matched"     = $false
                    "HuduObject"  = ""
                    "ITGObject"   = $itgimport
                    "Imported"    = ""
                }
            }
        }
    } else {
        $MatchedImports = foreach ($itgimport in $ITGImports ) {
            [PSCustomObject]@{
                "Name"        = $itgimport.attributes.name
                "CompanyName" = $itgimport.attributes."organization-name"
                "ITGID"       = $itgimport.id
                "HuduID"      = ""
                "Matched"     = $false
                "HuduObject"  = ""
                "ITGObject"   = $itgimport
                "Imported"    = ""
            }
		
        }

    }
    $MatchedImportsByOrgId = @{}
    foreach ($import in $MatchedImports) {
        $orgId = $import.ITGObject.attributes.'organization-id'
        if (-not $MatchedImportsByOrgId.ContainsKey($orgId)) {
            $MatchedImportsByOrgId[$orgId] = @()
        }
        $MatchedImportsByOrgId[$orgId] += $import
    }
    Write-Host "Matched $MigrationName (Already exist so will not be migrated)"
    Write-Host $($MatchedImports | Sort-Object CompanyName | Where-Object { $_.Matched -eq $true } | Select-Object CompanyName, Name | Format-Table | Out-String)
	
    Write-Host "Unmatched $MigrationName"
    Write-Host $($MatchedImports | Sort-Object CompanyName | Where-Object { $_.Matched -eq $false } | Select-Object CompanyName, Name | Format-Table | Out-String)
	
    # Import Items
    $UnmappedImportCount = ($MatchedImports | Where-Object { $_.Matched -eq $false } | measure-object).count
    if ($ImportEnabled -eq $true -and $UnmappedImportCount -gt 0) {
		
        if (!$ImportLayout) { 
            Write-Host "Creating New Asset Layout $ImportAssetLayoutName"
            $Null = New-HuduAssetLayout -name $ImportAssetLayoutName -icon $ImportIcon -color "#6e00d5" -icon_color "#ffffff" -include_passwords $true -include_photos $true -include_comments $true -include_files $true -fields $AssetLayoutFields
            $ImportLayout = Get-HuduAssetLayouts -name $ImportAssetLayoutName
	    # Activate Asset Layouts once Created
	    $Null = Set-HuduAssetLayout -id $ImportLayout.id -Active $true
		
        }
	
        $ImportOption = Get-ImportMode -ImportName $MigrationName
	
        if (($importOption -eq "A") -or ($importOption -eq "S") ) {		
	
            foreach ($company in $CompaniesToMigrate) {
                Write-Host "Migrating $($company.CompanyName) $MigrationName"

                $orgId = $company.ITGCompanyObject.id
                if (-not $MatchedImportsByOrgId.ContainsKey($orgId)) { continue }

                $orgImports = $MatchedImportsByOrgId[$orgId]

                foreach ($unmatchedImport in $orgImports) {
                    if ($unmatchedImport.Matched -eq $true) { continue }

                    $AssetFields = & $AssetFieldsMap

                    Confirm-Import -ImportObjectName "$($unmatchedImport.Name): $($AssetFields | Out-String)" -ImportObject $unmatchedImport -ImportSetting $ImportOption

                    Write-Host "Starting $($unmatchedImport.Name)"

                    $HuduAssetName = $unmatchedImport.Name
                    $HuduNewImport = (New-HuduAsset -name $HuduAssetName -company_id $company.HuduCompanyObject.ID -asset_layout_id $ImportLayout.id -fields $AssetFields).asset

                    if ($unmatchedImport.ITGObject.attributes.archived) {
                        Write-Host "WARNING: $($HuduAssetName) is archived in ITGlue and is being archived in Hudu" -ForegroundColor Magenta
                        $null = Set-HuduAssetArchive -Id $HuduNewImport.id -CompanyId $HuduNewImport.company_id -Archive $false
                    }

                    $unmatchedImport.Matched = $true
                    $unmatchedImport.HuduID = $HuduNewImport.id
                    $unmatchedImport.HuduObject = $HuduNewImport
                    $unmatchedImport.Imported = "Created-By-Script"

                    $ImportsMigrated++

                    Write-Host "$($unmatchedImport.Name) Has been created in Hudu"
                    Write-Host ""
                }
            }

        }
    } else {
        if ($UnmappedImportCount -eq 0) {
            Write-Host "All $MigrationName matched, no migration required" -foregroundcolor green
        } else {
            Write-Host "Warning Import $MigrationName is set to disabled so the above unmatched $MigrationName will not have data migrated" -foregroundcolor red
            Read-Host -Prompt "Press any key to continue or CTRL+C to quit" 
        }
    }
	
    Return $MatchedImports

}
