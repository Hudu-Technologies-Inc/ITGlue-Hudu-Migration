function Resolve-ITGlueDocumentsBaseURI {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$ITGBaseURI
    )

    $candidates = @(
        $ITGBaseURI
        $ITGAPIEndpoint
        $settings.ITGAPIEndpoint
        $environmentSettings.ITGAPIEndpoint
    )

    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace([string]$candidate)) {
            continue
        }

        $resolved = ([string]$candidate).Trim() -replace '[\\/]+$', ''
        if ($resolved -match '^https?://') {
            return $resolved
        }
    }

    throw "IT Glue API endpoint is blank. Set ITGAPIEndpoint in your environment or pass -ITGBaseURI, for example https://api.itglue.com."
}

function New-ITGlueDocumentsUri {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BaseUri,

        [Parameter(Mandatory = $true)]
        [string]$ResourceUri,

        [Parameter(Mandatory = $true)]
        [hashtable]$Query
    )

    $queryString = $Query.GetEnumerator() |
        Sort-Object Name |
        ForEach-Object {
            '{0}={1}' -f [uri]::EscapeDataString([string]$_.Key), [uri]::EscapeDataString([string]$_.Value)
        }

    if ($queryString) {
        return "$BaseUri$ResourceUri`?$($queryString -join '&')"
    }

    return "$BaseUri$ResourceUri"
}

function Get-ITGlueDocumentsResponseData {
    [CmdletBinding()]
    param(
        [AllowNull()]
        $Response
    )

    if ($null -eq $Response) {
        return @()
    }

    if ($null -ne $Response.data) {
        return @($Response.data)
    }

    return @($Response)
}

function Get-ITGlueDocumentsPaginationTotalPages {
    [CmdletBinding()]
    param(
        [AllowNull()]
        $Response
    )

    if ($null -eq $Response -or $null -eq $Response.meta -or $null -eq $Response.meta.pagination) {
        return $null
    }

    $totalPagesRaw = $Response.meta.pagination.'total-pages' ?? $Response.meta.pagination.total_pages
    if ($totalPagesRaw) {
        return [int]$totalPagesRaw
    }

    return $null
}

function Get-ITGlueDocumentOrganizationId {
    [CmdletBinding()]
    param(
        [AllowNull()]
        $Organization
    )

    $id = @(
        $Organization.id
        $Organization.ITGID
        $Organization.ITGCompanyObject.id
        $Organization.ITGObject.id
        $Organization.attributes.'organization-id'
        $Organization.attributes.organization_id
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -First 1

    if ($id) {
        return [Int64]$id
    }

    return $null
}

function Get-ITGlueDocumentOrganizationName {
    [CmdletBinding()]
    param(
        [AllowNull()]
        $Organization
    )

    @(
        $Organization.attributes.name
        $Organization.CompanyName
        $Organization.name
        $Organization.ITGCompanyObject.attributes.name
        $Organization.ITGObject.attributes.name
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -First 1
}

function Get-ITGlueDocumentOrganizations {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ITGKey,

        [Parameter(Mandatory = $true)]
        [string]$ITGBaseURI,

        [ValidateRange(1, 1000)]
        [int]$PageSize = 1000
    )

    $headers = @{
        'x-api-key'    = $ITGKey
        'Content-Type' = 'application/vnd.api+json'
        'Accept'       = 'application/vnd.api+json'
    }

    $organizations = @()
    $page = 1
    $totalPages = $null

    do {
        $uri = New-ITGlueDocumentsUri -BaseUri $ITGBaseURI -ResourceUri '/organizations' -Query @{
            'page[number]' = $page
            'page[size]'   = $PageSize
        }

        try {
            $response = Invoke-RestMethod -Method GET -Uri $uri -Headers $headers -ErrorAction Stop
        } catch {
            throw "Failed to retrieve IT Glue organizations on page $page`: $($_.Exception.Message)"
        }

        $data = @(Get-ITGlueDocumentsResponseData -Response $response)
        if ($data.Count -gt 0) {
            $organizations += $data
        }

        if ($null -eq $totalPages) {
            $totalPages = Get-ITGlueDocumentsPaginationTotalPages -Response $response
        }

        $page++
    } while (
        ($totalPages -and $page -le $totalPages) -or
        (-not $totalPages -and $data.Count -eq $PageSize)
    )

    return $organizations
}

function ConvertTo-ITGlueDocumentMetadata {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Document,

        [AllowNull()]
        [Nullable[Int64]]$FallbackOrganizationId = $null,

        [AllowNull()]
        [string]$FallbackOrganizationName,

        [switch]$IncludeContent,

        [switch]$IncludeRawObject
    )

    $attributes = $Document.attributes
    $content = [string]$attributes.content
    $metadata = [ordered]@{
        id                         = $Document.id
        type                       = $Document.type
        ITGID                      = $Document.id
        name                       = $attributes.name
        organization_id            = $attributes.'organization-id' ?? $FallbackOrganizationId
        organization_name          = $attributes.'organization-name' ?? $FallbackOrganizationName
        resource_url               = $attributes.'resource-url'
        restricted                 = $attributes.restricted
        my_glue                    = $attributes.'my-glue'
        public                     = $attributes.public
        document_folder_id         = $attributes.'document-folder-id'
        is_uploaded                = $attributes.'is-uploaded'
        user_id                    = $attributes.'user-id'
        published_by               = $attributes.'published-by'
        published_at               = $attributes.'published-at'
        created_at                 = $attributes.'created-at'
        updated_at                 = $attributes.'updated-at'
        archived                   = $attributes.archived
        support_office_online      = $attributes.'support-office-online'
        office_online_resource_url = $attributes.'office-online-resource-url'
        content_length             = if ($null -ne $attributes.content) { $content.Length } else { $null }
    }

    if ($IncludeContent) {
        $metadata.content = $attributes.content
    }

    if ($IncludeRawObject) {
        $metadata.ITGObject = $Document
    }

    [pscustomobject]$metadata
}

