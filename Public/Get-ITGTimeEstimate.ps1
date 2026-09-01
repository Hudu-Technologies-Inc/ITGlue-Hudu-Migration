function Get-ITGlueMigrationETA {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $ExportPath,

        [Nullable[int]] $PasswordFolderCount = $null,
        [Nullable[int]] $RelationCount = $null,
        [Nullable[int]] $RelationSourceCount = $null,
        [string] $MigrationLogsPath,
        [Alias('ITGAPIEndpoint')]
        [string] $ITGBaseURI,

        [ValidateRange(1, 32)]
        [int] $CommitWorkerCount = 1,

        [ValidateRange(0.1, 1.0)]
        [double] $CommitWorkerEfficiency = 0.80,

        [double] $Buffer = 1.0,
        [switch] $Detailed
    )

    $coef = @{
        Company              = 0.36
        Location             = 0.69
        Website              = 0.33
        Configuration        = 0.85
        Contact              = 0.43
        FlexibleAsset        = 1.05
        FlexibleLayout       = 12.00
        ArticleStub          = 0.60
        ArticleContent       = 0.82
        DocumentFile         = 0.26
        DocumentMB           = 0.15
        Password             = 0.41
        PasswordFolder       = 1.00
        AttachmentFile       = 0.70
        AttachmentMB         = 0.24
        IPAM                 = 0.85
        LinkReplacementItem  = 0.026
        ArchiveItem          = 0.65
        LabelType            = 1.50
        Label                = 0.18
        RelationSourceObject = 0.50
        RelationCreate       = 0.82
    }

    # CSVs that represent built-in IT Glue object types, not flexible assets.
    $standardCsvs = @(
        'organizations.csv'
        'contacts.csv'
        'domains.csv'
        'locations.csv'
        'configurations.csv'
        'documents.csv'
        'passwords.csv'
        'ssl-certificates.csv'
    )

    # CSV exports present in IT Glue, but not imported by the normal migration flow.
    $unsupportedCsvs = @(
        'ssl-certificates.csv'
    )

    # Directories that aren't flexible-asset attachment fields.
    $reservedDirectories = @(
        'documents'
        'attachments'
        'vaulted'
    )

    function Get-FileStats {
        param([System.IO.FileInfo[]] $Files)

        $Files = @($Files)
        $measure = $Files | Measure-Object Length -Sum
        $bytes = 0
        if ($measure -and $null -ne $measure.Sum) {
            $bytes = [double]$measure.Sum
        }

        [pscustomobject]@{
            Count = $Files.Count
            MB    = $bytes / 1MB
        }
    }

    function Get-Sum {
        param([object] $Values)

        $total = 0.0
        $items = @($Values)
        if ($Values -is [System.Collections.IEnumerable] -and $Values -isnot [string]) {
            $items = $Values
        }

        foreach ($value in $items) {
            if ($null -eq $value) { continue }
            $total += [double]$value
        }

        return $total
    }

    function Get-CsvRowCount {
        param([object[]] $Rows)

        return @($Rows).Count
    }

    function Test-ITGArchivedValue {
        param($Value)

        if ($null -eq $Value) { return $false }

        $text = ([string]$Value).Trim()
        if ([string]::IsNullOrWhiteSpace($text)) { return $false }

        return $text.ToLowerInvariant() -notin @('no', 'false', '0')
    }

    function Test-TruthyExportValue {
        param($Value)

        if ($null -eq $Value) { return $false }

        $text = ([string]$Value).Trim()
        if ([string]::IsNullOrWhiteSpace($text)) { return $false }

        return $text.ToLowerInvariant() -in @('true', 'yes', 'y', '1')
    }

    function Get-TrimmedPropertyValue {
        param(
            [object] $Row,
            [string] $PropertyName
        )

        if ($null -eq $Row -or [string]::IsNullOrWhiteSpace($PropertyName)) { return $null }
        if ($Row.PSObject.Properties.Name -notcontains $PropertyName) { return $null }

        $value = ([string]$Row.$PropertyName).Trim()
        if ([string]::IsNullOrWhiteSpace($value)) { return $null }

        return $value
    }

    function Get-NonBlankPropertyCount {
        param(
            [object[]] $Rows,
            [string] $PropertyName
        )

        return @(
            @($Rows) | Where-Object {
                $null -ne (Get-TrimmedPropertyValue -Row $_ -PropertyName $PropertyName)
            }
        ).Count
    }

    function Get-UniqueNonBlankPropertyCount {
        param(
            [object[]] $Rows,
            [string] $PropertyName
        )

        return @(
            @($Rows) |
                ForEach-Object { Get-TrimmedPropertyValue -Row $_ -PropertyName $PropertyName } |
                Where-Object { $null -ne $_ } |
                Sort-Object -Unique
        ).Count
    }

    function Get-EndpointMultiplier {
        param([string] $BaseUri)

        if ([string]::IsNullOrWhiteSpace($BaseUri)) {
            return [pscustomobject]@{
                Region     = 'unspecified'
                Multiplier = 1.00
            }
        }

        $normalized = $BaseUri.Trim().ToLowerInvariant()
        if ($normalized -match 'api\.au\.itglue\.com') {
            return [pscustomobject]@{
                Region     = 'au'
                Multiplier = 1.25
            }
        }

        if ($normalized -match 'api\.eu\.itglue\.com') {
            return [pscustomobject]@{
                Region     = 'eu'
                Multiplier = 1.10
            }
        }

        return [pscustomobject]@{
            Region     = 'default'
            Multiplier = 1.00
        }
    }

    function Get-EffectiveCommitWorkerCount {
        param(
            [int] $WorkerCount,
            [double] $Efficiency
        )

        $workers = [math]::Max(1, [int]$WorkerCount)
        if ($workers -eq 1) { return 1.0 }

        return [math]::Max(1.0, 1.0 + (([double]$workers - 1.0) * [double]$Efficiency))
    }

    function Get-WorkerAdjustedSeconds {
        param(
            [double] $Seconds,
            [double] $CommitRatio = 1.0,
            [double] $EffectiveWorkers = 1.0
        )

        if ($Seconds -le 0) { return 0.0 }

        $boundedCommitRatio = [math]::Min(1.0, [math]::Max(0.0, $CommitRatio))
        $serialSeconds = $Seconds * (1.0 - $boundedCommitRatio)
        $commitSeconds = ($Seconds * $boundedCommitRatio) / [math]::Max(1.0, $EffectiveWorkers)

        return $serialSeconds + $commitSeconds
    }

    function Get-ArchivedRowCount {
        param([object[]] $Rows)

        return @(
            @($Rows) | Where-Object {
                $_.PSObject.Properties.Name -contains 'archived' -and
                    (Test-ITGArchivedValue -Value $_.archived)
            }
        ).Count
    }

    function Get-JsonArrayCount {
        param([string] $Path)

        if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }

        $file = Get-Item -LiteralPath $Path
        if ($file.Length -eq 0) { return 0 }

        try {
            $items = @(Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json)
            return $items.Count
        }
        catch {
            return $null
        }
    }

    function Get-LogCount {
        param(
            [string] $LogsPath,
            [string[]] $FileNames
        )

        if ([string]::IsNullOrWhiteSpace($LogsPath)) { return $null }
        if (-not (Test-Path -LiteralPath $LogsPath -PathType Container)) { return $null }

        foreach ($fileName in $FileNames) {
            $count = Get-JsonArrayCount -Path (Join-Path $LogsPath $fileName)
            if ($null -ne $count) {
                return $count
            }
        }

        return $null
    }

    # ------------------------------------------------------------
    # CSV counts
    # ------------------------------------------------------------

    $csvFiles = @(
        Get-ChildItem -LiteralPath $ExportPath -File -Filter '*.csv'
    )

    $csvData = @{}

    foreach ($csv in $csvFiles) {
        $csvData[$csv.Name.ToLowerInvariant()] = @(
            Import-Csv -LiteralPath $csv.FullName
        )
    }

    function Get-CsvData {
        param([string] $Name)

        $key = $Name.ToLowerInvariant()

        if ($csvData.ContainsKey($key)) {
            return @($csvData[$key])
        }

        return @()
    }

    $companyRows       = @(Get-CsvData 'organizations.csv')
    $contactRows       = @(Get-CsvData 'contacts.csv')
    $websiteRows       = @(Get-CsvData 'domains.csv')
    $locationRows      = @(Get-CsvData 'locations.csv')
    $configurationRows = @(Get-CsvData 'configurations.csv')
    $articleRows       = @(Get-CsvData 'documents.csv')
    $passwordRows      = @(Get-CsvData 'passwords.csv')

    $companies      = Get-CsvRowCount $companyRows
    $contacts       = Get-CsvRowCount $contactRows
    $websites       = Get-CsvRowCount $websiteRows
    $locations      = Get-CsvRowCount $locationRows
    $configurations = Get-CsvRowCount $configurationRows
    $articles       = Get-CsvRowCount $articleRows
    $passwords      = Get-CsvRowCount $passwordRows
    $ipamCount = @(
        $configurationRows |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_.primary_ip) }
    ).Count

    # Anything else is a flexible asset CSV/layout.
    $flexCsvs = @(
        $csvFiles |
            Where-Object { $_.Name.ToLowerInvariant() -notin $standardCsvs }
    )

    $flexibleLayouts = $flexCsvs.Count

    $flexibleAssets = Get-Sum (
        $flexCsvs |
            ForEach-Object {
                Get-CsvRowCount $csvData[$_.Name.ToLowerInvariant()]
            }
    )

    $simpleRows =
        $companies +
        $contacts +
        $websites +
        $locations +
        $configurations

    $relationSourceObjectsEstimate =
        $flexibleAssets +
        $configurations +
        $passwords +
        $contacts +
        $articles

    $relationSourceCountSource = 'estimated from export rows'
    if ($null -ne $RelationSourceCount) {
        $relationSourceObjects = [int]$RelationSourceCount
        $relationSourceCountSource = 'parameter'
    } else {
        $relationSourceObjects = [int]$relationSourceObjectsEstimate
    }

    $relationCountSource = 'estimated from relation source objects'
    $loggedRelationCount = Get-LogCount -LogsPath $MigrationLogsPath -FileNames @(
        'relations-to-create.json',
        'relations-created.json'
    )
    if ($null -ne $RelationCount) {
        $estimatedRelationCount = [int]$RelationCount
        $relationCountSource = 'parameter'
    } elseif ($null -ne $loggedRelationCount) {
        $estimatedRelationCount = [int]$loggedRelationCount
        $relationCountSource = 'migration log'
    } else {
        $estimatedRelationCount = [int][math]::Round($relationSourceObjects * 0.50)
    }

    $passwordFolderCountSource = 'estimated from password rows'
    $loggedPasswordFolderCount = Get-LogCount -LogsPath $MigrationLogsPath -FileNames @(
        'created-passwordfolders.json'
    )
    if ($null -ne $PasswordFolderCount) {
        $effectivePasswordFolderCount = [int]$PasswordFolderCount
        $passwordFolderCountSource = 'parameter'
    } elseif ($null -ne $loggedPasswordFolderCount) {
        $effectivePasswordFolderCount = [int]$loggedPasswordFolderCount
        $passwordFolderCountSource = 'migration log'
    } else {
        $effectivePasswordFolderCount = [int][math]::Round($passwords * 0.40)
    }

    $archivedRows =
        (Get-ArchivedRowCount $configurationRows) +
        (Get-ArchivedRowCount $passwordRows) +
        (Get-ArchivedRowCount $articleRows) +
        (Get-ArchivedRowCount (
            $flexCsvs | ForEach-Object {
                $csvData[$_.Name.ToLowerInvariant()]
            }
        ))

    $importantContactLabels = @(
        $contactRows | Where-Object { Test-TruthyExportValue -Value $_.important }
    ).Count
    $primaryLocationLabels = @(
        $locationRows | Where-Object { Test-TruthyExportValue -Value $_.primary }
    ).Count
    $configurationStatusLabels = Get-NonBlankPropertyCount -Rows $configurationRows -PropertyName 'configuration_status'
    $passwordCategoryLabels = Get-NonBlankPropertyCount -Rows $passwordRows -PropertyName 'password_category'

    $labelCount =
        $importantContactLabels +
        $primaryLocationLabels +
        $configurationStatusLabels +
        $passwordCategoryLabels

    $importantContactLabelTypes = 0
    if ($importantContactLabels -gt 0) { $importantContactLabelTypes = 1 }

    $primaryLocationLabelTypes = 0
    if ($primaryLocationLabels -gt 0) { $primaryLocationLabelTypes = 1 }

    $labelTypeCount =
        $importantContactLabelTypes +
        $primaryLocationLabelTypes +
        (Get-UniqueNonBlankPropertyCount -Rows $configurationRows -PropertyName 'configuration_status') +
        (Get-UniqueNonBlankPropertyCount -Rows $passwordRows -PropertyName 'password_category')

    # ------------------------------------------------------------
    # Files
    # ------------------------------------------------------------

    $documentFiles = @(
        Get-ChildItem `
            -LiteralPath (Join-Path $ExportPath 'documents') `
            -Recurse `
            -File `
            -ErrorAction SilentlyContinue
    )

    $attachmentFiles = @(
        Get-ChildItem `
            -LiteralPath (Join-Path $ExportPath 'attachments') `
            -Recurse `
            -File `
            -ErrorAction SilentlyContinue
    )

    # Every other top-level directory contains flexible-asset
    # attachment-field files.
    $attachmentFieldFiles = @(
        Get-ChildItem -LiteralPath $ExportPath -Directory |
            Where-Object { $_.Name -notin $reservedDirectories } |
            ForEach-Object {
                Get-ChildItem `
                    -LiteralPath $_.FullName `
                    -Recurse `
                    -File `
                    -ErrorAction SilentlyContinue
            }
    )

    $documents        = Get-FileStats $documentFiles
    $attachments      = Get-FileStats $attachmentFiles
    $attachmentFields = Get-FileStats $attachmentFieldFiles

    # One document file per article; anything beyond that is embedded media.
    $articlePhotos = [math]::Max(
        0,
        $documents.Count - $articles
    )

    $attachmentFileCount =
        $attachments.Count +
        $attachmentFields.Count

    $attachmentMB =
        $attachments.MB +
        $attachmentFields.MB

    # ------------------------------------------------------------
    # Estimate
    # ------------------------------------------------------------

    $effectiveCommitWorkers = Get-EffectiveCommitWorkerCount -WorkerCount $CommitWorkerCount -Efficiency $CommitWorkerEfficiency

    $parts = [ordered]@{
        Companies =
            $companies * $coef.Company

        Locations =
            Get-WorkerAdjustedSeconds -Seconds ($locations * $coef.Location) -CommitRatio 0.80 -EffectiveWorkers $effectiveCommitWorkers

        Websites =
            $websites * $coef.Website

        Configurations =
            Get-WorkerAdjustedSeconds -Seconds ($configurations * $coef.Configuration) -CommitRatio 0.80 -EffectiveWorkers $effectiveCommitWorkers

        Contacts =
            Get-WorkerAdjustedSeconds -Seconds ($contacts * $coef.Contact) -CommitRatio 0.80 -EffectiveWorkers $effectiveCommitWorkers

        FlexibleAssets =
            Get-WorkerAdjustedSeconds -Seconds ($flexibleAssets * $coef.FlexibleAsset) -CommitRatio 0.85 -EffectiveWorkers $effectiveCommitWorkers

        FlexibleLayouts =
            $flexibleLayouts * $coef.FlexibleLayout

        Articles =
            ($articles * $coef.ArticleStub) +
            (Get-WorkerAdjustedSeconds -Seconds ($articles * $coef.ArticleContent) -CommitRatio 1.0 -EffectiveWorkers $effectiveCommitWorkers) +
            ($documents.Count * $coef.DocumentFile) +
            ($documents.MB * $coef.DocumentMB)

        Passwords =
            $passwords * $coef.Password

        PasswordFolders =
            $effectivePasswordFolderCount * $coef.PasswordFolder

        Attachments =
            ($attachmentFileCount * $coef.AttachmentFile) +
            ($attachmentMB * $coef.AttachmentMB)

        IPAM =
            $IPAMCount * $coef.IPAM

        LinkReplacement =
            ($companies + $flexibleAssets + $articles + $passwords) * $coef.LinkReplacementItem

        Labels =
            ($labelTypeCount * $coef.LabelType) +
            (Get-WorkerAdjustedSeconds -Seconds ($labelCount * $coef.Label) -CommitRatio 1.0 -EffectiveWorkers $effectiveCommitWorkers)

        Relations =
            ($relationSourceObjects * $coef.RelationSourceObject) +
            (Get-WorkerAdjustedSeconds -Seconds ($estimatedRelationCount * $coef.RelationCreate) -CommitRatio 1.0 -EffectiveWorkers $effectiveCommitWorkers)

        Archiving =
            Get-WorkerAdjustedSeconds -Seconds ($archivedRows * $coef.ArchiveItem) -CommitRatio 1.0 -EffectiveWorkers $effectiveCommitWorkers
    }

    $rawSeconds = Get-Sum $parts.Values
    $endpointAdjustment = Get-EndpointMultiplier -BaseUri $ITGBaseURI
    $effectiveBuffer = $Buffer * [double]$endpointAdjustment.Multiplier
    $etaSeconds = $rawSeconds * $effectiveBuffer
    $eta        = [timespan]::FromSeconds($etaSeconds)

    if (-not $Detailed) {
        return $eta
    }

    $estimateParts = @(
        foreach ($part in $parts.GetEnumerator()) {
            [pscustomobject]@{
                Name     = $part.Key
                Seconds  = [math]::Round([double]$part.Value, 2)
                Duration = [timespan]::FromSeconds([double]$part.Value)
            }
        }
    )

    [pscustomobject]@{
        EstimatedTime             = $eta
        EstimatedHours            = [math]::Round($eta.TotalHours, 2)
        Buffer                    = $Buffer
        EndpointRegion            = $endpointAdjustment.Region
        EndpointMultiplier        = $endpointAdjustment.Multiplier
        EffectiveBuffer           = $effectiveBuffer
        CommitWorkerCount         = $CommitWorkerCount
        CommitWorkerEfficiency    = $CommitWorkerEfficiency
        EffectiveCommitWorkers    = [math]::Round($effectiveCommitWorkers, 2)
        ITGBaseURI                = $ITGBaseURI

        Companies                 = $companies
        Locations                 = $locations
        Websites                  = $websites
        Configurations            = $configurations
        Contacts                  = $contacts
        SimpleRows                = $simpleRows

        FlexibleLayouts           = $flexibleLayouts
        FlexibleAssets            = $flexibleAssets
        FlexibleLayoutNames       = $flexCsvs.BaseName
        UnsupportedCsvsIgnored    = @($csvFiles | Where-Object { $_.Name.ToLowerInvariant() -in $unsupportedCsvs }).BaseName

        Articles                  = $articles
        ArticlePhotos             = $articlePhotos
        DocumentFiles             = $documents.Count
        DocumentMB                = [math]::Round($documents.MB, 2)

        Passwords                 = $passwords
        PasswordFolders           = $effectivePasswordFolderCount
        PasswordFolderCountSource = $passwordFolderCountSource

        AttachmentFiles           = $attachments.Count
        AttachmentMB              = [math]::Round($attachments.MB, 2)
        AttachmentFieldFiles      = $attachmentFields.Count
        AttachmentFieldMB         = [math]::Round($attachmentFields.MB, 2)
        TotalAttachmentFiles      = $attachmentFileCount
        TotalAttachmentMB         = [math]::Round($attachmentMB, 2)

        IPAMObjects               = $IPAMCount
        ImportantContactLabels    = $importantContactLabels
        PrimaryLocationLabels     = $primaryLocationLabels
        ConfigurationStatusLabels = $configurationStatusLabels
        PasswordCategoryLabels    = $passwordCategoryLabels
        LabelTypes                = $labelTypeCount
        Labels                    = $labelCount
        RelationObjects           = $relationSourceObjects
        RelationSourceObjects     = $relationSourceObjects
        RelationSourceCountSource = $relationSourceCountSource
        EstimatedRelations        = $estimatedRelationCount
        RelationCountSource       = $relationCountSource
        ArchivedItems             = $archivedRows

        EstimateParts             = $estimateParts
        RawEstimate               = [timespan]::FromSeconds($rawSeconds)
        BufferedEstimate          = $eta
    }
}
