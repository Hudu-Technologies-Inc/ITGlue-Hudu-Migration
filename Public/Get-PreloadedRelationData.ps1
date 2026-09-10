
function Get-RelatedToDoc {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$ITGKey,

        [Parameter(Mandatory = $true)]
        [long]$OrganizationId,

        [Parameter(Mandatory = $true)]
        [long]$DocID,

        [string]$ITGlue_Base_URI = 'https://api.itglue.com'
    )

    if ($OrganizationId -le 0 -or $DocID -le 0) {
        Write-Warning "Skipping ITGlue document lookup because doc/org id is invalid. DocID=$DocID OrganizationId=$OrganizationId"
        return
    }

    $headers = @{
        'x-api-key'    = $ITGKey
        'Content-Type' = 'application/vnd.api+json'
    }

    $baseUri = $ITGlue_Base_URI.TrimEnd('/')
    $candidateUris = @(
        "$baseUri/organizations/$OrganizationId/relationships/documents/$DocID?include=related_items",
        "$baseUri/organizations/$OrganizationId/documents/$DocID?include=related_items",
        "$baseUri/documents/$DocID?include=related_items",
        "$baseUri/organizations/$OrganizationId/relationships/documents/$DocID"
    ) | Select-Object -Unique

    $LastError = $null
    foreach ($uri in $candidateUris) {
        try {
            $Response = Invoke-RestMethod -Method GET -Uri $uri -Headers $headers
            if ($Response) {
                return $Response
            }
        }
        catch {
            $LastError = $_
        }
    }

    Write-Warning "Failed to retrieve ITGlue document $DocID for organization $OrganizationId"
    if ($LastError) {
        if ($LastError.ErrorDetails.Message) {
            Write-Warning $LastError.ErrorDetails.Message
        } else {
            Write-Warning $LastError.Exception.Message
        }
    }
}
function Add-UnknownITGlueRelationType {
    param(
        [string]$TypeName
    )

    $TypeName = [string]($TypeName ?? '').Trim()
    if ([string]::IsNullOrWhiteSpace($TypeName)) {
        return
    }

    if (-not $script:UnknownITGlueRelationTypeCounts) {
        $script:UnknownITGlueRelationTypeCounts = @{}
    }

    if ($script:UnknownITGlueRelationTypeCounts.ContainsKey($TypeName)) {
        $script:UnknownITGlueRelationTypeCounts[$TypeName]++
        return
    }

    $script:UnknownITGlueRelationTypeCounts[$TypeName] = 1
    Write-Warning "Encountered unsupported ITGlue relation type '$TypeName'"
}
function Add-UnresolvedITGlueRelationSample {
    param(
        [string]$TypeName,
        [string]$Reason,
        $RelationObject
    )

    if (-not $MigrationLogs -and (-not $settings -or -not $settings.MigrationLogs)) {
        return
    }

    $TypeName = [string]($TypeName ?? 'unknown')
    if (-not $script:UnresolvedITGlueRelationSamples) {
        $script:UnresolvedITGlueRelationSamples = [System.Collections.ArrayList]@()
        $script:UnresolvedITGlueRelationSampleCounts = @{}
    }

    $CurrentCount = [int]($script:UnresolvedITGlueRelationSampleCounts[$TypeName] ?? 0)
    if ($CurrentCount -ge 5) {
        return
    }

    $script:UnresolvedITGlueRelationSampleCounts[$TypeName] = $CurrentCount + 1
    [void]$script:UnresolvedITGlueRelationSamples.Add([pscustomobject]@{
        TypeName = $TypeName
        Reason   = $Reason
        Sample   = $RelationObject
    })

    $script:UnresolvedITGlueRelationSamples |
        ConvertTo-Json -Depth 20 |
        Out-File (Join-Path $($MigrationLogs ?? $settings.MigrationLogs) 'unresolved-relation-samples.json')
}
function Convert-ITGlueTypeToRelationAssetType {
    param(
        [string]$TypeName
    )

    switch -Regex (($TypeName ?? '').Trim().ToLower()) {
        '^flexible[-_\s]?assets?$' { return 'flexible_asset' }
        '^configurations?$' { return 'configuration' }
        '^passwords?$' { return 'password' }
        '^documents?$' { return 'document' }
        '^document[/\\]folders?$' { return 'document_folder' }
        '^document[-_\s]?folders?$' { return 'document_folder' }
        '^article[-_\s]?folders?$' { return 'document_folder' }
        '^checklists?$' { return 'checklist' }
        '^checklist[-_\s]?templates?$' { return 'checklist_template' }
        '^tags?$' { return $null }
        '^contacts?$' { return 'contact' }
        '^locations?$' { return 'location' }
        '^organizations?$' { return 'organization' }
        '^companies$' { return 'organization' }
        '^domains?$' { return 'domain' }
        '^websites?$' { return 'domain' }
        default {
            Add-UnknownITGlueRelationType -TypeName $TypeName
            return $null
        }
    }
}
function Convert-ITGlueTagSubTypeToRelationAssetType {
    param(
        [string]$SubType
    )

    switch -Regex (($SubType ?? '').Trim()) {
        '^Configurations$' { return 'configuration' }
        '^Contacts$' { return 'contact' }
        '^Documents$' { return 'document' }
        '^Document[-_\s]?Folders$' { return 'document_folder' }
        '^Domains$' { return 'domain' }
        '^Websites$' { return 'domain' }
        '^Passwords$' { return 'password' }
        '^Organizations$' { return 'organization' }
        '^Companies$' { return 'organization' }
        '^Locations$' { return 'location' }
        '^FlexibleAssetType$' { return 'flexible_asset' }
        '^Flexible[-_\s]?Assets?$' { return 'flexible_asset' }
        '^Checklists$' { return 'checklist' }
        '^Checklist[-_\s]?Templates$' { return 'checklist_template' }
        default { return $null }
    }
}
function Get-NormalizedRelationLookupName {
    param(
        [string]$Name
    )

    $Name = [string]($Name ?? '').Trim()
    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $null
    }

    return ($Name -replace '\s+', ' ').ToLowerInvariant()
}
function Resolve-ITGlueRelationReference {
    param(
        $ITGlueRelationObject
    )

    if (-not $ITGlueRelationObject) {
        return $null
    }

    $AssetType = $null
    $ResourceId = $null
    $ResourceName = $null

    if ($ITGlueRelationObject.type -match '^related[-_]?items?$') {
        $AssetType = Convert-ITGlueTypeToRelationAssetType -TypeName (
            $ITGlueRelationObject.attributes.'destination_type' ??
            $ITGlueRelationObject.attributes.'destination-type' ??
            $ITGlueRelationObject.attributes.'asset-type' ??
            $ITGlueRelationObject.attributes.'resource-type'
        )

        $ResourceId = (
            $ITGlueRelationObject.attributes.'destination_id' ??
            $ITGlueRelationObject.attributes.'destination-id' ??
            $ITGlueRelationObject.attributes.'resource-id'
        )

        $ResourceName = $ITGlueRelationObject.attributes.'name'
    } elseif ($ITGlueRelationObject.type -eq 'tag') {
        $AssetType = Convert-ITGlueTypeToRelationAssetType -TypeName (
            $ITGlueRelationObject.attributes.'destination_type' ??
            $ITGlueRelationObject.attributes.'destination-type' ??
            $ITGlueRelationObject.attributes.'tag-type' ??
            $ITGlueRelationObject.attributes.'taggable-type' ??
            $ITGlueRelationObject.attributes.'resource-type' ??
            $ITGlueRelationObject.attributes.'asset-type'
        )

        $ResourceId = (
            $ITGlueRelationObject.attributes.'destination_id' ??
            $ITGlueRelationObject.attributes.'destination-id' ??
            $ITGlueRelationObject.attributes.'tag-id' ??
            $ITGlueRelationObject.attributes.'taggable-id' ??
            $ITGlueRelationObject.attributes.'resource-id'
        )

        $ResourceName = $ITGlueRelationObject.attributes.'name'
    } elseif ($ITGlueRelationObject.attributes.'asset-type' -and $ITGlueRelationObject.attributes.'resource-id') {
        $AssetType = Convert-ITGlueTypeToRelationAssetType -TypeName $ITGlueRelationObject.attributes.'asset-type'
        $ResourceId = $ITGlueRelationObject.attributes.'resource-id'
        $ResourceName = $ITGlueRelationObject.attributes.'name'
    } elseif ($ITGlueRelationObject.attributes.'destination_type' -and $ITGlueRelationObject.attributes.'destination_id') {
        $AssetType = Convert-ITGlueTypeToRelationAssetType -TypeName $ITGlueRelationObject.attributes.'destination_type'
        $ResourceId = $ITGlueRelationObject.attributes.'destination_id'
        $ResourceName = $ITGlueRelationObject.attributes.'name'
    } elseif ($ITGlueRelationObject.type -and $ITGlueRelationObject.id) {
        $AssetType = Convert-ITGlueTypeToRelationAssetType -TypeName $ITGlueRelationObject.type
        $ResourceId = $ITGlueRelationObject.id
        $ResourceName = $ITGlueRelationObject.attributes.'name'
    } else {
        $ITGlueRelationObject | convertto-json -Depth 10 | out-file (Join-Path $($MigrationLogs ?? $settings.MigrationLogs) "unresolved-relation-$($ITGlueRelationObject.GetHashCode()).json")
    }

    if (-not $AssetType -or -not $ResourceId) {
        Add-UnresolvedITGlueRelationSample -TypeName $ITGlueRelationObject.type -Reason 'Could not resolve target type or id' -RelationObject $ITGlueRelationObject
        return $null
    }

    return [pscustomobject]@{
        AssetType  = $AssetType
        ResourceId = [string]$ResourceId
        Name       = [string]$ResourceName
    }
}
function Get-HuduIdFromItglueObject {
    param(
        $ITGObjectId,
        $AssetType
    )

    $ITGObjectId = [string]$ITGObjectId
    $FoundHuduObject = $null
    $FoundHuduAssetType = $null

    switch ($AssetType) {
        'configuration' {
            $FoundHuduObject = $MatchedConfigurationMap[$ITGObjectId].HuduObject
            $FoundHuduAssetType = "Asset"
        }
        'document' {
            $FoundHuduObject = $MatchedArticleMap[$ITGObjectId].HuduObject
            $FoundHuduAssetType = 'Article'
        }
        'document_folder' {
            $FoundHuduObject = $MatchedArticleDocumentFolderMap[$ITGObjectId].HuduObject
            $FoundHuduAssetType = 'Article'
        }
        'contact' {
            $FoundHuduObject = $MatchedContactMap[$ITGObjectId].HuduObject
            $FoundHuduAssetType = 'Asset'
        }
        'flexible_asset' {
            $FoundHuduObject = $MatchedAssetMap[$ITGObjectId].HuduObject
            $FoundHuduAssetType = "Asset"
        }
        'location' {
            $FoundHuduObject = $MatchedLocationMap[$ITGObjectId].HuduObject
            $FoundHuduAssetType = "Asset"
        }
        'password' {
            $FoundHuduObject = $MatchedPasswordMap[$ITGObjectId].HuduObject
            $FoundHuduAssetType = 'AssetPassword'
        }
        'organization' {
            $FoundHuduObject = $MatchedCompanyMap[$ITGObjectId].HuduCompanyObject
            $FoundHuduAssetType = 'Company'
        }
        'domain' {
            $FoundHuduObject = $MatchedWebsiteMap[$ITGObjectId].HuduObject
            $FoundHuduAssetType = 'Website'
        }
        'checklist' {
            $FoundHuduObject = $MatchedChecklistsMap[$ITGObjectId].HuduProcedure
            $FoundHuduAssetType = 'Procedure'
        }
        'checklist_template' {
            $FoundHuduObject = $MatchedChecklistsMap[$ITGObjectId].HuduProcedure
            $FoundHuduAssetType = 'Procedure'
        }
                
    }

    if ($FoundHuduObject) {
        return [pscustomobject]@{
            HuduObject = $FoundHuduObject
            Type       = $FoundHuduAssetType
        }
    }
    else {
        Write-Warning "Unable to match ITGlue $AssetType to Hudu object for ITG object $ITGObjectId"
    }
}
function Get-HuduItemsFromItglueObject {
    param(
        $ITGObjectId,
        $AssetType,
        $RelationReference
    )

    $ITGObjectId = [string]$ITGObjectId

    if ($AssetType -eq 'document_folder') {
        $FolderArticles = @($MatchedArticleDocumentFolderMap[$ITGObjectId])
        if ($FolderArticles.Count -gt 0) {
            return $FolderArticles | ForEach-Object {
                [pscustomobject]@{
                    HuduObject = $_.HuduObject
                    Type       = 'Article'
                }
            }
        }

        Write-Warning "Unable to match ITGlue document folder to child Hudu articles for ITG folder $ITGObjectId"
        return
    }

    if ($AssetType -eq 'checklist_template') {
        $DirectTemplateObject = $MatchedChecklistsMap[$ITGObjectId].HuduProcedure
        if ($DirectTemplateObject) {
            return [pscustomobject]@{
                HuduObject = $DirectTemplateObject
                Type       = 'Procedure'
            }
        }

        $TemplateNameKey = Get-NormalizedRelationLookupName -Name $RelationReference.Name
        if ($TemplateNameKey) {
            $TemplateNameMatches = @($MatchedChecklistsByNameMap[$TemplateNameKey])
            if ($TemplateNameMatches.Count -eq 1) {
                return [pscustomobject]@{
                    HuduObject = $TemplateNameMatches[0].HuduProcedure
                    Type       = 'Procedure'
                }
            }

            if ($TemplateNameMatches.Count -gt 1) {
                Write-Warning "Unable to match ITGlue checklist_template $ITGObjectId by name '$($RelationReference.Name)' because multiple migrated procedures have that name"
                return
            }
        }
    }

    $MatchedItem = Get-HuduIdFromItglueObject -ITGObjectId $ITGObjectId -AssetType $AssetType
    if ($MatchedItem) {
        return $MatchedItem
    }
}
function Get-SingleRelationValue {
    param(
        $Value,
        [string]$Label
    )

    $Values = @($Value | Where-Object { $null -ne $_ -and "$_".Trim() -ne '' } | Select-Object -Unique)
    if ($Values.Count -eq 1) {
        return $Values[0]
    }

    if ($Values.Count -gt 1) {
        Write-Warning "Skipping relation because $Label resolved to multiple values: $($Values -join ', ')"
    }

    return $null
}
function Get-ITGlueDocumentFolderId {
    param(
        $Article,
        $ITGlueDocumentResponse
    )

    $FolderId = Get-SingleRelationValue -Value @(
        $Article.ITGObject.attributes.'document-folder-id'
        $Article.ITGObject.attributes.'document_folder_id'
        $ITGlueDocumentResponse.data.attributes.'document-folder-id'
        $ITGlueDocumentResponse.data.attributes.'document_folder_id'
    ) -Label 'Document folder ITGID'

    if ($FolderId) {
        return [string]$FolderId
    }
}
function Get-ArticleLookupInfo {
    param(
        $Article
    )

    $ResolvedDocId = Get-SingleRelationValue -Value @(
        $Article.ITGID
        $Article.ITGObject.id
    ) -Label 'Document ITGID'

    $ResolvedOrganizationId = Get-SingleRelationValue -Value @(
        $Article.Company.ITGID
        $Article.Company.ITGCompanyObject.id
        $Article.ITGObject.attributes.'organization-id'
    ) -Label 'Document OrganizationId'

    if (-not $ResolvedDocId -or -not $ResolvedOrganizationId) {
        return $null
    }

    return [pscustomobject]@{
        DocID          = [long]$ResolvedDocId
        OrganizationId = [long]$ResolvedOrganizationId
    }
}
function Test-ITGlueResponseHasRelationData {
    param(
        $Response
    )

    if (-not $Response) {
        return $false
    }

    if (@($Response.included).Count -gt 0) {
        return $true
    }

    if (@($($Response.data.relationships.'related-items' ?? $Response.data.relationships.'related-item').data).Count -gt 0) {
        return $true
    }

    return $false
}
function Test-ITGlueRelationPointerOnly {
    param(
        $ITGlueRelationObject
    )

    if (-not $ITGlueRelationObject) {
        return $false
    }

    if ($ITGlueRelationObject.attributes) {
        return $false
    }

    return [bool]($ITGlueRelationObject.id -and $ITGlueRelationObject.type -match '^(related[-_]?items?|tags?)$')
}
function Get-PasswordDocumentLookupInfo {
    param(
        $Password
    )

    if (-not $Password -or -not $Password.ITGObject) {
        return $null
    }

    $ParentUrl = [string]$Password.ITGObject.attributes.'parent-url'
    $ResourceType = [string]$Password.ITGObject.attributes.'resource-type'
    $ResourceId = Get-SingleRelationValue -Value @(
        $Password.ITGObject.attributes.'resource-id'
        if ($ParentUrl -match '/docs/(\d+)') { $Matches[1] }
    ) -Label 'Password Document ITGID'

    if (-not $ResourceId) {
        return $null
    }

    if (($ResourceType -and $ResourceType -notmatch '^documents?$') -and ($ParentUrl -notmatch '/docs/')) {
        return $null
    }

    return [pscustomobject]@{
        PasswordItgId = [string]$Password.ITGID
        DocumentItgId = [string]$ResourceId
    }
}
function New-HuduRelationPair {
    param(
        [string]$LeftType,
        [int]$LeftId,
        [string]$RightType,
        [int]$RightId
    )

    @(
        [pscustomobject]@{
            FromableType = $LeftType
            FromableID   = $LeftId
            ToableType   = $RightType
            ToableID     = $RightId
        }
        [pscustomobject]@{
            FromableType = $RightType
            FromableID   = $RightId
            ToableType   = $LeftType
            ToableID     = $LeftId
        }
    )
}
function Get-HuduRelationObject {
    param(
        $ITGlueSourceObjects
    )

    $NewHuduRelations = foreach ($ITGlueSourceObject in $ITGlueSourceObjects) {
        $AssetType = Convert-ITGlueTypeToRelationAssetType -TypeName $ITGlueSourceObject.data.type
        if (-not $AssetType) { continue }

        $FromableHudu = Get-HuduIdFromItglueObject -AssetType $AssetType -ITGObjectId $ITGlueSourceObject.data.id
        if (-not $FromableHudu) { continue }

        Write-Host "Determining Hudu objects for source $AssetType / ITGID: $($ITGlueSourceObject.data.id)" -ForegroundColor Cyan

        foreach ($LinkedITGlueObject in @($ITGlueSourceObject.included) + @($ITGlueSourceObject.data.relationships.'related-items'.data)) {
            if (Test-ITGlueRelationPointerOnly -ITGlueRelationObject $LinkedITGlueObject) { continue }

            $LinkedReference = Resolve-ITGlueRelationReference -ITGlueRelationObject $LinkedITGlueObject
            if (-not $LinkedReference) { continue }

            foreach ($LinkedHuduItem in @(Get-HuduItemsFromItglueObject -AssetType $LinkedReference.AssetType -ITGObjectId $LinkedReference.ResourceId -RelationReference $LinkedReference)) {
                $FromableType = Get-SingleRelationValue -Value $FromableHudu.type -Label 'FromableType'
                $FromableID = Get-SingleRelationValue -Value $FromableHudu.HuduObject.id -Label 'FromableID'
                $ToableType = Get-SingleRelationValue -Value $LinkedHuduItem.type -Label 'ToableType'
                $ToableID = Get-SingleRelationValue -Value $LinkedHuduItem.HuduObject.id -Label 'ToableID'

                if (-not $FromableType -or -not $FromableID -or -not $ToableType -or -not $ToableID) {
                    continue
                }

                [pscustomobject]@{
                    FromableType = [string]$FromableType
                    FromableID   = [int]$FromableID
                    ToableType   = [string]$ToableType
                    ToableID     = [int]$ToableID
                }
            }
        }
    }

    return $NewHuduRelations
}
function Get-HuduRelationObjectFromTagFields {
    param(
        $MatchedAssets,
        $MatchedAssetLayoutFields
    )

    if (-not $MatchedAssetLayoutFields) {
        return
    }

    foreach ($UpdateAsset in $MatchedAssets) {
        if (-not $UpdateAsset.ITGObject.attributes.traits) { continue }

        $SourceHuduId = Get-SingleRelationValue -Value @(
            $UpdateAsset.HuduID
            $UpdateAsset.HuduObject.id
        ) -Label 'Tag source HuduID'

        if (-not $SourceHuduId) { continue }

        $traits = $UpdateAsset.ITGObject.attributes.traits
        foreach ($TraitProperty in $traits.PSObject.Properties) {
            $ITGParsed = $TraitProperty.Name
            $ITGValues = $TraitProperty.Value
            $field = $MatchedAssetLayoutFields | Where-Object {
                $_.IGLayoutID -eq $UpdateAsset.ITGObject.attributes.'flexible-asset-type-id' -and
                $_.ITGParsedName -eq $ITGParsed
            } | Select-Object -First 1

            if (-not $field -or $field.FieldType -ne 'Tag') { continue }

            $TargetAssetType = Convert-ITGlueTagSubTypeToRelationAssetType -SubType $field.FieldSubType
            if (-not $TargetAssetType) { continue }
            if ($TargetAssetType -eq 'domain' -and $true -ne $ImportDomains) {
                Write-Host "Skipping website/domain tag relations for $($field.FieldName) in $($UpdateAsset.Name) because website migration is disabled." -ForegroundColor Yellow
                continue
            }

            foreach ($TagValue in @($ITGValues.values)) {
                $TargetItgId = Get-SingleRelationValue -Value @(
                    $TagValue.id
                    $TagValue.'resource-id'
                    $TagValue.'resource_id'
                ) -Label "Tag target ITGID for $($field.FieldName)"

                if (-not $TargetItgId) { continue }

                $RelationReference = [pscustomobject]@{
                    AssetType  = $TargetAssetType
                    ResourceId = [string]$TargetItgId
                    Name       = [string]$TagValue.name
                }

                foreach ($LinkedHuduItem in @(Get-HuduItemsFromItglueObject -AssetType $TargetAssetType -ITGObjectId $TargetItgId -RelationReference $RelationReference)) {
                    $ToableType = Get-SingleRelationValue -Value $LinkedHuduItem.Type -Label 'Tag ToableType'
                    $ToableID = Get-SingleRelationValue -Value $LinkedHuduItem.HuduObject.id -Label 'Tag ToableID'
                    if (-not $ToableType -or -not $ToableID) { continue }

                    [pscustomobject]@{
                        FromableType = 'Asset'
                        FromableID   = [int]$SourceHuduId
                        ToableType   = [string]$ToableType
                        ToableID     = [int]$ToableID
                    }
                }
            }
        }
    }
}
function Convert-QueuedTagRelationToHuduRelationObject {
    param(
        $Relation
    )

    if (-not $Relation) { return }

    $SourceHuduId = Get-SingleRelationValue -Value $Relation.hudu_from_id -Label 'Queued tag source HuduID'
    if (-not $SourceHuduId) { return }

    $TargetAssetType = switch ($Relation.relation_type) {
        'Article' { 'document' }
        'AssetPassword' { 'password' }
        'Company' { 'organization' }
        'Website' { 'domain' }
        'Procedure' { 'checklist' }
        default { $null }
    }

    if (-not $TargetAssetType) { return }

    if ($Relation.relation_type -eq 'Procedure') {
        $ProcedureObject = $MatchedChecklistsMap[[string]$Relation.itg_to_id].HuduProcedure
        if ($ProcedureObject) {
            $LinkedHuduItem = [pscustomobject]@{
                HuduObject = $ProcedureObject
                Type       = 'Procedure'
            }
        }
    }
    else {
        $LinkedHuduItem = Get-HuduIdFromItglueObject -AssetType $TargetAssetType -ITGObjectId $Relation.itg_to_id
    }
    if (-not $LinkedHuduItem) { return }

    $ToableType = Get-SingleRelationValue -Value $LinkedHuduItem.Type -Label 'Queued tag ToableType'
    $ToableID = Get-SingleRelationValue -Value $LinkedHuduItem.HuduObject.id -Label 'Queued tag ToableID'
    if (-not $ToableType -or -not $ToableID) { return }

    [pscustomobject]@{
        FromableType = 'Asset'
        FromableID   = [int]$SourceHuduId
        ToableType   = [string]$ToableType
        ToableID     = [int]$ToableID
    }
}
function Get-PasswordDocumentRelationObject {
    param(
        $MatchedPasswords
    )

    foreach ($Password in $MatchedPasswords) {
        $Lookup = Get-PasswordDocumentLookupInfo -Password $Password
        if (-not $Lookup) { continue }

        if (-not $MatchedPasswordMap.ContainsKey($Lookup.PasswordItgId)) { continue }
        if (-not $MatchedArticleMap.ContainsKey($Lookup.DocumentItgId)) { continue }

        $PasswordHuduObject = $MatchedPasswordMap[$Lookup.PasswordItgId].HuduObject
        $DocumentHuduObject = $MatchedArticleMap[$Lookup.DocumentItgId].HuduObject
        if (-not $PasswordHuduObject -or -not $DocumentHuduObject) { continue }

        $PasswordType = Get-SingleRelationValue -Value 'AssetPassword' -Label 'PasswordType'
        $PasswordId = Get-SingleRelationValue -Value $PasswordHuduObject.id -Label 'PasswordID'
        $DocumentType = Get-SingleRelationValue -Value 'Article' -Label 'DocumentType'
        $DocumentId = Get-SingleRelationValue -Value $DocumentHuduObject.id -Label 'DocumentID'

        if (-not $PasswordType -or -not $PasswordId -or -not $DocumentType -or -not $DocumentId) {
            continue
        }

        New-HuduRelationPair -LeftType $PasswordType -LeftId ([int]$PasswordId) -RightType $DocumentType -RightId ([int]$DocumentId)
    }
}


