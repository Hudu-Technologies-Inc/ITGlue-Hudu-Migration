function Resolve-ITGlueAttachmentBaseURI {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [Alias('ITGAPIEndpoint')]
        [string]$ITGBaseURI
    )

    $candidates = @($ITGBaseURI)

    if (Get-Command -Name Resolve-ITGlueExportBaseURI -ErrorAction SilentlyContinue) {
        try {
            return Resolve-ITGlueExportBaseURI -ITGBaseURI $ITGBaseURI
        } catch {
        }
    }

    if (Get-Command -Name Get-ITGlueBaseURI -ErrorAction SilentlyContinue) {
        try {
            $candidates += Get-ITGlueBaseURI
        } catch {
        }
    }

    $candidates += Get-Variable -Name ITGAPIEndpoint -ValueOnly -ErrorAction SilentlyContinue
    foreach ($settingsVariableName in @('settings', 'environmentSettings')) {
        $settingsValue = Get-Variable -Name $settingsVariableName -ValueOnly -ErrorAction SilentlyContinue
        if ($null -eq $settingsValue) {
            continue
        }

        if ($settingsValue -is [hashtable]) {
            $candidates += $settingsValue['ITGAPIEndpoint']
        } else {
            $apiEndpointProperty = $settingsValue.PSObject.Properties['ITGAPIEndpoint']
            if ($apiEndpointProperty) {
                $candidates += $apiEndpointProperty.Value
            }
        }
    }

    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace([string]$candidate)) {
            continue
        }

        $resolved = ([string]$candidate).Trim()
        if ($resolved -match '^\[(?<url>https?://[^\]]+)\]\(https?://[^\)]+\)$') {
            $resolved = $Matches.url
        }

        $resolved = $resolved -replace '[\\/]+$', ''
        if ($resolved -match '^https?://') {
            return $resolved
        }
    }

    throw "IT Glue API endpoint is blank. Set ITGAPIEndpoint in your environment or pass -ITGBaseURI, for example https://api.itglue.com."
}

function Get-ITGlueAttachmentHeaders {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$ITGKey
    )

    $resolvedKey = @(
        $ITGKey
        (Get-Variable -Name ITGKey -Scope Script -ValueOnly -ErrorAction SilentlyContinue)
        (Get-Variable -Name ITGKey -Scope Global -ValueOnly -ErrorAction SilentlyContinue)
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -First 1

    if ([string]::IsNullOrWhiteSpace([string]$resolvedKey)) {
        throw "IT Glue API key is blank. Pass -ITGKey or initialize the migration settings first."
    }

    @{
        'x-api-key'    = [string]$resolvedKey
        'Content-Type' = 'application/vnd.api+json'
        'Accept'       = 'application/vnd.api+json'
    }
}

function Get-ITGlueAttachmentName {
    [CmdletBinding()]
    param(
        [AllowNull()]
        $Attachment
    )

    @(
        $Attachment.attributes.'file-name'
        $Attachment.attributes.file_name
        $Attachment.attributes.filename
        $Attachment.attributes.name
        $Attachment.attributes.attachment.file_name
        $Attachment.attributes.attachment.'file-name'
        $Attachment.attributes.attachment.filename
        $Attachment.attributes.attachment.name
        $Attachment.attributes.'attachment-file-name'
        $Attachment.attributes.'attachment-file_name'
        $Attachment.attributes.'attachment-filename'
        $Attachment.attributes.'attachment_filename'
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -First 1
}

function Normalize-ITGlueAttachmentName {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return ''
    }

    $text = [IO.Path]::GetFileName($Name).Normalize([Text.NormalizationForm]::FormD)
    $chars = $text.ToCharArray() | Where-Object {
        [Globalization.CharUnicodeInfo]::GetUnicodeCategory($_) -ne [Globalization.UnicodeCategory]::NonSpacingMark
    }

    $text = (-join $chars).ToLowerInvariant()
    $text = $text -replace '&', ' and '
    $text = $text -replace '[^a-z0-9.]+', ' '
    $text = $text.Trim()
    $text = $text -replace '\s+', ' '

    return $text
}

