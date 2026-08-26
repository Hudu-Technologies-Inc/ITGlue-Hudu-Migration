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
        $ITGImports,
        [int]$ThrottleLimit = ($MigrationParallelismLimit ?? 4),
        [bool]$UseFastAssetCommit = ($UseFastAssetCommit ?? $true),
        [bool]$UseFastArchiveCommit = ($UseFastArchiveCommit ?? $true),
        [hashtable]$CustomHeaders = ($HuduFastCommitHeaders ?? @{})
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
	
    Write-Host "Matched $MigrationName (Already exist so will not be migrated)"
    Write-Host $($MatchedImports | Sort-Object CompanyName | Where-Object { $_.Matched -eq $true } | Select-Object CompanyName, Name | Format-Table | Out-String)
	
    Write-Host "Unmatched $MigrationName"
    Write-Host $($MatchedImports | Sort-Object CompanyName | Where-Object { $_.Matched -eq $false } | Select-Object CompanyName, Name | Format-Table | Out-String)
	
    # Import Items
    $UnmappedImportCount = ($MatchedImports | Where-Object { $_.Matched -eq $false } | measure-object).count
    if ($ImportEnabled -eq $true -and $UnmappedImportCount -gt 0) {
		
        if (!$ImportLayout) { 
            Write-Host "Creating New Asset Layout $ImportAssetLayoutName"
            $Null = New-HuduAssetLayout -name $ImportAssetLayoutName -icon $ImportIcon -color "$($LayoutIconBackGroundColor)" -icon_color "$($LayoutIconForegroundColor)" -include_passwords $true -include_photos $true -include_comments $true -include_files $true -fields $AssetLayoutFields
            $ImportLayout = Get-HuduAssetLayouts -name $ImportAssetLayoutName
	    # Activate Asset Layouts once Created
	    $Null = Set-HuduAssetLayout -id $ImportLayout.id -Active $true
		
        }
	
        $ImportOption = Get-ImportMode -ImportName $MigrationName
	
        if (($importOption -eq "A") -or ($importOption -eq "S") ) {
            if ($UseFastAssetCommit -and -not (Get-Command -Name Invoke-FastHuduAssetCommit -ErrorAction SilentlyContinue)) {
                $UseFastAssetCommit = $false
            }

            if ($UseFastArchiveCommit -and -not (Get-Command -Name Invoke-FastHuduArchiveCommit -ErrorAction SilentlyContinue)) {
                $UseFastArchiveCommit = $false
            }

            $AssetCreateRequests = [System.Collections.ArrayList]@()
            $requestIndex = 0

            foreach ($company in $CompaniesToMigrate) {
                # if ($true -eq $itgimport.attributes.archived){
                #     write-host "SKIPPING ARCHIVED IMPORT: $($itgimport.attributes.name) is archived in ITGlue and is being skipped for migration" -ForegroundColor Yellow
                #     continue
                # }

                Write-Host "Migrating $($company.CompanyName) $MigrationName"
	
                foreach ($unmatchedImport in ($MatchedImports | Where-Object { $_.Matched -eq $false -and $company.ITGCompanyObject.id -eq $_."ITGObject".attributes."organization-id" })) {
	
                    $AssetFields = & $AssetFieldsMap

					$AssetFields.'ITG Date Created' = $(Get-CoercedDate $unmatchedImport."ITGObject".attributes.'created-at')
					$AssetFields.'ITG Date Last Updated' = $(Get-CoercedDate $unmatchedImport."ITGObject".attributes.'updated-at')

                    Confirm-Import -ImportObjectName "$($unmatchedImport.Name): $($AssetFields | Out-String)" -ImportObject $unmatchedImport -ImportSetting $ImportOption
                    	
                    Write-Host "Starting $($unmatchedImport.Name)"
	
                    $HuduAssetName = $($unmatchedImport.Name)

                    $null = $AssetCreateRequests.Add([pscustomobject]@{
                        Index              = $requestIndex
                        Name               = $HuduAssetName
                        CompanyId          = [int]$company.HuduCompanyObject.ID
                        AssetLayoutId      = [int]$ImportLayout.id
                        Fields             = @($AssetFields)
                        SourceImport       = $unmatchedImport
                        ArchiveAfterCreate = ($true -eq $unmatchedImport.ITGObject.attributes.archived)
                    })
                    $requestIndex++
                }
            }

            $AssetCreateResults = if ($AssetCreateRequests.Count -gt 0 -and $UseFastAssetCommit) {
                $fastAssetCommitParams = @{
                    AssetRequests = @($AssetCreateRequests)
                    Operation     = 'Create'
                    ThrottleLimit = $ThrottleLimit
                }
                if ($CustomHeaders -and $CustomHeaders.Count -gt 0) {
                    $fastAssetCommitParams.CustomHeaders = $CustomHeaders
                }
                Invoke-FastHuduAssetCommit @fastAssetCommitParams
            } else {
                foreach ($assetCreateRequest in @($AssetCreateRequests)) {
                    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
                    try {
                        $HuduNewImport = (New-HuduAsset -name $assetCreateRequest.Name -company_id $assetCreateRequest.CompanyId -asset_layout_id $assetCreateRequest.AssetLayoutId -fields $assetCreateRequest.Fields).asset
                        $stopwatch.Stop()
                        [pscustomobject]@{
                            Status         = if ($HuduNewImport) { 'created' } else { 'failed' }
                            Operation      = 'Create'
                            Index          = $assetCreateRequest.Index
                            AssetId        = $HuduNewImport.id
                            AssetName      = $assetCreateRequest.Name
                            CompanyId      = $assetCreateRequest.CompanyId
                            Asset          = $HuduNewImport
                            SourceRequest  = $assetCreateRequest
                            Attempts       = 1
                            SleptSeconds   = 0
                            ElapsedSeconds = [math]::Round($stopwatch.Elapsed.TotalSeconds, 3)
                            StatusCode     = $null
                            Error          = $null
                        }
                    } catch {
                        $stopwatch.Stop()
                        [pscustomobject]@{
                            Status         = 'failed'
                            Operation      = 'Create'
                            Index          = $assetCreateRequest.Index
                            AssetId        = $null
                            AssetName      = $assetCreateRequest.Name
                            CompanyId      = $assetCreateRequest.CompanyId
                            Asset          = $null
                            SourceRequest  = $assetCreateRequest
                            Attempts       = 1
                            SleptSeconds   = 0
                            ElapsedSeconds = [math]::Round($stopwatch.Elapsed.TotalSeconds, 3)
                            StatusCode     = $null
                            Error          = $_.Exception.Message
                        }
                    }
                }
            }

            $AssetCreateRequestsByIndex = @{}
            foreach ($assetCreateRequest in @($AssetCreateRequests)) {
                $AssetCreateRequestsByIndex[[int]$assetCreateRequest.Index] = $assetCreateRequest
            }

            $ArchiveRequests = [System.Collections.ArrayList]@()
            foreach ($assetCreateResult in @($AssetCreateResults | Sort-Object Index)) {
                $assetCreateRequest = $AssetCreateRequestsByIndex[[int]$assetCreateResult.Index]
                $unmatchedImport = $assetCreateRequest.SourceImport
                if ($assetCreateResult.Status -eq 'created' -and $assetCreateResult.Asset) {
                    $HuduNewImport = $assetCreateResult.Asset
                    if ($assetCreateRequest.ArchiveAfterCreate) {
                        Write-Host "WARNING: $($assetCreateResult.AssetName) is archived in ITGlue and is being archived in Hudu" -ForegroundColor Magenta
                        $null = $ArchiveRequests.Add([pscustomobject]@{
                            Group     = $MigrationName
                            Type      = 'Asset'
                            Id        = [int]$HuduNewImport.id
                            CompanyId = [int]$HuduNewImport.company_id
                            Source    = $unmatchedImport
                        })
                    }

                    $unmatchedImport.matched = $true
                    $unmatchedImport.HuduID = $HuduNewImport.id
                    $unmatchedImport."HuduObject" = $HuduNewImport
                    $unmatchedImport.Imported = "Created-By-Script"

                    $ImportsMigrated = $ImportsMigrated + 1

                    Write-host "$($unmatchedImport.Name) Has been created in Hudu"
                    Write-Host ""
                } else {
                    $unmatchedImport.Imported = "Create-Failed"
                    Write-Host "Failed to create $($unmatchedImport.Name) in Hudu: $($assetCreateResult.Error)" -ForegroundColor Red
                }
            }

            $createdCount = @($AssetCreateResults | Where-Object { $_.Status -eq 'created' -and $_.Asset }).Count
            $failedCount = @($AssetCreateResults | Where-Object { $_.Status -ne 'created' -or -not $_.Asset }).Count
            Write-Host "$MigrationName asset create commits complete: $createdCount/$($AssetCreateRequests.Count) created, $failedCount failed." -ForegroundColor Cyan
            if ($failedCount -gt 0) {
                Write-Host "$MigrationName had $failedCount failed asset create commit(s). Review the errors above before trusting this section as complete." -ForegroundColor Red
            }

            if (-not [string]::IsNullOrWhiteSpace([string]$MigrationLogs)) {
                $safeMigrationName = ([string]$MigrationName -replace '[^\w.-]+', '-').Trim('-')
                if ([string]::IsNullOrWhiteSpace($safeMigrationName)) {
                    $safeMigrationName = 'ImportItems'
                }
                $AssetCreateResults | ConvertTo-Json -depth 75 | Out-File "$MigrationLogs\$safeMigrationName-AssetCreateCommitResults.json"
            }

            if ($ArchiveRequests.Count -gt 0) {
                if ($UseFastArchiveCommit) {
                    $fastArchiveCommitParams = @{
                        ArchiveRequests = @($ArchiveRequests)
                        ThrottleLimit   = $ThrottleLimit
                    }
                    if ($CustomHeaders -and $CustomHeaders.Count -gt 0) {
                        $fastArchiveCommitParams.CustomHeaders = $CustomHeaders
                    }
                    $null = Invoke-FastHuduArchiveCommit @fastArchiveCommitParams
                } else {
                    foreach ($archiveRequest in @($ArchiveRequests)) {
                        $null = Set-HuduAssetArchive -Id $archiveRequest.Id -CompanyId $archiveRequest.CompanyId -Archive $true
                    }
                }
            }
        }
			
	
    } else {
        if ($UnmappedImportCount -eq 0) {
            Write-Host "All $MigrationName matched, no migration required" -foregroundcolor green
        } else {
            Write-Host "Warning Import $MigrationName is set to disabled so the above unmatched $MigrationName will not have data migrated" -foregroundcolor red
            if ($true -eq $NonInteractive) {Write-Host "Non-interactive mode enabled, skipping user prompt"} else {Read-Host -Prompt "Press any key to continue or CTRL+C to quit"}
        }
    }
	
    Return $MatchedImports

}
function Add-HuduAssetTagLayoutField {
    param(
        [Parameter(Mandatory)]
        [hashtable]$LayoutField,

        [AllowNull()]
        $LinkableLayout,

        [Parameter(Mandatory)]
        [string]$FieldName,

        [Parameter(Mandatory)]
        [string]$LayoutName
    )

    if ($null -eq $LinkableLayout -or [string]::IsNullOrWhiteSpace([string]$LinkableLayout.ID)) {
        Write-Host "Skipping AssetTag field '$FieldName' in '$LayoutName' because no linkable Hudu layout was found." -ForegroundColor Yellow
        return $false
    }

    $LayoutField.add("field_type", "AssetTag")
    $LayoutField.add("linkable_id", $LinkableLayout.ID)
    return $true
}

function Add-HuduAssetTagFieldValue {
    param(
        [Parameter(Mandatory)]
        [hashtable]$AssetFields,

        [Parameter(Mandatory)]
        $Field,

        [AllowNull()]
        $LinkedItems,

        [Parameter(Mandatory)]
        [string]$AssetName
    )

    $validLinks = @($LinkedItems | ForEach-Object {
        $id = $_.HuduID ?? $_.id
        $name = $_.Name ?? $_.name

        if (-not [string]::IsNullOrWhiteSpace([string]$id)) {
            [pscustomobject]@{
                id   = $id
                name = $name
            }
        }
    })

    if ($validLinks.Count -eq 0) {
        Write-Host "Skipping AssetTag value '$($Field.FieldName)' in '$AssetName' because none of the tagged IT Glue items are within the import scope." -ForegroundColor Yellow
        return $false
    }

    $AssetFields["$($Field.HuduParsedName)"] = "$($validLinks | ConvertTo-Json -Compress -AsArray | Out-String)"
    return $true
}