function Get-RelationPreloadPath {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("Assets","Configs","Locations","Contacts","Articles","Passwords","Procedures")]
        [string]$RelationType,

        [string]$MigrationLogs
    )

    if ([string]::IsNullOrWhiteSpace($MigrationLogs)) {
        $MigrationLogs = $settings.MigrationLogs
    }

    Join-Path $MigrationLogs "RelationsPreload-$RelationType.json"
}

function Get-RelationPreloadStatusPath {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("Assets","Configs","Locations","Contacts","Articles","Passwords","Procedures")]
        [string]$RelationType,

        [string]$MigrationLogs
    )

    if ([string]::IsNullOrWhiteSpace($MigrationLogs)) {
        $MigrationLogs = $settings.MigrationLogs
    }

    Join-Path $MigrationLogs "RelationsPreload-$RelationType.status.json"
}

function Write-RelationPreloadStatus {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("Assets","Configs","Locations","Contacts","Articles","Passwords","Procedures")]
        [string]$RelationType,

        [Parameter(Mandatory = $true)]
        [string]$State,

        [string]$MigrationLogs,
        [datetime]$StartedAt,
        [datetime]$FinishedAt,
        [int]$FetchedCount = 0,
        [int]$RelatedCount = 0,
        [string]$ErrorMessage
    )

    if ([string]::IsNullOrWhiteSpace($MigrationLogs)) {
        $MigrationLogs = $settings.MigrationLogs
    }

    if ([string]::IsNullOrWhiteSpace($MigrationLogs)) {
        return
    }

    $status = [ordered]@{
        RelationType = $RelationType
        State        = $State
        StartedAt    = if ($StartedAt) { $StartedAt.ToString('o') } else { $null }
        FinishedAt   = if ($FinishedAt) { $FinishedAt.ToString('o') } else { $null }
        FetchedCount = $FetchedCount
        RelatedCount = $RelatedCount
        Error        = $ErrorMessage
    }

    $statusPath = Get-RelationPreloadStatusPath -RelationType $RelationType -MigrationLogs $MigrationLogs
    $status | ConvertTo-Json -Depth 10 | Out-File -LiteralPath $statusPath
}