function Get-ITGlueAttachmentId {
    [CmdletBinding()]
    param(
        [AllowNull()]
        $Attachment
    )

    @(
        $Attachment.id
        $Attachment.attributes.id
        $Attachment.attributes.attachment.id
        $Attachment.attributes.'attachment-id'
        $Attachment.attributes.attachment_id
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -First 1
}

function Get-ITGlueAttachmentsForResource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet(
            'checklists',
            'checklist_templates',
            'configurations',
            'contacts',
            'documents',
            'domains',
            'locations',
            'passwords',
            'ssl_certificates',
            'flexible_assets',
            'tickets'
        )]
        [string]$ResourceType,

        [Parameter(Mandatory = $true)]
        [ValidateRange(1, [Int64]::MaxValue)]
        [Int64]$ResourceId,

        [AllowNull()]
        [string]$ITGKey,

        [AllowNull()]
        [Alias('ITGAPIEndpoint')]
        [string]$ITGBaseURI,

        [ValidateRange(1, 1000)]
        [int]$PageSize = 1000
    )

    $baseUri = Resolve-ITGlueAttachmentBaseURI -ITGBaseURI $ITGBaseURI
    $headers = Get-ITGlueAttachmentHeaders -ITGKey $ITGKey
    $attachments = @()
    $pageNumber = 1

    do {
        $query = @(
            "page%5Bnumber%5D=$pageNumber"
            "page%5Bsize%5D=$PageSize"
        ) -join '&'
        $uri = "$($baseUri.TrimEnd('/'))/$ResourceType/$ResourceId/relationships/attachments?$query"

        try {
            $response = Invoke-RestMethod -Method GET -Uri $uri -Headers $headers -ErrorAction Stop
        } catch {
            throw "Unable to retrieve IT Glue attachments for $ResourceType/$ResourceId. $($_.Exception.Message)"
        }

        $pageData = @($response.data)
        $attachments += $pageData
        $pageNumber++
    } while ($pageData.Count -ge $PageSize)

    return $attachments
}

function Get-ITGlueExportAttachmentFolderCandidates {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet(
            'checklists',
            'checklist_templates',
            'configurations',
            'contacts',
            'documents',
            'domains',
            'locations',
            'passwords',
            'ssl_certificates',
            'flexible_assets',
            'tickets'
        )]
        [string]$ResourceType,

        [AllowNull()]
        [string]$AttachmentFolderName
    )

    if (-not [string]::IsNullOrWhiteSpace($AttachmentFolderName)) {
        return @($AttachmentFolderName)
    }

    switch ($ResourceType) {
        'domains' { @('websites', 'domains') }
        'flexible_assets' { @('assets', 'flexible_assets') }
        default { @($ResourceType) }
    }
}

function Get-ITGlueExportAttachmentFilesForResource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ExportPath,

        [Parameter(Mandatory = $true)]
        [ValidateSet(
            'checklists',
            'checklist_templates',
            'configurations',
            'contacts',
            'documents',
            'domains',
            'locations',
            'passwords',
            'ssl_certificates',
            'flexible_assets',
            'tickets'
        )]
        [string]$ResourceType,

        [Parameter(Mandatory = $true)]
        [ValidateRange(1, [Int64]::MaxValue)]
        [Int64]$ResourceId,

        [AllowNull()]
        [string]$AttachmentFolderName
    )

    $attachmentRoot = Join-Path -Path $ExportPath -ChildPath 'attachments'
    if (-not (Test-Path -LiteralPath $attachmentRoot -PathType Container -ErrorAction SilentlyContinue)) {
        return @()
    }

    foreach ($folderName in @(Get-ITGlueExportAttachmentFolderCandidates -ResourceType $ResourceType -AttachmentFolderName $AttachmentFolderName)) {
        $resourceFolder = Join-Path -Path (Join-Path -Path $attachmentRoot -ChildPath $folderName) -ChildPath ([string]$ResourceId)
        if (Test-Path -LiteralPath $resourceFolder -PathType Container -ErrorAction SilentlyContinue) {
            return @(Get-ChildItem -LiteralPath $resourceFolder -Recurse -File -Force -ErrorAction SilentlyContinue)
        }
    }

    return @()
}

