if (-not ($FirstTimeLoad -eq 1)) {
    # General Settings Load
    . $PSScriptRoot\Initialize-Module.ps1 -InitType 'Lite'

}
if (-not $MatchedAssets -and (Test-Path -LiteralPath "$MigrationLogs\Assets.json")) {$MatchedAssets = (Get-Content -path "$MigrationLogs\Assets.json" | ConvertFrom-json -depth 100) }
if (-not $matchedConfigurations -and (Test-Path -LiteralPath "$MigrationLogs\Configurations.json")) {$matchedConfigurations = (Get-Content -path "$MigrationLogs\Configurations.json" | ConvertFrom-json -depth 100) }
if (-not $MatchedPasswords -and (Test-Path -LiteralPath "$MigrationLogs\Passwords.json")) {$MatchedPasswords = (Get-Content -path "$MigrationLogs\Passwords.json" | ConvertFrom-json -depth 100) }
if (-not $MatchedAssetPasswords -and (Test-Path -LiteralPath "$MigrationLogs\AssetPasswords.json")) {$MatchedAssetPasswords = (Get-Content -path "$MigrationLogs\AssetPasswords.json" | ConvertFrom-json -depth 100) }
if (-not $MatchedContacts -and (Test-Path -LiteralPath "$MigrationLogs\Contacts.json")) {$MatchedContacts = (Get-Content -path "$MigrationLogs\Contacts.json" | ConvertFrom-json -depth 100) }
if (-not $MatchedArticles -and (Test-Path -LiteralPath "$MigrationLogs\Articles.json")) {$MatchedArticles = (Get-Content -path "$MigrationLogs\Articles.json" | ConvertFrom-json -depth 100) }
if (-not $MatchedCompanies -and (Test-Path -LiteralPath "$MigrationLogs\Companies.json")) {$MatchedCompanies = (Get-Content -path "$MigrationLogs\Companies.json" | ConvertFrom-json -depth 100) }
if (-not $MatchedLocations -and (Test-Path -LiteralPath "$MigrationLogs\Locations.json")) {$MatchedLocations = (Get-Content -path "$MigrationLogs\Locations.json" | ConvertFrom-json -depth 100) }
if (-not $MatchedPasswords -and (Test-Path -LiteralPath "$MigrationLogs\Passwords.json")) {$MatchedPasswords = (Get-Content -path "$MigrationLogs\Passwords.json" | ConvertFrom-json -depth 100) }
if (-not $MatchedWebsites -and (Test-Path -LiteralPath "$MigrationLogs\websites.json")) {$MatchedWebsites = (Get-Content -path "$MigrationLogs\websites.json" | ConvertFrom-json -depth 100) }
if (-not $MatchedAssetLayoutFields -and (Test-Path -LiteralPath "$MigrationLogs\AssetLayoutsFields.json")) {$MatchedAssetLayoutFields = (Get-Content -path "$MigrationLogs\AssetLayoutsFields.json" | ConvertFrom-json -depth 100) }
if (-not $RelationsToCreate -and (Test-Path -LiteralPath "$MigrationLogs\RelationsToCreate.json")) {$RelationsToCreate = (Get-Content -path "$MigrationLogs\RelationsToCreate.json" | ConvertFrom-json -depth 100) }
$MigrationParallelismLimit = [int]($MigrationParallelismLimit ?? [math]::Min(12, [math]::Max(2, [Environment]::ProcessorCount - 1)))
$MigrationParallelismLimit = [math]::Min(12, [math]::Max(2, $MigrationParallelismLimit))
$UseFastRelationCommit = $UseFastRelationCommit ?? $true
$HuduFastCommitHeaders = $HuduFastCommitHeaders ?? @{}
if ($UseFastRelationCommit -and -not (Get-Command -Name Invoke-FastHuduRelationCommit -ErrorAction SilentlyContinue)) {
    . $PSScriptRoot\Public\Invoke-FastRelationCommit.ps1
}
if (-not (Get-Command -Name Read-PreloadedRelationData -ErrorAction SilentlyContinue)) {
    . $PSScriptRoot\Public\Get-PreloadedRelationData.ps1
}
if (-not $matchedChecklists -and (Test-Path -LiteralPath "$MigrationLogs\Checklists.json")) {$matchedChecklists = (Get-Content -path "$MigrationLogs\Checklists.json" | ConvertFrom-json -depth 100) }