function Initialize-ITGlueRelationPreloadApiContext {
    param(
        [string]$ITGKey,
        [string]$ITGAPIEndpoint
    )

    if (-not (Get-Command -Name Get-ITGlueFlexibleAssets -ErrorAction SilentlyContinue)) {
        Import-Module ITGlueAPIv2 -ErrorAction Stop
    }

    if (-not [string]::IsNullOrWhiteSpace($ITGAPIEndpoint) -and (Get-Command -Name Add-ITGlueBaseURI -ErrorAction SilentlyContinue)) {
        Add-ITGlueBaseURI -base_uri $ITGAPIEndpoint
    }

    if (-not [string]::IsNullOrWhiteSpace($ITGKey) -and (Get-Command -Name Add-ITGlueAPIKey -ErrorAction SilentlyContinue)) {
        Add-ITGlueAPIKey $ITGKey
    }
}

function Get-PreloadedRelationData {
    param (
        [Parameter(Mandatory = $true)]
        [ValidateSet("Assets","Configs","Locations","Contacts","Articles","Passwords","Procedures")]
        [string]$RelationType,

        [object[]]$ItgObjects = @(),
        [string]$ITGKey,
        [string]$ITGAPIEndpoint,
        [string]$MigrationLogs
    )

    if ([string]::IsNullOrWhiteSpace($ITGAPIEndpoint)) {
        $ITGAPIEndpoint = $settings.ITGAPIEndpoint
    }
    if ([string]::IsNullOrWhiteSpace($MigrationLogs)) {
        $MigrationLogs = $settings.MigrationLogs
    }

    if ([string]::IsNullOrWhiteSpace($MigrationLogs)) {
        throw "MigrationLogs is required to write preloaded relation data."
    }

    if (-not (Test-Path -LiteralPath $MigrationLogs -PathType Container -ErrorAction SilentlyContinue)) {
        $null = New-Item -Path $MigrationLogs -ItemType Directory -Force
    }

    $startedAt = Get-Date
    Write-RelationPreloadStatus -RelationType $RelationType -State 'Running' -MigrationLogs $MigrationLogs -StartedAt $startedAt

    try {
        Initialize-ITGlueRelationPreloadApiContext -ITGKey $ITGKey -ITGAPIEndpoint $ITGAPIEndpoint

        $objects = @($ItgObjects | Where-Object { $_ })
        $objectIndex = 0
        $objectTotal = $objects.Count
        $freshObjects = foreach ($object in $objects) {
            $objectIndex++
            if ($objectIndex % 100 -eq 0 -or $objectIndex -eq $objectTotal) {
                Write-Host "  ...preloaded $objectIndex of $objectTotal $RelationType relation source object(s)"
            }

            switch ($RelationType) {
                'Assets' {
                    Get-ITGlueFlexibleAssets -id $object.ITGObject.id -include related_items
                }
                'Configs' {
                    Get-ITGlueConfigurations -id $object.ITGObject.id -include related_items
                }
                'Locations' {
                    Get-ITGlueLocations -id $object.ITGObject.id -include related_items
                }
                'Contacts' {
                    Get-ITGlueContacts -id $object.ITGObject.id -include related_items
                }
                'Articles' {
                    $ArticleLookup = Get-ArticleLookupInfo -Article $object
                    if ($ArticleLookup) {
                        Get-RelatedToDoc -DocID $ArticleLookup.DocID -OrganizationId $ArticleLookup.OrganizationId -ITGKey $ITGKey -ITGlue_Base_URI $ITGAPIEndpoint
                    }
                }
                'Passwords' {
                    Get-ITGluePasswords -id $object.ITGObject.id -include related_items
                }
                'Procedures' {
                    Write-Warning "Procedure relation preloading is not available through the ITGlue API key endpoints used by this migration."
                }
            }
        }

        $freshObjects = @($freshObjects | Where-Object { $_ })
        $relatedObjects = @($freshObjects | Where-Object { Test-ITGlueResponseHasRelationData -Response $_ })
        $preloadPath = Get-RelationPreloadPath -RelationType $RelationType -MigrationLogs $MigrationLogs
        $tempPath = "$preloadPath.tmp"

        ConvertTo-Json -InputObject $freshObjects -Depth 99 | Out-File -LiteralPath $tempPath
        Move-Item -LiteralPath $tempPath -Destination $preloadPath -Force

        $finishedAt = Get-Date
        Write-RelationPreloadStatus -RelationType $RelationType -State 'Completed' -MigrationLogs $MigrationLogs -StartedAt $startedAt -FinishedAt $finishedAt -FetchedCount $freshObjects.Count -RelatedCount $relatedObjects.Count

        [pscustomobject]@{
            RelationType = $RelationType
            Path         = $preloadPath
            FetchedCount = $freshObjects.Count
            RelatedCount = $relatedObjects.Count
        }
    }
    catch {
        $finishedAt = Get-Date
        Write-RelationPreloadStatus -RelationType $RelationType -State 'Failed' -MigrationLogs $MigrationLogs -StartedAt $startedAt -FinishedAt $finishedAt -ErrorMessage $_.Exception.Message
        throw
    }
}