function Find-ITGlueExportAttachmentFile {
    [CmdletBinding()]
    param(
        [AllowNull()]
        $Attachment,

        [AllowNull()]
        [object[]]$LocalFiles
    )

    if (-not $Attachment -or -not $LocalFiles -or $LocalFiles.Count -lt 1) {
        return $null
    }

    $attachmentId = [string](Get-ITGlueAttachmentId -Attachment $Attachment)
    $attachmentName = [string](Get-ITGlueAttachmentName -Attachment $Attachment)
    $normalizedName = Normalize-ITGlueAttachmentName -Name $attachmentName
    $normalizedStem = Normalize-ITGlueAttachmentName -Name ([IO.Path]::GetFileNameWithoutExtension($attachmentName))
    $escapedId = if (-not [string]::IsNullOrWhiteSpace($attachmentId)) { [regex]::Escape($attachmentId) } else { $null }

    @($LocalFiles |
        Where-Object {
            if (-not $_ -or $_.PSIsContainer -eq $true) {
                return $false
            }

            $fileName = Normalize-ITGlueAttachmentName -Name $_.Name
            $fileStem = Normalize-ITGlueAttachmentName -Name $_.BaseName
            $idMatch = $false

            if (-not [string]::IsNullOrWhiteSpace($escapedId)) {
                $idMatch = (
                    [string]$_.BaseName -eq $attachmentId -or
                    [string]$_.Name -match "^$escapedId(?:\D|$)" -or
                    [string]$_.FullName -match "[\\/]$escapedId(?:[\\/._ -]|$)"
                )
            }

            $nameMatch = (
                ($normalizedName -and $fileName -eq $normalizedName) -or
                ($normalizedStem -and $fileStem -eq $normalizedStem)
            )

            $idMatch -or $nameMatch
        } |
        Sort-Object @{
            Expression = {
                if (-not [string]::IsNullOrWhiteSpace($escapedId) -and [string]$_.BaseName -eq $attachmentId) { 0 }
                elseif (-not [string]::IsNullOrWhiteSpace($escapedId) -and [string]$_.Name -match "^$escapedId(?:\D|$)") { 1 }
                elseif ((Normalize-ITGlueAttachmentName -Name $_.Name) -eq $normalizedName) { 2 }
                else { 3 }
            }
        }, FullName) | Select-Object -First 1
}

function Get-ITGlueExportAttachmentInventory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ExportPath
    )

    $attachmentRoot = Join-Path -Path $ExportPath -ChildPath 'attachments'
    if (-not (Test-Path -LiteralPath $attachmentRoot -PathType Container -ErrorAction SilentlyContinue)) {
        return @()
    }

    $knownFolderMap = @{
        checklists          = 'checklists'
        checklist_templates = 'checklist_templates'
        configurations      = 'configurations'
        contacts            = 'contacts'
        documents           = 'documents'
        domains             = 'domains'
        websites            = 'domains'
        locations           = 'locations'
        passwords           = 'passwords'
        ssl_certificates    = 'ssl_certificates'
        tickets             = 'tickets'
        assets              = 'flexible_assets'
        flexible_assets     = 'flexible_assets'
    }

    foreach ($typeFolder in @(Get-ChildItem -LiteralPath $attachmentRoot -Directory -Force -ErrorAction SilentlyContinue)) {
        $resourceType = $knownFolderMap[$typeFolder.Name]
        if ([string]::IsNullOrWhiteSpace($resourceType)) {
            $resourceType = 'flexible_assets'
        }

        foreach ($resourceFolder in @(Get-ChildItem -LiteralPath $typeFolder.FullName -Directory -Force -ErrorAction SilentlyContinue)) {
            if ($resourceFolder.Name -notmatch '^\d+$') {
                continue
            }

            $files = @(Get-ChildItem -LiteralPath $resourceFolder.FullName -Recurse -File -Force -ErrorAction SilentlyContinue)
            if ($files.Count -lt 1) {
                continue
            }

            [pscustomobject]@{
                ResourceType         = $resourceType
                ResourceId           = [Int64]$resourceFolder.Name
                AttachmentFolderName = $typeFolder.Name
                FolderPath           = $resourceFolder.FullName
                LocalFileCount       = $files.Count
            }
        }
    }
}