function Get-ITGlueDocuments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ITGKey,

        [AllowNull()]
        [Alias('ITGlue_Base_URI', 'ITGAPIEndpoint')]
        [string]$ITGBaseURI,

        [AllowNull()]
        [Alias('organization_id')]
        [Nullable[Int64]]$OrganizationId = $null,

        [AllowNull()]
        [Alias('organization_ids')]
        [Int64[]]$OrganizationIds = @(),

        [AllowNull()]
        [object[]]$Organizations = @(),

        [AllowNull()]
        [string]$DocumentFolderId = 'null',

        [switch]$RootOnly,

        [ValidateRange(1, 1000)]
        [int]$PageSize = 1000,

        [switch]$Raw,

        [switch]$IncludeContent,

        [switch]$IncludeRawObject
    )

    $ITGBaseURI = Resolve-ITGlueDocumentsBaseURI -ITGBaseURI $ITGBaseURI
    $headers = @{
        'x-api-key'    = $ITGKey
        'Content-Type' = 'application/vnd.api+json'
        'Accept'       = 'application/vnd.api+json'
    }

    $organizationRecords = [System.Collections.ArrayList]@()

    foreach ($id in @($OrganizationIds)) {
        if ($id -gt 0) {
            [void]$organizationRecords.Add([pscustomobject]@{
                id   = [Int64]$id
                name = $null
            })
        }
    }

    if ($null -ne $OrganizationId -and $OrganizationId -gt 0) {
        [void]$organizationRecords.Add([pscustomobject]@{
            id   = [Int64]$OrganizationId
            name = $null
        })
    }

    foreach ($organization in @($Organizations | Where-Object { $_ })) {
        $id = Get-ITGlueDocumentOrganizationId -Organization $organization
        if ($null -ne $id -and $id -gt 0) {
            [void]$organizationRecords.Add([pscustomobject]@{
                id   = $id
                name = Get-ITGlueDocumentOrganizationName -Organization $organization
            })
        }
    }

    if ($organizationRecords.Count -eq 0) {
        Write-Host "No organization ids were provided; retrieving IT Glue organizations first." -ForegroundColor Cyan
        foreach ($organization in @(Get-ITGlueDocumentOrganizations -ITGKey $ITGKey -ITGBaseURI $ITGBaseURI -PageSize $PageSize)) {
            $id = Get-ITGlueDocumentOrganizationId -Organization $organization
            if ($null -ne $id -and $id -gt 0) {
                [void]$organizationRecords.Add([pscustomobject]@{
                    id   = $id
                    name = Get-ITGlueDocumentOrganizationName -Organization $organization
                })
            }
        }
    }

    $organizationRecords = @(
        $organizationRecords |
            Where-Object { $_.id -gt 0 } |
            Sort-Object id -Unique
    )

    if ($organizationRecords.Count -eq 0) {
        Write-Warning "No IT Glue organizations were available for document retrieval."
        return @()
    }

    $documents = @()
    $organizationIndex = 0
    foreach ($organization in $organizationRecords) {
        $organizationIndex++
        $organizationLabel = if ($organization.name) { "$($organization.name) ($($organization.id))" } else { [string]$organization.id }
        Write-Host "Retrieving IT Glue documents for organization $organizationLabel [$organizationIndex/$($organizationRecords.Count)]." -ForegroundColor Cyan

        $page = 1
        $totalPages = $null

        do {
            $query = @{
                'page[number]' = $page
                'page[size]'   = $PageSize
            }

            if (-not $RootOnly -and -not [string]::IsNullOrWhiteSpace($DocumentFolderId)) {
                $query['filter[document_folder_id]'] = $DocumentFolderId
            }

            $resourceUri = "/organizations/$($organization.id)/relationships/documents"
            $uri = New-ITGlueDocumentsUri -BaseUri $ITGBaseURI -ResourceUri $resourceUri -Query $query

            try {
                $response = Invoke-RestMethod -Method GET -Uri $uri -Headers $headers -ErrorAction Stop
            } catch {
                throw "Failed to retrieve IT Glue documents for organization $($organization.id) on page $page`: $($_.Exception.Message)"
            }

            $data = @(Get-ITGlueDocumentsResponseData -Response $response)
            foreach ($document in $data) {
                if ($Raw) {
                    $documents += $document
                } else {
                    $documents += ConvertTo-ITGlueDocumentMetadata `
                        -Document $document `
                        -FallbackOrganizationId $organization.id `
                        -FallbackOrganizationName $organization.name `
                        -IncludeContent:$IncludeContent `
                        -IncludeRawObject:$IncludeRawObject
                }
            }

            if ($null -eq $totalPages) {
                $totalPages = Get-ITGlueDocumentsPaginationTotalPages -Response $response
            }

            $page++
        } while (
            ($totalPages -and $page -le $totalPages) -or
            (-not $totalPages -and $data.Count -eq $PageSize)
        )
    }

    return $documents
}

Set-Alias -Name Get-ITGDocuments -Value Get-ITGlueDocuments -ErrorAction SilentlyContinue
