
if ($true -eq $ImportFlexibleAssetLayouts -and -not ($ResumeFound -eq $true -and (Test-Path "$MigrationLogs\AssetLayouts.json"))) {
    Write-Host "Pre-flight: checking IT Glue flexible asset layout names against existing Hudu asset layouts." -ForegroundColor Green
    $previousMigrationName = $MigrationName
    $MigrationName = "Flexible Asset Layouts"
    try {
        $PreflightFlexLayoutSelect = { (Get-ITGlueFlexibleAssetTypes -page_size 1000 -page_number $i -include related_items).data }
        $PreflightFlexLayouts = Import-ITGlueItems -ItemSelect $PreflightFlexLayoutSelect
    } finally {
        $MigrationName = $previousMigrationName
    }

    $PreflightFlexibleTargetLayouts = foreach ($ITGLayout in @($PreflightFlexLayouts | Where-Object { $_ })) {
        if ([string]::IsNullOrWhiteSpace($ITGLayout.attributes.name)) { continue }
        [pscustomobject]@{
            SourceType = "Flexible Asset Layout"
            SourceName = $ITGLayout.attributes.name
            TargetName = "$($FlexibleLayoutPrefix)$($ITGLayout.attributes.name)"
            SourceId   = $ITGLayout.id
        }
    }

    $PreflightHuduLayouts = Get-HuduAssetLayouts
    $layoutCollisionCheck = Test-HuduFlexibleAssetLayoutNameCollision `
        -ITGlueFlexibleAssetLayouts $PreflightFlexLayouts `
        -HuduAssetLayouts $PreflightHuduLayouts `
        -FlexibleLayoutPrefix $FlexibleLayoutPrefix `
        -HuduBaseUrl $HuduBaseDomain `
        -Detailed

    if (-not $layoutCollisionCheck.Success) {
        $PreflightCollisionFound = $true
        Write-Host "The following IT Glue flexible asset layout target names already exist in Hudu:" -ForegroundColor Red
        Write-Host ($layoutCollisionCheck.Collisions |
            Sort-Object TargetName |
            Select-Object SourceName, TargetName, SourceId, HuduLayoutId, HuduManagementUrl |
            Format-Table -AutoSize -Wrap |
            Out-String -Width 4096)
        Write-Host "Resolve these by renaming the existing Hudu asset layout(s), changing the FA prefix, or disabling flexible asset layout import before retrying." -ForegroundColor Red
    } else {
        Write-Host "Pre-flight layout collision check passed." -ForegroundColor Green
    }
}

if ($true -eq $ImportConfigurations -and -not ($ResumeFound -eq $true -and (Test-Path "$MigrationLogs\Configurations.json"))) {
    Write-Host "Pre-flight: checking configuration asset layout names against existing Hudu asset layouts." -ForegroundColor Green

    $ConfigurationPrefix = $settings.ConPromptPrefix ?? $ConfigurationPrefix ?? ""
    $ConfigurationSplitMode = Get-ConfigurationSplitMode -Settings $settings -EnvironmentSettings $environmentSettings
    $SmartConfigurationMaxCategories = Get-SmartConfigurationCategoryMax -Settings $settings -EnvironmentSettings $environmentSettings

    $previousMigrationName = $MigrationName
    $MigrationName = "Configurations"
    try {
        $PreflightConfigurationsSelect = { (Get-ITGlueConfigurations -page_size 1000 -page_number $i -include related_items).data }
        $PreflightITGConfigurations = Import-ITGlueItems -ItemSelect $PreflightConfigurationsSelect
    } finally {
        $MigrationName = $previousMigrationName
    }

    $PreflightConfigurationTargetLayouts = switch ($ConfigurationSplitMode) {
        'Single' {
            if (@($PreflightITGConfigurations).Count -gt 0) {
                [pscustomobject]@{
                    SourceType = "Configurations"
                    SourceName = "Configurations"
                    TargetName = "$($ConfigurationPrefix)Configurations"
                    SourceId   = $null
                }
            }
        }

        'Smart' {
            $SmartConfigurationGroups = Resolve-SmartConfigurationSplits -Configurations @($PreflightITGConfigurations) -MaxCategories $SmartConfigurationMaxCategories
            $SmartConfigurationPreview = @(
                foreach ($group in @($SmartConfigurationGroups)) {
                    [pscustomobject]@{
                        TargetLayoutName = "$($ConfigurationPrefix)$($group.CategoryName)"
                        CategoryName     = $group.CategoryName
                        Count            = $group.Count
                        SourceTypes      = @($group.SourceTypes) -join '; '
                        SourceKinds      = @($group.SourceKinds) -join '; '
                        Tokens           = @($group.Tokens) -join '; '
                    }
                }
            )

            Write-Host "Smart configuration split preview ($(@($SmartConfigurationPreview).Count) categories, max $SmartConfigurationMaxCategories):" -ForegroundColor Cyan
            Write-Host ($SmartConfigurationPreview |
                Sort-Object -Property @{ Expression = 'Count'; Descending = $true }, @{ Expression = 'CategoryName'; Descending = $false } |
                Select-Object TargetLayoutName, Count, SourceTypes, SourceKinds |
                Format-Table -AutoSize -Wrap |
                Out-String -Width 4096)

            $smartPreviewLogPath = $MigrationLogs ?? $settings.MigrationLogs
            if (-not [string]::IsNullOrWhiteSpace([string]$smartPreviewLogPath)) {
                try {
                    if (-not (Test-Path -LiteralPath $smartPreviewLogPath -PathType Container)) {
                        $null = New-Item -Path $smartPreviewLogPath -ItemType Directory -Force
                    }

                    $jsonPreviewPath = Join-Path -Path $smartPreviewLogPath -ChildPath 'SmartConfigurationSplits-Preflight.json'
                    $csvPreviewPath = Join-Path -Path $smartPreviewLogPath -ChildPath 'SmartConfigurationSplits-Preflight.csv'
                    $SmartConfigurationPreview | ConvertTo-Json -Depth 20 | Out-File $jsonPreviewPath
                    $SmartConfigurationPreview | Export-Csv -Path $csvPreviewPath -NoTypeInformation
                    Write-Host "Smart configuration split preview written to $jsonPreviewPath and $csvPreviewPath" -ForegroundColor Cyan
                } catch {
                    Write-Warning "Could not write smart configuration split preview: $($_.Exception.Message)"
                }
            }

            foreach ($group in @($SmartConfigurationGroups)) {
                [pscustomobject]@{
                    SourceType = "Smart Configuration Group"
                    SourceName = @($group.SourceTypes) -join ', '
                    TargetName = "$($ConfigurationPrefix)$($group.CategoryName)"
                    SourceId   = $null
                }
            }
        }

        default {
            $ITGConfigTypes = $PreflightITGConfigurations.attributes."configuration-type-name" |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                Sort-Object -Unique

            foreach ($ConfigType in $ITGConfigTypes) {
                [pscustomobject]@{
                    SourceType = "Configuration Type"
                    SourceName = $ConfigType
                    TargetName = "$($ConfigurationPrefix)$($ConfigType)"
                    SourceId   = $null
                }
            }
        }
    }

    $PreflightHuduLayouts = $PreflightHuduLayouts ?? $(Get-HuduAssetLayouts)
    $configurationCollisionCheck = Test-HuduAssetLayoutTargetNameCollision `
        -TargetLayouts $PreflightConfigurationTargetLayouts `
        -HuduAssetLayouts $PreflightHuduLayouts `
        -HuduBaseUrl $HuduBaseDomain `
        -Detailed

    if (-not $configurationCollisionCheck.Success) {
        $PreflightCollisionFound = $true
        Write-Host "The following configuration asset layout target names already exist in Hudu:" -ForegroundColor Red
        Write-Host ($configurationCollisionCheck.Collisions |
            Sort-Object TargetName |
            Select-Object SourceType, SourceName, TargetName, HuduLayoutId, HuduManagementUrl |
            Format-Table -AutoSize -Wrap |
            Out-String -Width 4096)
        Write-Host "Resolve these by renaming the existing Hudu asset layout(s), changing the configuration prefix, or disabling configuration import before retrying." -ForegroundColor Red
    } else {
        Write-Host "Pre-flight configuration layout collision check passed." -ForegroundColor Green
    }
}

$PreflightOutlierTargetLayouts = @(
    if ($true -eq $ImportLocations -and -not ($ResumeFound -eq $true -and (Test-Path "$MigrationLogs\Locations.json"))) {
        [pscustomobject]@{
            SourceType = "Locations/Places"
            SourceName = $LocImportAssetLayoutName
            TargetName = $LocImportAssetLayoutName
            SourceId   = $null
        }
    }

    if ($true -eq $ImportContacts -and -not ($ResumeFound -eq $true -and (Test-Path "$MigrationLogs\Contacts.json"))) {
        [pscustomobject]@{
            SourceType = "Contacts/People"
            SourceName = $ConImportAssetLayoutName
            TargetName = $ConImportAssetLayoutName
            SourceId   = $null
        }
    }
) | Where-Object { -not [string]::IsNullOrWhiteSpace($_.TargetName) }

if (@($PreflightOutlierTargetLayouts).Count -gt 0) {
    Write-Host "Pre-flight: checking location and contact asset layout names against existing Hudu asset layouts." -ForegroundColor Green

    $PreflightHuduLayouts = $PreflightHuduLayouts ?? $(Get-HuduAssetLayouts)
    $outlierCollisionCheck = Test-HuduAssetLayoutTargetNameCollision `
        -TargetLayouts $PreflightOutlierTargetLayouts `
        -HuduAssetLayouts $PreflightHuduLayouts `
        -HuduBaseUrl $HuduBaseDomain `
        -Detailed

    if (-not $outlierCollisionCheck.Success) {
        $PreflightCollisionFound = $true
        Write-Host "The following location or contact asset layout target names already exist in Hudu:" -ForegroundColor Red
        Write-Host ($outlierCollisionCheck.Collisions |
            Sort-Object TargetName |
            Select-Object SourceType, SourceName, TargetName, HuduLayoutId, HuduManagementUrl |
            Format-Table -AutoSize -Wrap |
            Out-String -Width 4096)
        Write-Host "Resolve these by renaming the existing Hudu asset layout(s), changing the location/contact layout names, or disabling the corresponding import before retrying." -ForegroundColor Red
    } else {
        Write-Host "Pre-flight location and contact layout collision check passed." -ForegroundColor Green
    }
}

$plannedLayoutTargets = @($PreflightFlexibleTargetLayouts) + @($PreflightConfigurationTargetLayouts) + @($PreflightOutlierTargetLayouts)
$plannedTargetCollisions = $plannedLayoutTargets |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_.TargetName) } |
    Group-Object { $_.TargetName.Trim().ToLowerInvariant() } |
    Where-Object { $_.Count -gt 1 }

if ($plannedTargetCollisions) {
    $PreflightCollisionFound = $true
    Write-Host "The following planned asset layout target names would collide during this migration:" -ForegroundColor Red
    foreach ($collision in $plannedTargetCollisions) {
        Write-Host ($collision.Group |
            Select-Object SourceType, SourceName, TargetName, SourceId |
            Format-Table -AutoSize -Wrap |
            Out-String -Width 4096)
    }
    Write-Host "Resolve these by changing the FA prefix, configuration prefix, location/contact layout names, or source layout/type names before retrying." -ForegroundColor Red
}