function Test-ITGlueExportAttachments {
    [CmdletBinding(DefaultParameterSetName = 'Resource')]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ExportPath,

        [Parameter(Mandatory = $true, ParameterSetName = 'Resource')]
        [ValidateSet(
            'checklists',
            'checklist_templates',
            'configurations',
            'contacts',
            'documents',
            'domains',
            'locations',
            'passwords',
            'ssl_certificates',
            'flexible_assets',
            'tickets'
        )]
        [string]$ResourceType,

        [Parameter(Mandatory = $true, ParameterSetName = 'Resource')]
        [ValidateRange(1, [Int64]::MaxValue)]
        [Int64]$ResourceId,

        [Parameter(Mandatory = $true, ParameterSetName = 'Inventory')]
        [switch]$ScanLocalInventory,

        [AllowNull()]
        [string]$AttachmentFolderName,

        [AllowNull()]
        [string]$ITGKey,

        [AllowNull()]
        [Alias('ITGAPIEndpoint')]
        [string]$ITGBaseURI,

        [ValidateRange(1, 1000)]
        [int]$PageSize = 1000
    )

    if (-not (Test-Path -LiteralPath $ExportPath -PathType Container -ErrorAction SilentlyContinue)) {
        throw "IT Glue export path was not found: $ExportPath"
    }

    $checks = if ($PSCmdlet.ParameterSetName -eq 'Inventory') {
        @(Get-ITGlueExportAttachmentInventory -ExportPath $ExportPath)
    } else {
        @([pscustomobject]@{
            ResourceType         = $ResourceType
            ResourceId           = $ResourceId
            AttachmentFolderName = $AttachmentFolderName
        })
    }

    foreach ($check in $checks) {
        $localFiles = @(Get-ITGlueExportAttachmentFilesForResource `
            -ExportPath $ExportPath `
            -ResourceType $check.ResourceType `
            -ResourceId $check.ResourceId `
            -AttachmentFolderName $check.AttachmentFolderName)

        $apiAttachments = @(Get-ITGlueAttachmentsForResource `
            -ResourceType $check.ResourceType `
            -ResourceId $check.ResourceId `
            -ITGKey $ITGKey `
            -ITGBaseURI $ITGBaseURI `
            -PageSize $PageSize)

        $matched = foreach ($attachment in $apiAttachments) {
            $localFile = Find-ITGlueExportAttachmentFile -Attachment $attachment -LocalFiles $localFiles
            if ($localFile) {
                [pscustomobject]@{
                    AttachmentId   = Get-ITGlueAttachmentId -Attachment $attachment
                    AttachmentName = Get-ITGlueAttachmentName -Attachment $attachment
                    LocalPath      = $localFile.FullName
                }
            }
        }

        $matchedLocalPathSet = @{}
        foreach ($item in @($matched)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$item.LocalPath)) {
                $matchedLocalPathSet[[string]$item.LocalPath] = $true
            }
        }

        $missingFromExport = foreach ($attachment in $apiAttachments) {
            $localFile = Find-ITGlueExportAttachmentFile -Attachment $attachment -LocalFiles $localFiles
            if (-not $localFile) {
                [pscustomobject]@{
                    AttachmentId   = Get-ITGlueAttachmentId -Attachment $attachment
                    AttachmentName = Get-ITGlueAttachmentName -Attachment $attachment
                    RawAttachment  = $attachment
                }
            }
        }

        $localWithoutApiMatch = foreach ($localFile in $localFiles) {
            if (-not $matchedLocalPathSet.ContainsKey([string]$localFile.FullName)) {
                [pscustomobject]@{
                    Name      = $localFile.Name
                    LocalPath = $localFile.FullName
                    Length    = $localFile.Length
                }
            }
        }

        [pscustomobject]@{
            ResourceType                 = $check.ResourceType
            ResourceId                   = [Int64]$check.ResourceId
            AttachmentFolderName         = $check.AttachmentFolderName
            ExportComplete               = (@($missingFromExport).Count -eq 0)
            MatchesApi                   = (@($missingFromExport).Count -eq 0 -and @($localWithoutApiMatch).Count -eq 0)
            ApiAttachmentCount           = $apiAttachments.Count
            LocalFileCount               = $localFiles.Count
            MatchedCount                 = @($matched).Count
            MissingFromExportCount       = @($missingFromExport).Count
            LocalWithoutApiMatchCount    = @($localWithoutApiMatch).Count
            Matched                      = @($matched)
            MissingFromExport            = @($missingFromExport)
            LocalWithoutApiMatch         = @($localWithoutApiMatch)
        }
    }
}
