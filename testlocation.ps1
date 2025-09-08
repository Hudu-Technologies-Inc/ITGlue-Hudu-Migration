. .\public\CustomMapping.ps1
if ($true -eq $customMapLocations) {
        $imports = Convert-ITGImportsToHuduPreview `
            -ITGImports $ITGLocations `
            -CompaniesToMigrate $CompaniesToMigrate `
            -ImportAssetLayoutName $LocImportAssetLayoutName `
            -AssetLayoutFields $LocAssetLayoutFields `
            -AssetFieldsMap $LocAssetFieldsMap `
            -Verbose
        $mockLayout =[pscustomobject]@{Id = -6; name="ephemeral-$LocMigrationName"; fields=$LocAssetLayoutFields}
        $imports | ConvertTo-Json -Depth 95 | Set-Content -Path "$LocMigrationName.json"
        $LocationsResult = Set-ITGAssetsToExistingLayout `
                            -desiredMapFileName "$LocMigrationName.ps1" `
                            -sourceAssets $imports `
                            -sourceAssetLayout  $mockLayout `
                            -allrelations @() `
                            -stagedMode $false -justMap $false -userMapping $null
        $MatchedLocations = $LocationsResult.createdAssets | Where-Object {$_.ITGId -and $null -ne $_.ITGId}
        $LocationLayout   =   $LocationsResult.destlayout
        $LocImportAssetLayoutName = $LocationLayout.name
        Write-Host "Added $($LocationsResult.counts.assetsmoved ?? 0) of $($MatchedLocations.count ?? 0) from mock ITG to $LocImportAssetLayoutName"
    } else {
        $MatchedLocations = Import-Items @LocImportSplat
    }