function Start-PreloadedRelationDataJob {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("Assets","Configs","Locations","Contacts","Articles","Passwords","Procedures")]
        [string]$RelationType,

        [object[]]$ItgObjects = @(),
        [string]$ITGKey,
        [string]$ITGAPIEndpoint,
        [string]$MigrationLogs,
        [string]$ScriptRoot = $PSScriptRoot,
        [switch]$Force
    )

    if ([string]::IsNullOrWhiteSpace($ITGKey)) {
        $ITGKey = $settings.ITGKey
    }
    if ([string]::IsNullOrWhiteSpace($ITGAPIEndpoint)) {
        $ITGAPIEndpoint = $settings.ITGAPIEndpoint
    }
    if ([string]::IsNullOrWhiteSpace($MigrationLogs)) {
        $MigrationLogs = $settings.MigrationLogs
    }

    $preloadEnabledSetting = Get-Variable -Name PreloadITGlueRelations -ValueOnly -ErrorAction SilentlyContinue
    if ($false -eq $preloadEnabledSetting) {
        return
    }

    if ([string]::IsNullOrWhiteSpace($MigrationLogs)) {
        Write-Warning "Skipping $RelationType relation preload because MigrationLogs is blank."
        return
    }

    if (-not $script:ITGlueRelationPreloadJobs) {
        $script:ITGlueRelationPreloadJobs = @{}
    }
    if (-not $script:ITGlueRelationPreloadForceCleared) {
        $script:ITGlueRelationPreloadForceCleared = @{}
    }

    if ($Force -and -not $script:ITGlueRelationPreloadForceCleared.ContainsKey($RelationType)) {
        foreach ($stalePath in @(
            (Get-RelationPreloadPath -RelationType $RelationType -MigrationLogs $MigrationLogs),
            (Get-RelationPreloadStatusPath -RelationType $RelationType -MigrationLogs $MigrationLogs)
        )) {
            if (Test-Path -LiteralPath $stalePath -PathType Leaf -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $stalePath -Force
            }
        }

        $script:ITGlueRelationPreloadForceCleared[$RelationType] = $true
    }

    if ([string]::IsNullOrWhiteSpace($ITGKey)) {
        Write-Warning "Skipping $RelationType relation preload because ITGKey is blank."
        return
    }
    if ([string]::IsNullOrWhiteSpace($ITGAPIEndpoint)) {
        Write-Warning "Skipping $RelationType relation preload because ITGAPIEndpoint is blank."
        return
    }
    if (-not (Get-Command -Name Start-Job -ErrorAction SilentlyContinue)) {
        Write-Warning "Skipping $RelationType relation preload because this PowerShell host does not support background jobs."
        return
    }

    $objects = @($ItgObjects | Where-Object { $_ })
    if ($objects.Count -eq 0) {
        Write-Host "Skipping $RelationType relation preload because there are no migrated source objects." -ForegroundColor DarkGray
        return
    }

    $preloadPath = Get-RelationPreloadPath -RelationType $RelationType -MigrationLogs $MigrationLogs
    if (Test-Path -LiteralPath $preloadPath -PathType Leaf -ErrorAction SilentlyContinue) {
        Write-Host "$RelationType relation preload already exists at $preloadPath" -ForegroundColor DarkGray
        return
    }

    $existingJob = $script:ITGlueRelationPreloadJobs[$RelationType]
    if ($existingJob -and $existingJob.State -in @('NotStarted', 'Running')) {
        Write-Host "$RelationType relation preload job $($existingJob.Id) is already running." -ForegroundColor DarkGray
        return $existingJob
    }

    $helperScriptPath = Join-Path $ScriptRoot 'Get-PreloadedRelationData.ps1'
    if (-not (Test-Path -LiteralPath $helperScriptPath -PathType Leaf -ErrorAction SilentlyContinue)) {
        $helperScriptPath = Join-Path (Split-Path -Parent $ScriptRoot) 'Public\Get-PreloadedRelationData.ps1'
    }
    if (-not (Test-Path -LiteralPath $helperScriptPath -PathType Leaf -ErrorAction SilentlyContinue)) {
        Write-Warning "Skipping $RelationType relation preload because helper script was not found."
        return
    }

    $jobName = "ITGlueRelationPreload-$RelationType-$([guid]::NewGuid().ToString('N'))"
    $jobArguments = [object[]]@(
        $helperScriptPath
        $RelationType
        ,$objects
        $ITGKey
        $ITGAPIEndpoint
        $MigrationLogs
    )

    try {
        $job = Start-Job -Name $jobName -ArgumentList $jobArguments -ErrorAction Stop -ScriptBlock {
            param(
                [string]$HelperScriptPath,
                [string]$RelationType,
                [object[]]$Objects,
                [string]$ITGKey,
                [string]$ITGAPIEndpoint,
                [string]$MigrationLogs
            )

            try { Set-StrictMode -Off } catch {}
            Import-Module ITGlueAPIv2 -ErrorAction Stop
            if (Get-Command -Name Add-ITGlueBaseURI -ErrorAction SilentlyContinue) {
                Add-ITGlueBaseURI -base_uri $ITGAPIEndpoint
            }
            if (Get-Command -Name Add-ITGlueAPIKey -ErrorAction SilentlyContinue) {
                Add-ITGlueAPIKey $ITGKey
            }

            . $HelperScriptPath
            Get-PreloadedRelationData -RelationType $RelationType -ItgObjects $Objects -ITGKey $ITGKey -ITGAPIEndpoint $ITGAPIEndpoint -MigrationLogs $MigrationLogs
        }
    }
    catch {
        Write-Warning "Skipping $RelationType relation preload because the background job could not be started: $($_.Exception.Message)"
        return
    }

    $script:ITGlueRelationPreloadJobs[$RelationType] = $job
    Write-Host "Started $RelationType relation preload job $($job.Id) for $($objects.Count) ITGlue object(s)." -ForegroundColor Cyan
    $job
}