function Get-ITGlueRelationSourceData {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("Assets","Configs","Locations","Contacts","Articles","Passwords","Procedures")]
        [string]$RelationType,

        [Parameter(Mandatory = $true)]
        [string]$DisplayName,

        [object[]]$ItgObjects = @(),

        [Parameter(Mandatory = $true)]
        [scriptblock]$FetchItem
    )

    $objects = @($ItgObjects | Where-Object { $_ })
    $preload = Read-PreloadedRelationData -RelationType $RelationType -MigrationLogs $MigrationLogs -WaitForJob -StatusSeconds 60
    if ($preload.Found) {
        Write-Host "Using preloaded relation metadata for $($preload.Data.Count) $DisplayName from $($preload.Path)" -ForegroundColor Green
        return @($preload.Data)
    }

    Write-Host "refreshing $($objects.Count) $DisplayName"
    $itemIndex = 0
    $itemTotal = $objects.Count
    foreach ($object in $objects) {
        $itemIndex++
        if ($itemIndex % 100 -eq 0 -or $itemIndex -eq $itemTotal) {
            Write-Host "  ...refreshed $itemIndex of $itemTotal $DisplayName"
        }

        & $FetchItem $object
    }
}

$script:UnknownITGlueRelationTypeCounts = @{}
$script:UnresolvedITGlueRelationSamples = [System.Collections.ArrayList]@()
$script:UnresolvedITGlueRelationSampleCounts = @{}
foreach ($DiagnosticFileName in @('unknown-relation-types.json', 'unresolved-relation-samples.json')) {
    $DiagnosticFilePath = Join-Path $($MigrationLogs ?? $settings.MigrationLogs) $DiagnosticFileName
    if (Test-Path -LiteralPath $DiagnosticFilePath) {
        Remove-Item -LiteralPath $DiagnosticFilePath -Force
    }
}

if ($null -eq $FreshITGAssets) {
    $FreshITGAssets = Get-ITGlueRelationSourceData -RelationType Assets -DisplayName 'assets' -ItgObjects @($MatchedAssets) -FetchItem {
        param($Item)
        Get-ITGlueFlexibleAssets -id $Item.ITGObject.id -include related_items
    }
}
$RelatedAssets = $RelatedAssets ?? $($FreshITGAssets | Where-Object { Test-ITGlueResponseHasRelationData -Response $_ })

if ($null -eq $FreshConfigurations) {
    $FreshConfigurations = Get-ITGlueRelationSourceData -RelationType Configs -DisplayName 'configs' -ItgObjects @($MatchedConfigurations) -FetchItem {
        param($Item)
        Get-ITGlueConfigurations -id $Item.ITGObject.id -include related_items
    }
}
$RelatedConfigurations = $RelatedConfigurations ?? $($FreshConfigurations | Where-Object { Test-ITGlueResponseHasRelationData -Response $_ })

if ($null -eq $FreshPasswords) {
    $FreshPasswords = Get-ITGlueRelationSourceData -RelationType Passwords -DisplayName 'passwords' -ItgObjects @($MatchedPasswords) -FetchItem {
        param($Item)
        Get-ITGluePasswords -id $Item.ITGObject.id -include related_items
    }
}
$RelatedPasswords = $RelatedPasswords ?? $($FreshPasswords | Where-Object { Test-ITGlueResponseHasRelationData -Response $_ })

if ($null -eq $FreshContacts) {
    $FreshContacts = Get-ITGlueRelationSourceData -RelationType Contacts -DisplayName 'contacts' -ItgObjects @($MatchedContacts) -FetchItem {
        param($Item)
        Get-ITGlueContacts -id $Item.ITGObject.id -include related_items
    }
}
$RelatedContacts = $RelatedContacts ?? $($FreshContacts | Where-Object { Test-ITGlueResponseHasRelationData -Response $_ })

if ($null -eq $FreshLocations) {
    $FreshLocations = Get-ITGlueRelationSourceData -RelationType Locations -DisplayName 'locations' -ItgObjects @($MatchedLocations) -FetchItem {
        param($Item)
        Get-ITGlueLocations -id $Item.ITGObject.id -include related_items
    }
}
$RelatedLocations = $RelatedLocations ?? $($FreshLocations | Where-Object { Test-ITGlueResponseHasRelationData -Response $_ })

