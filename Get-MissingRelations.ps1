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
if (-not $matchedChecklists -and (Test-Path -LiteralPath "$MigrationLogs\Checklists.json")) {$matchedChecklists = (Get-Content -path "$MigrationLogs\Checklists.json" | ConvertFrom-json -depth 100) }

$script:UnknownITGlueRelationTypeCounts = @{}
$script:UnresolvedITGlueRelationSamples = [System.Collections.ArrayList]@()
$script:UnresolvedITGlueRelationSampleCounts = @{}
foreach ($DiagnosticFileName in @('unknown-relation-types.json', 'unresolved-relation-samples.json')) {
    $DiagnosticFilePath = Join-Path $($MigrationLogs ?? $settings.MigrationLogs) $DiagnosticFileName
    if (Test-Path -LiteralPath $DiagnosticFilePath) {
        Remove-Item -LiteralPath $DiagnosticFilePath -Force
    }
}

write-host "refreshing $($MatchedAssets.count) assets"
$__asIdx = 0; $__asTotal = $MatchedAssets.count
$FreshITGAssets= $FreshITGAssets ?? $($MatchedAssets |ForEach-Object {
    $__asIdx++
    if ($__asIdx % 100 -eq 0 -or $__asIdx -eq $__asTotal) { Write-Host "  ...refreshed $__asIdx of $__asTotal assets" }
    Get-ITGlueFlexibleAssets -id $_.ITGObject.id -include related_items})
$RelatedAssets = $RelatedAssets ?? $($FreshITGAssets | Where-Object { Test-ITGlueResponseHasRelationData -Response $_ })

write-host "refreshing $($MatchedConfigurations.count) configs"
$__cfgIdx = 0; $__cfgTotal = $MatchedConfigurations.count
$FreshConfigurations = $FreshConfigurations ?? $($MatchedConfigurations | ForEach-Object {
    $__cfgIdx++
    if ($__cfgIdx % 100 -eq 0 -or $__cfgIdx -eq $__cfgTotal) { Write-Host "  ...refreshed $__cfgIdx of $__cfgTotal configs" }
    Get-ITGlueConfigurations -id $_.itgobject.id -include related_items})
$RelatedConfigurations = $RelatedConfigurations ?? $($FreshConfigurations | Where-Object { Test-ITGlueResponseHasRelationData -Response $_ })

write-host "refreshing $($MatchedPasswords.count) passwords"
$__pwIdx = 0; $__pwTotal = $MatchedPasswords.count
$FreshPasswords = $FreshPasswords ?? $($MatchedPasswords | ForEach-Object {
    $__pwIdx++
    if ($__pwIdx % 100 -eq 0 -or $__pwIdx -eq $__pwTotal) { Write-Host "  ...refreshed $__pwIdx of $__pwTotal passwords" }
    Get-ITGluePasswords -id $_.itgobject.id -include related_items})
$RelatedPasswords = $RelatedPasswords ?? $($FreshPasswords | Where-Object { Test-ITGlueResponseHasRelationData -Response $_ })

write-host "refreshing $($MatchedContacts.count) contacts"
$__ctIdx = 0; $__ctTotal = $MatchedContacts.count
$FreshContacts = $FreshContacts ?? $($MatchedContacts | ForEach-Object {
    $__ctIdx++
    if ($__ctIdx % 100 -eq 0 -or $__ctIdx -eq $__ctTotal) { Write-Host "  ...refreshed $__ctIdx of $__ctTotal contacts" }
    Get-ITGlueContacts -id $_.ITGObject.id -include related_items})
$RelatedContacts = $RelatedContacts ?? $($FreshContacts | Where-Object { Test-ITGlueResponseHasRelationData -Response $_ })

write-host "refreshing $($MatchedArticles.count) articles"
$__arIdx = 0; $__arTotal = $MatchedArticles.count
$FreshDocuments = $FreshDocuments ?? ($MatchedArticles | ForEach-Object {
    $__arIdx++
    if ($__arIdx % 100 -eq 0 -or $__arIdx -eq $__arTotal) { Write-Host "  ...refreshed $__arIdx of $__arTotal articles" }
    $ArticleLookup = Get-ArticleLookupInfo -Article $_
    if ($ArticleLookup) {
        Get-RelatedToDoc -DocID $ArticleLookup.DocID -OrganizationId $ArticleLookup.OrganizationId -ITGKey $ITGKey -ITGlue_Base_URI ($ITGAPIEndpoint ?? $settings.ITGAPIEndpoint)
    }
})
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