function Wait-PreloadedRelationDataJob {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("Assets","Configs","Locations","Contacts","Articles","Passwords","Procedures")]
        [string]$RelationType,

        [int]$StatusSeconds = 60,
        [switch]$KeepJob
    )

    foreach ($jobCommand in @('Get-Job', 'Wait-Job', 'Receive-Job')) {
        if (-not (Get-Command -Name $jobCommand -ErrorAction SilentlyContinue)) {
            Write-Warning "Cannot wait for $RelationType relation preload because this PowerShell host does not support $jobCommand."
            return
        }
    }

    $job = if ($script:ITGlueRelationPreloadJobs) { $script:ITGlueRelationPreloadJobs[$RelationType] } else { $null }
    if (-not $job) {
        $job = Get-Job -Name "ITGlueRelationPreload-$RelationType-*" -ErrorAction SilentlyContinue | Sort-Object Id -Descending | Select-Object -First 1
    }
    if (-not $job) {
        return
    }

    $lastReceivedCount = 0
    while ($job.State -in @('NotStarted', 'Running')) {
        $completedJob = Wait-Job -Job $job -Timeout $StatusSeconds
        $jobOutput = @(Receive-Job -Job $job -Keep -ErrorAction SilentlyContinue)
        if ($jobOutput.Count -gt $lastReceivedCount) {
            foreach ($item in @($jobOutput[$lastReceivedCount..($jobOutput.Count - 1)])) {
                $message = if ($item -is [string]) { $item } else { ($item | Out-String).Trim() }
                if (-not [string]::IsNullOrWhiteSpace($message)) {
                    Write-Host "[relation preload:$RelationType] $message" -ForegroundColor DarkCyan
                }
            }
            $lastReceivedCount = $jobOutput.Count
        }
        if ($completedJob) {
            break
        }

        Write-Host "$RelationType relation preload job $($job.Id) is still $($job.State). Checking again in $StatusSeconds seconds." -ForegroundColor Yellow
    }

    try {
        $jobOutput = @(Receive-Job -Job $job -ErrorAction Stop)
        if ($jobOutput.Count -gt $lastReceivedCount) {
            foreach ($item in @($jobOutput[$lastReceivedCount..($jobOutput.Count - 1)])) {
                $message = if ($item -is [string]) { $item } else { ($item | Out-String).Trim() }
                if (-not [string]::IsNullOrWhiteSpace($message)) {
                    Write-Host "[relation preload:$RelationType] $message" -ForegroundColor DarkCyan
                }
            }
        }
    }
    catch {
        Write-Warning "$RelationType relation preload job $($job.Id) failed: $($_.Exception.Message)"
    }

    if (-not $KeepJob) {
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        if ($script:ITGlueRelationPreloadJobs -and $script:ITGlueRelationPreloadJobs.ContainsKey($RelationType)) {
            $script:ITGlueRelationPreloadJobs.Remove($RelationType)
        }
    }
}