if ($null -eq $FreshDocuments) {
    $FreshDocuments = Get-ITGlueRelationSourceData -RelationType Articles -DisplayName 'articles' -ItgObjects @($MatchedArticles) -FetchItem {
        param($Item)
        $ArticleLookup = Get-ArticleLookupInfo -Article $Item
        if ($ArticleLookup) {
            Get-RelatedToDoc -DocID $ArticleLookup.DocID -OrganizationId $ArticleLookup.OrganizationId -ITGKey $ITGKey -ITGlue_Base_URI ($ITGAPIEndpoint ?? $settings.ITGAPIEndpoint)
        }
    }
}
$RelatedDocuments = $RelatedDocuments ?? ($FreshDocuments | Where-Object { Test-ITGlueResponseHasRelationData -Response $_ })

write-host "mapping configs"
$MatchedConfigurationMap = @{}
$MatchedConfigurations | ForEach-Object { $MatchedConfigurationMap[[string]$_.ITGID] = $_ }

write-host "mapping articles"
$MatchedArticleMap = @{}
$MatchedArticles | ForEach-Object { $MatchedArticleMap[[string]$_.ITGID] = $_ }

write-host "mapping article folders"
$FreshDocumentMap = @{}
$FreshDocuments | Where-Object { $_ -and $_.data -and $_.data.id } | ForEach-Object {
    $FreshDocumentMap[[string]$_.data.id] = $_
}

$MatchedArticleDocumentFolderMap = @{}
$MatchedArticles | ForEach-Object {
    $Article = $_
    $DocumentResponse = $FreshDocumentMap[[string]$Article.ITGID]
    $DocumentFolderId = Get-ITGlueDocumentFolderId -Article $Article -ITGlueDocumentResponse $DocumentResponse
    if ($DocumentFolderId) {
        if (-not $MatchedArticleDocumentFolderMap.ContainsKey($DocumentFolderId)) {
            $MatchedArticleDocumentFolderMap[$DocumentFolderId] = [System.Collections.ArrayList]@()
        }

        [void]$MatchedArticleDocumentFolderMap[$DocumentFolderId].Add($Article)
    }
}

write-host "mapping contacts"
$MatchedContactMap = @{}
$MatchedContacts | ForEach-Object { $MatchedContactMap[[string]$_.ITGID] = $_ }

write-host "mapping assets"
$MatchedAssetMap = @{}
$MatchedAssets | ForEach-Object { $MatchedAssetMap[[string]$_.ITGID] = $_ }

write-host "mapping companies"
$MatchedCompanyMap = @{}
$MatchedCompanies | ForEach-Object { $MatchedCompanyMap[[string]$_.ITGID] = $_ }

write-host "mapping locations"
$MatchedLocationMap = @{}
$MatchedLocations | ForEach-Object { $MatchedLocationMap[[string]$_.ITGID] = $_ }

write-host "mapping passwords"
$MatchedPasswordMap = @{}
$MatchedPasswords | ForEach-Object { $MatchedPasswordMap[[string]$_.ITGID] = $_ }
$MatchedAssetPasswords | ForEach-Object { $MatchedPasswordMap[[string]$_.ITGID] = $_ }

write-host "mapping websites"
$MatchedWebsiteMap = @{}
$MatchedWebsites | ForEach-Object { $MatchedWebsiteMap[[string]$_.ITGID] = $_ }

write-host "mapping checklists"
$MatchedChecklistsMap = @{}
$MatchedChecklistsByNameMap = @{}
$MatchedChecklists | Where-Object { $_ -and $_.id -and $_.HuduProcedure } | ForEach-Object {
    $MatchedChecklistsMap[[string]$_.id] = $_

    $ChecklistNameKey = Get-NormalizedRelationLookupName -Name $_.attributes.name
    if ($ChecklistNameKey) {
        if (-not $MatchedChecklistsByNameMap.ContainsKey($ChecklistNameKey)) {
            $MatchedChecklistsByNameMap[$ChecklistNameKey] = [System.Collections.ArrayList]@()
        }

        [void]$MatchedChecklistsByNameMap[$ChecklistNameKey].Add($_)
    }
}

$DocumentRelationsToCreate = Get-HuduRelationObject -ITGlueSourceObjects $RelatedDocuments
$ContactRelationsToCreate = Get-HuduRelationObject -ITGlueSourceObjects $RelatedContacts
$ConfigurationRelationsToCreate = Get-HuduRelationObject -ITGlueSourceObjects $RelatedConfigurations
$LocationRelationsToCreate = Get-HuduRelationObject -ITGlueSourceObjects $RelatedLocations
$AssetRelationsToCreate = Get-HuduRelationObject -ITGlueSourceObjects $RelatedAssets
$PasswordRelationsToCreate = Get-HuduRelationObject -ITGlueSourceObjects $RelatedPasswords
$PasswordDocumentRelationsToCreate = Get-PasswordDocumentRelationObject -MatchedPasswords $MatchedPasswords
$TagFieldRelationsToCreate = Get-HuduRelationObjectFromTagFields -MatchedAssets $MatchedAssets -MatchedAssetLayoutFields $MatchedAssetLayoutFields
$QueuedTagRelationsToCreate = $RelationsToCreate | ForEach-Object { Convert-QueuedTagRelationToHuduRelationObject -Relation $_ }

