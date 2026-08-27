
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
function Get-ITGlueRelationMetadataCachePath {
    $LogPath = $MigrationLogs ?? $settings.MigrationLogs
    if ([string]::IsNullOrWhiteSpace([string]$LogPath)) {
        return $null
    }

    return (Join-Path $LogPath 'itg-relation-metadata.json')
}
function New-ITGlueRelationMetadataCache {
    param(
        [string]$BaseUri
    )

    [pscustomobject]@{
        SchemaVersion = 1
        GeneratedAt   = (Get-Date).ToString('o')
        BaseUri       = $BaseUri
        Responses     = [pscustomobject]@{
            Assets         = @()
            Configurations = @()
            Passwords      = @()
            Contacts       = @()
            Documents      = @()
        }
    }
}
function Read-ITGlueRelationMetadataCache {
    param(
        [string]$Path,
        [string]$BaseUri
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf -ErrorAction SilentlyContinue)) {
        return $null
    }

    try {
        $Cache = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -Depth 100
        if ($Cache.SchemaVersion -ne 1) {
            Write-Warning "Ignoring relation metadata cache because schema version '$($Cache.SchemaVersion)' is not supported."
            return $null
        }

        if ($Cache.BaseUri -and $BaseUri -and $Cache.BaseUri.TrimEnd('/') -ne $BaseUri.TrimEnd('/')) {
            Write-Warning "Ignoring relation metadata cache because it was generated for $($Cache.BaseUri), not $BaseUri."
            return $null
        }

        return $Cache
    }
    catch {
        Write-Warning "Could not load relation metadata cache at $Path`: $($_.Exception.Message)"
        return $null
    }
}
function Save-ITGlueRelationMetadataCache {
    param(
        $Cache,
        [string]$Path
    )

    if (-not $Cache -or [string]::IsNullOrWhiteSpace($Path)) {
        return
    }

    $Directory = Split-Path -Path $Path -Parent
    if (-not [string]::IsNullOrWhiteSpace($Directory) -and -not (Test-Path -LiteralPath $Directory -PathType Container -ErrorAction SilentlyContinue)) {
        New-Item -Path $Directory -ItemType Directory -Force | Out-Null
    }

    $Cache.GeneratedAt = (Get-Date).ToString('o')
    $Cache | ConvertTo-Json -Depth 100 | Out-File -LiteralPath $Path
}
function New-ITGlueRelationMetadataRequest {
    param(
        [string]$Kind,
        $ItgId,
        $OrganizationId
    )

    if ($null -eq $ItgId -or [string]::IsNullOrWhiteSpace([string]$ItgId)) {
        return
    }

    [pscustomobject]@{
        Kind           = $Kind
        ItgId          = [string]$ItgId
        OrganizationId = if ($OrganizationId) { [string]$OrganizationId } else { $null }
        Key            = if ($OrganizationId) { "$Kind|$ItgId|$OrganizationId" } else { "$Kind|$ItgId" }
    }
}
function Get-ITGlueRelationMetadataRequests {
    $Requests = [System.Collections.ArrayList]@()
    $Seen = @{}

    $addRequest = {
        param($Request)
        if (-not $Request -or $Seen.ContainsKey($Request.Key)) {
            return
        }

        $Seen[$Request.Key] = $true
        [void]$Requests.Add($Request)
    }

    foreach ($Asset in @($MatchedAssets)) {
        & $addRequest (New-ITGlueRelationMetadataRequest -Kind 'Assets' -ItgId ($Asset.ITGObject.id ?? $Asset.ITGID))
    }

    foreach ($Configuration in @($MatchedConfigurations)) {
        & $addRequest (New-ITGlueRelationMetadataRequest -Kind 'Configurations' -ItgId ($Configuration.ITGObject.id ?? $Configuration.ITGID))
    }

    foreach ($Password in @($MatchedPasswords)) {
        & $addRequest (New-ITGlueRelationMetadataRequest -Kind 'Passwords' -ItgId ($Password.ITGObject.id ?? $Password.ITGID))
    }

    foreach ($Contact in @($MatchedContacts)) {
        & $addRequest (New-ITGlueRelationMetadataRequest -Kind 'Contacts' -ItgId ($Contact.ITGObject.id ?? $Contact.ITGID))
    }

    foreach ($Article in @($MatchedArticles)) {
        $ArticleLookup = Get-ArticleLookupInfo -Article $Article
        if ($ArticleLookup) {
            & $addRequest (New-ITGlueRelationMetadataRequest -Kind 'Documents' -ItgId $ArticleLookup.DocID -OrganizationId $ArticleLookup.OrganizationId)
        }
    }

    return @($Requests)
}
function Get-ITGlueRelationMetadataRecordKey {
    param(
        $Record
    )

    if (-not $Record) {
        return $null
    }

    if ($Record.OrganizationId) {
        return "$($Record.Kind)|$($Record.ItgId)|$($Record.OrganizationId)"
    }

    return "$($Record.Kind)|$($Record.ItgId)"
}
function Get-ITGlueRelationMetadataCachedKeys {
    param(
        $Cache
    )

    $CachedKeys = @{}
    if (-not $Cache -or -not $Cache.Responses) {
        return $CachedKeys
    }

    foreach ($Kind in @('Assets', 'Configurations', 'Passwords', 'Contacts', 'Documents')) {
        foreach ($Record in @($Cache.Responses.$Kind)) {
            if (-not $Record -or -not $Record.Response) {
                continue
            }

            $Key = Get-ITGlueRelationMetadataRecordKey -Record $Record
            if ($Key) {
                $CachedKeys[$Key] = $true
            }
        }
    }

    return $CachedKeys
}
function Get-MissingITGlueRelationMetadataRequests {
    param(
        [array]$Requests,
        $Cache
    )

    $CachedKeys = Get-ITGlueRelationMetadataCachedKeys -Cache $Cache
    return @($Requests | Where-Object { -not $CachedKeys.ContainsKey($_.Key) })
}
function Test-ITGlueRelationMetadataCacheComplete {
    param(
        [array]$Requests,
        $Cache,
        [string]$Kind
    )

    $KindRequests = @($Requests | Where-Object { $_.Kind -eq $Kind })
    if ($KindRequests.Count -eq 0) {
        return $false
    }

    return (@(Get-MissingITGlueRelationMetadataRequests -Requests $KindRequests -Cache $Cache).Count -eq 0)
}
function Invoke-ITGlueRelationMetadataRequest {
    param(
        $Request,
        [string]$ITGKey,
        [string]$BaseUri
    )

    $headers = @{
        'x-api-key'    = $ITGKey
        'Content-Type' = 'application/vnd.api+json'
    }

    $base = $BaseUri.TrimEnd('/')
    $lastError = $null
    $candidateUris = switch ($Request.Kind) {
        'Assets' {
            "$base/flexible_assets/$($Request.ItgId)?include=related_items"
        }
        'Configurations' {
            "$base/configurations/$($Request.ItgId)?include=related_items"
        }
        'Passwords' {
            "$base/passwords/$($Request.ItgId)?include=related_items"
        }
        'Contacts' {
            "$base/contacts/$($Request.ItgId)?include=related_items"
        }
        'Documents' {
            @(
                "$base/organizations/$($Request.OrganizationId)/relationships/documents/$($Request.ItgId)?include=related_items",
                "$base/organizations/$($Request.OrganizationId)/documents/$($Request.ItgId)?include=related_items",
                "$base/documents/$($Request.ItgId)?include=related_items",
                "$base/organizations/$($Request.OrganizationId)/relationships/documents/$($Request.ItgId)"
            ) | Select-Object -Unique
        }
        default {
            @()
        }
    }

    foreach ($uri in @($candidateUris)) {
        try {
            $response = Invoke-RestMethod -Method GET -Uri $uri -Headers $headers
            return [pscustomobject]@{
                Kind           = $Request.Kind
                ItgId          = [string]$Request.ItgId
                OrganizationId = $Request.OrganizationId
                Response       = $response
                Error          = $null
            }
        }
        catch {
            $lastError = $_
        }
    }

    [pscustomobject]@{
        Kind           = $Request.Kind
        ItgId          = [string]$Request.ItgId
        OrganizationId = $Request.OrganizationId
        Response       = $null
        Error          = if ($lastError) { [string]$lastError.Exception.Message } else { 'No candidate URI was available.' }
    }
}
function Invoke-ITGlueRelationMetadataPrefetch {
    param(
        [array]$Requests,
        [string]$ITGKey,
        [string]$BaseUri
    )

    foreach ($Request in @($Requests)) {
        Invoke-ITGlueRelationMetadataRequest -Request $Request -ITGKey $ITGKey -BaseUri $BaseUri
    }
}
function Start-ITGlueRelationMetadataPrefetchJob {
    param(
        [array]$Requests,
        [string]$ITGKey,
        [string]$BaseUri,
        [int]$ThrottleLimit = 4
    )

    if (-not $Requests -or @($Requests).Count -eq 0) {
        return @()
    }

    $ThrottleLimit = [math]::Max(1, [math]::Min($ThrottleLimit, @($Requests).Count))
    $ChunkSize = [int][math]::Ceiling(@($Requests).Count / [double]$ThrottleLimit)
    $Jobs = [System.Collections.ArrayList]@()

    for ($i = 0; $i -lt @($Requests).Count; $i += $ChunkSize) {
        $end = [math]::Min($i + $ChunkSize - 1, @($Requests).Count - 1)
        $chunk = @($Requests[$i..$end])
        $jobName = "ITGlueRelationMetadataPrefetch-$([guid]::NewGuid().ToString('N'))"
        $job = Start-Job -Name $jobName -ArgumentList $chunk, $ITGKey, $BaseUri -ScriptBlock {
            param(
                [array]$Requests,
                [string]$ITGKey,
                [string]$BaseUri
            )

            function Invoke-ITGlueRelationMetadataRequestInJob {
                param(
                    $Request,
                    [string]$ITGKey,
                    [string]$BaseUri
                )

                $headers = @{
                    'x-api-key'    = $ITGKey
                    'Content-Type' = 'application/vnd.api+json'
                }

                $base = $BaseUri.TrimEnd('/')
                $lastError = $null
                $candidateUris = switch ($Request.Kind) {
                    'Assets' {
                        "$base/flexible_assets/$($Request.ItgId)?include=related_items"
                    }
                    'Configurations' {
                        "$base/configurations/$($Request.ItgId)?include=related_items"
                    }
                    'Passwords' {
                        "$base/passwords/$($Request.ItgId)?include=related_items"
                    }
                    'Contacts' {
                        "$base/contacts/$($Request.ItgId)?include=related_items"
                    }
                    'Documents' {
                        @(
                            "$base/organizations/$($Request.OrganizationId)/relationships/documents/$($Request.ItgId)?include=related_items",
                            "$base/organizations/$($Request.OrganizationId)/documents/$($Request.ItgId)?include=related_items",
                            "$base/documents/$($Request.ItgId)?include=related_items",
                            "$base/organizations/$($Request.OrganizationId)/relationships/documents/$($Request.ItgId)"
                        ) | Select-Object -Unique
                    }
                    default {
                        @()
                    }
                }

                foreach ($uri in @($candidateUris)) {
                    try {
                        $response = Invoke-RestMethod -Method GET -Uri $uri -Headers $headers
                        return [pscustomobject]@{
                            Kind           = $Request.Kind
                            ItgId          = [string]$Request.ItgId
                            OrganizationId = $Request.OrganizationId
                            Response       = $response
                            Error          = $null
                        }
                    }
                    catch {
                        $lastError = $_
                    }
                }

                [pscustomobject]@{
                    Kind           = $Request.Kind
                    ItgId          = [string]$Request.ItgId
                    OrganizationId = $Request.OrganizationId
                    Response       = $null
                    Error          = if ($lastError) { [string]$lastError.Exception.Message } else { 'No candidate URI was available.' }
                }
            }

            foreach ($Request in @($Requests)) {
                Invoke-ITGlueRelationMetadataRequestInJob -Request $Request -ITGKey $ITGKey -BaseUri $BaseUri
            }
        }
        [void]$Jobs.Add($job)
    }

    return @($Jobs)
}
function Wait-ITGlueRelationMetadataPrefetchJob {
    param(
        [array]$Jobs,
        [int]$StatusSeconds = 30,
        [switch]$KeepJob
    )

    $Jobs = @($Jobs | Where-Object { $_ })
    if ($Jobs.Count -eq 0) {
        return @()
    }

    Write-Host "Waiting for $($Jobs.Count) background ITGlue relation metadata job(s)." -ForegroundColor Cyan
    $waitStarted = Get-Date
    while (@($Jobs | Where-Object { $_.State -in @('NotStarted', 'Running') }).Count -gt 0) {
        $null = Wait-Job -Job $Jobs -Timeout $StatusSeconds
        $elapsed = (Get-Date) - $waitStarted
        $remaining = @($Jobs | Where-Object { $_.State -in @('NotStarted', 'Running') }).Count
        if ($remaining -gt 0) {
            Write-Host "  ...$remaining relation metadata job(s) still running after $($elapsed.ToString('hh\:mm\:ss'))" -ForegroundColor Yellow
        }
    }

    $records = foreach ($Job in $Jobs) {
        try {
            Receive-Job -Job $Job -ErrorAction Stop
        }
        catch {
            Write-Warning "Relation metadata job $($Job.Id) failed: $($_.Exception.Message)"
        }
        finally {
            if (-not $KeepJob) {
                Remove-Job -Job $Job -Force -ErrorAction SilentlyContinue
            }
        }
    }

    return @($records)
}
function Merge-ITGlueRelationMetadataCache {
    param(
        $Cache,
        [array]$Records,
        [string]$BaseUri
    )

    if (-not $Cache) {
        $Cache = New-ITGlueRelationMetadataCache -BaseUri $BaseUri
    }

    if (-not $Cache.Responses) {
        $Cache | Add-Member -MemberType NoteProperty -Name Responses -Value ([pscustomobject]@{}) -Force
    }

    foreach ($Kind in @('Assets', 'Configurations', 'Passwords', 'Contacts', 'Documents')) {
        if (-not $Cache.Responses.PSObject.Properties[$Kind]) {
            $Cache.Responses | Add-Member -MemberType NoteProperty -Name $Kind -Value @() -Force
        }
    }

    foreach ($Record in @($Records)) {
        if (-not $Record -or -not $Record.Kind) {
            continue
        }

        if (-not $Cache.Responses.PSObject.Properties[$Record.Kind]) {
            continue
        }

        $Cache.Responses.$($Record.Kind) = @($Cache.Responses.$($Record.Kind)) + @($Record)
    }

    return $Cache
}
function Get-ITGlueRelationMetadataResponses {
    param(
        $Cache,
        [string]$Kind
    )

    if (-not $Cache -or -not $Cache.Responses -or -not $Cache.Responses.PSObject.Properties[$Kind]) {
        return @()
    }

    $ResponseMap = [ordered]@{}
    foreach ($Record in @($Cache.Responses.$Kind)) {
        if (-not $Record -or -not $Record.Response) {
            continue
        }

        $Key = Get-ITGlueRelationMetadataRecordKey -Record $Record
        if ($Key) {
            $ResponseMap[$Key] = $Record.Response
        }
    }

    return @($ResponseMap.Values)
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

if (-not $FreshITGAssets -or -not $FreshConfigurations -or -not $FreshPasswords -or -not $FreshContacts -or -not $FreshDocuments) {
    $RelationMetadataBaseUri = ($ITGAPIEndpoint ?? $settings.ITGAPIEndpoint ?? 'https://api.itglue.com')
    $RelationMetadataCachePath = Get-ITGlueRelationMetadataCachePath
    $RelationMetadataCache = Read-ITGlueRelationMetadataCache -Path $RelationMetadataCachePath -BaseUri $RelationMetadataBaseUri
    $RelationMetadataRequests = @(Get-ITGlueRelationMetadataRequests)
    $MissingRelationMetadataRequests = @(Get-MissingITGlueRelationMetadataRequests -Requests $RelationMetadataRequests -Cache $RelationMetadataCache)

    if ($RelationMetadataCache) {
        $CachedRelationMetadataCount = @('Assets', 'Configurations', 'Passwords', 'Contacts', 'Documents') |
            ForEach-Object { @(Get-ITGlueRelationMetadataResponses -Cache $RelationMetadataCache -Kind $_).Count } |
            Measure-Object -Sum |
            Select-Object -ExpandProperty Sum
        Write-Host "Loaded $CachedRelationMetadataCount cached ITGlue relation metadata response(s) from $RelationMetadataCachePath." -ForegroundColor Cyan
    }

    if ($MissingRelationMetadataRequests.Count -gt 0) {
        [string]$relationMetadataLanguage = $ExecutionContext.SessionState.LanguageMode
        $ITGlueRelationMetadataRunInBackground = $ITGlueRelationMetadataRunInBackground ?? $true
        $CanRunITGlueRelationMetadataJobs = ("FullLanguage" -ieq $relationMetadataLanguage)

        if (-not $CanRunITGlueRelationMetadataJobs) {
            Write-Host "Background ITGlue relation metadata prefetch is not allowed in $relationMetadataLanguage. Falling back to inline refreshes where cache is incomplete." -ForegroundColor Yellow
        }
        elseif (-not $ITGlueRelationMetadataRunInBackground) {
            Write-Host "Background ITGlue relation metadata prefetch is disabled. Falling back to inline refreshes where cache is incomplete." -ForegroundColor Yellow
        }
        elseif (-not $ITGKey) {
            Write-Host "ITGlue relation metadata cache is incomplete, but ITGKey is not available for background prefetch. Falling back to inline refreshes." -ForegroundColor Yellow
        }
        else {
            if (-not $ITGlueRelationMetadataPrefetchJob) {
                $ITGlueRelationMetadataPrefetchJob = Start-ITGlueRelationMetadataPrefetchJob `
                    -Requests $MissingRelationMetadataRequests `
                    -ITGKey $ITGKey `
                    -BaseUri $RelationMetadataBaseUri `
                    -ThrottleLimit $MigrationParallelismLimit
                Write-Host "Started $(@($ITGlueRelationMetadataPrefetchJob).Count) ITGlue relation metadata background job(s) for $($MissingRelationMetadataRequests.Count) uncached source object(s)." -ForegroundColor Green
            }
            else {
                Write-Host "Using existing ITGlue relation metadata background job variable." -ForegroundColor Cyan
            }

            $RelationMetadataPrefetchRecords = @(Wait-ITGlueRelationMetadataPrefetchJob -Jobs @($ITGlueRelationMetadataPrefetchJob))
            $ITGlueRelationMetadataPrefetchJob = $null
            $RelationMetadataFailures = @($RelationMetadataPrefetchRecords | Where-Object { $_.Error })
            if ($RelationMetadataFailures.Count -gt 0) {
                Write-Warning "ITGlue relation metadata prefetch had $($RelationMetadataFailures.Count) failed lookup(s). Incomplete categories will use the original inline refresh path."
            }

            $RelationMetadataCache = Merge-ITGlueRelationMetadataCache -Cache $RelationMetadataCache -Records $RelationMetadataPrefetchRecords -BaseUri $RelationMetadataBaseUri
            Save-ITGlueRelationMetadataCache -Cache $RelationMetadataCache -Path $RelationMetadataCachePath
            Write-Host "Saved ITGlue relation metadata cache to $RelationMetadataCachePath." -ForegroundColor Green
        }
    }
}

if (-not $FreshITGAssets -and (Test-ITGlueRelationMetadataCacheComplete -Requests $RelationMetadataRequests -Cache $RelationMetadataCache -Kind 'Assets')) {
    $FreshITGAssets = @(Get-ITGlueRelationMetadataResponses -Cache $RelationMetadataCache -Kind 'Assets')
    Write-Host "loaded $($FreshITGAssets.Count) assets from ITGlue relation metadata cache"
}
if (-not $FreshITGAssets) {
    write-host "refreshing $($MatchedAssets.count) assets"
    $__asIdx = 0; $__asTotal = $MatchedAssets.count
    $FreshITGAssets= $($MatchedAssets |ForEach-Object {
        $__asIdx++
        if ($__asIdx % 100 -eq 0 -or $__asIdx -eq $__asTotal) { Write-Host "  ...refreshed $__asIdx of $__asTotal assets" }
        Get-ITGlueFlexibleAssets -id $_.ITGObject.id -include related_items})
}
$RelatedAssets = $RelatedAssets ?? $($FreshITGAssets | Where-Object { Test-ITGlueResponseHasRelationData -Response $_ })

if (-not $FreshConfigurations -and (Test-ITGlueRelationMetadataCacheComplete -Requests $RelationMetadataRequests -Cache $RelationMetadataCache -Kind 'Configurations')) {
    $FreshConfigurations = @(Get-ITGlueRelationMetadataResponses -Cache $RelationMetadataCache -Kind 'Configurations')
    Write-Host "loaded $($FreshConfigurations.Count) configs from ITGlue relation metadata cache"
}
if (-not $FreshConfigurations) {
    write-host "refreshing $($MatchedConfigurations.count) configs"
    $__cfgIdx = 0; $__cfgTotal = $MatchedConfigurations.count
    $FreshConfigurations = $($MatchedConfigurations | ForEach-Object {
        $__cfgIdx++
        if ($__cfgIdx % 100 -eq 0 -or $__cfgIdx -eq $__cfgTotal) { Write-Host "  ...refreshed $__cfgIdx of $__cfgTotal configs" }
        Get-ITGlueConfigurations -id $_.itgobject.id -include related_items})
}
$RelatedConfigurations = $RelatedConfigurations ?? $($FreshConfigurations | Where-Object { Test-ITGlueResponseHasRelationData -Response $_ })

if (-not $FreshPasswords -and (Test-ITGlueRelationMetadataCacheComplete -Requests $RelationMetadataRequests -Cache $RelationMetadataCache -Kind 'Passwords')) {
    $FreshPasswords = @(Get-ITGlueRelationMetadataResponses -Cache $RelationMetadataCache -Kind 'Passwords')
    Write-Host "loaded $($FreshPasswords.Count) passwords from ITGlue relation metadata cache"
}
if (-not $FreshPasswords) {
    write-host "refreshing $($MatchedPasswords.count) passwords"
    $__pwIdx = 0; $__pwTotal = $MatchedPasswords.count
    $FreshPasswords = $($MatchedPasswords | ForEach-Object {
        $__pwIdx++
        if ($__pwIdx % 100 -eq 0 -or $__pwIdx -eq $__pwTotal) { Write-Host "  ...refreshed $__pwIdx of $__pwTotal passwords" }
        Get-ITGluePasswords -id $_.itgobject.id -include related_items})
}
$RelatedPasswords = $RelatedPasswords ?? $($FreshPasswords | Where-Object { Test-ITGlueResponseHasRelationData -Response $_ })

if (-not $FreshContacts -and (Test-ITGlueRelationMetadataCacheComplete -Requests $RelationMetadataRequests -Cache $RelationMetadataCache -Kind 'Contacts')) {
    $FreshContacts = @(Get-ITGlueRelationMetadataResponses -Cache $RelationMetadataCache -Kind 'Contacts')
    Write-Host "loaded $($FreshContacts.Count) contacts from ITGlue relation metadata cache"
}
if (-not $FreshContacts) {
    write-host "refreshing $($MatchedContacts.count) contacts"
    $__ctIdx = 0; $__ctTotal = $MatchedContacts.count
    $FreshContacts = $($MatchedContacts | ForEach-Object {
        $__ctIdx++
        if ($__ctIdx % 100 -eq 0 -or $__ctIdx -eq $__ctTotal) { Write-Host "  ...refreshed $__ctIdx of $__ctTotal contacts" }
        Get-ITGlueContacts -id $_.ITGObject.id -include related_items})
}
$RelatedContacts = $RelatedContacts ?? $($FreshContacts | Where-Object { Test-ITGlueResponseHasRelationData -Response $_ })

if (-not $FreshDocuments -and (Test-ITGlueRelationMetadataCacheComplete -Requests $RelationMetadataRequests -Cache $RelationMetadataCache -Kind 'Documents')) {
    $FreshDocuments = @(Get-ITGlueRelationMetadataResponses -Cache $RelationMetadataCache -Kind 'Documents')
    Write-Host "loaded $($FreshDocuments.Count) articles from ITGlue relation metadata cache"
}
if (-not $FreshDocuments) {
    write-host "refreshing $($MatchedArticles.count) articles"
    $__arIdx = 0; $__arTotal = $MatchedArticles.count
    $FreshDocuments = ($MatchedArticles | ForEach-Object {
        $__arIdx++
        if ($__arIdx % 100 -eq 0 -or $__arIdx -eq $__arTotal) { Write-Host "  ...refreshed $__arIdx of $__arTotal articles" }
        $ArticleLookup = Get-ArticleLookupInfo -Article $_
        if ($ArticleLookup) {
            Get-RelatedToDoc -DocID $ArticleLookup.DocID -OrganizationId $ArticleLookup.OrganizationId -ITGKey $ITGKey -ITGlue_Base_URI ($ITGAPIEndpoint ?? $settings.ITGAPIEndpoint)
        }
    })
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