function Read-PreloadedRelationData {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("Assets","Configs","Locations","Contacts","Articles","Passwords","Procedures")]
        [string]$RelationType,

        [string]$MigrationLogs,
        [switch]$WaitForJob,
        [int]$StatusSeconds = 60
    )

    if ([string]::IsNullOrWhiteSpace($MigrationLogs)) {
        $MigrationLogs = $settings.MigrationLogs
    }

    $preloadPath = Get-RelationPreloadPath -RelationType $RelationType -MigrationLogs $MigrationLogs
    if (-not (Test-Path -LiteralPath $preloadPath -PathType Leaf -ErrorAction SilentlyContinue) -and $WaitForJob) {
        Wait-PreloadedRelationDataJob -RelationType $RelationType -StatusSeconds $StatusSeconds
    }

    if (-not (Test-Path -LiteralPath $preloadPath -PathType Leaf -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{
            Found = $false
            Data  = @()
            Path  = $preloadPath
        }
    }

    try {
        $raw = Get-Content -LiteralPath $preloadPath -Raw
        $data = if ([string]::IsNullOrWhiteSpace($raw)) { @() } else { @(ConvertFrom-Json -InputObject $raw -Depth 100) }
        return [pscustomobject]@{
            Found = $true
            Data  = $data
            Path  = $preloadPath
        }
    }
    catch {
        Write-Warning "Could not load $RelationType preloaded relation data from $preloadPath. Falling back to live ITGlue refresh. $($_.Exception.Message)"
        return [pscustomobject]@{
            Found = $false
            Data  = @()
            Path  = $preloadPath
        }
    }
}