$AllRelationsToCreate =
    @($AssetRelationsToCreate) +
    @($DocumentRelationsToCreate) +
    @($ContactRelationsToCreate) +
    @($PasswordRelationsToCreate) +
    @($PasswordDocumentRelationsToCreate) +
    @($TagFieldRelationsToCreate) +
    @($QueuedTagRelationsToCreate) +
    @($LocationRelationsToCreate) +
    @($ConfigurationRelationsToCreate) |
    Where-Object { $_ } |
    Sort-Object FromableType, FromableID, ToableType, ToableID -Unique


if (get-command -name Set-HapiErrorsDirectory -ErrorAction SilentlyContinue){try {Set-HapiErrorsDirectory -skipRetry $true} catch {}}
write-host "Creating approximately $($AllRelationsToCreate.count) relations"
$RelationCommitResults = if ($UseFastRelationCommit) {
    $fastRelationCommitParams = @{
        Relations     = @($AllRelationsToCreate)
        ThrottleLimit = $MigrationParallelismLimit
    }
    if ($HuduFastCommitHeaders -and $HuduFastCommitHeaders.Count -gt 0) {
        $fastRelationCommitParams.CustomHeaders = $HuduFastCommitHeaders
    }
    Invoke-FastHuduRelationCommit @fastRelationCommitParams
} else {
    $__relIdx = 0; $__relTotal = $AllRelationsToCreate.count
    $AllRelationsToCreate | ForEach-Object {
        $__relIdx++
        if ($__relIdx % 100 -eq 0 -or $__relIdx -eq $__relTotal) { Write-Host "  ...creating relation $__relIdx of $__relTotal" }
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $relation = New-HuduRelation -FromableType $_.FromableType -FromableID $_.FromableID -ToableType $_.ToableType -ToableID $_.ToableID
            $stopwatch.Stop()
            [pscustomobject]@{
                Status         = if ($relation) { 'created' } else { 'skipped' }
                Relation       = $relation
                SourceRelation = $_
                Attempts       = 1
                SleptSeconds   = 0
                ElapsedSeconds = [math]::Round($stopwatch.Elapsed.TotalSeconds, 3)
                StatusCode     = $null
            }
        } catch {
            $stopwatch.Stop()
            [pscustomobject]@{
                Status         = 'failed'
                Relation       = $null
                SourceRelation = $_
                Attempts       = 1
                SleptSeconds   = 0
                ElapsedSeconds = [math]::Round($stopwatch.Elapsed.TotalSeconds, 3)
                StatusCode     = $null
                Error          = $_.Exception.Message
            }
        }
    }
}
$NewRelationsCreated = @($RelationCommitResults | Where-Object { $_.Relation } | ForEach-Object { $_.Relation })

$AllRelationsToCreate | ConvertTo-Json -Depth 75 | Out-File (Join-Path $($MigrationLogs ?? $settings.MigrationLogs) 'relations-to-create.json')
$NewRelationsCreated | ConvertTo-Json -Depth 75 | Out-File (Join-Path $($MigrationLogs ?? $settings.MigrationLogs) 'relations-created.json')
$RelationCommitResults | ConvertTo-Json -Depth 75 | Out-File (Join-Path $($MigrationLogs ?? $settings.MigrationLogs) 'relation-commit-results.json')

if ($script:UnknownITGlueRelationTypeCounts -and $script:UnknownITGlueRelationTypeCounts.Count -gt 0) {
    $UnknownRelationTypes = $script:UnknownITGlueRelationTypeCounts.GetEnumerator() |
        Sort-Object Name |
        ForEach-Object {
            [pscustomobject]@{
                TypeName = $_.Name
                Count    = $_.Value
            }
        }

    $UnknownRelationTypes | ConvertTo-Json -Depth 10 | Out-File (Join-Path $($MigrationLogs ?? $settings.MigrationLogs) 'unknown-relation-types.json')
    Write-Warning "Encountered $($UnknownRelationTypes.Count) unsupported ITGlue relation type(s). Details saved to unknown-relation-types.json"
}
