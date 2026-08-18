function Get-ITGlueMigrationETA {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $ExportPath,

        [Nullable[int]] $PasswordFolderCount = $null,
        [Nullable[int]] $RelationCount = $null,
        [Nullable[int]] $RelationSourceCount = $null,
        [string] $MigrationLogsPath,

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

    $parts = [ordered]@{
        Companies =
            $companies * $coef.Company

        Locations =
            $locations * $coef.Location

        Websites =
            $websites * $coef.Website

        Configurations =
            $configurations * $coef.Configuration

        Contacts =
            $contacts * $coef.Contact

        FlexibleAssets =
            $flexibleAssets * $coef.FlexibleAsset

        FlexibleLayouts =
            $flexibleLayouts * $coef.FlexibleLayout

        Articles =
            ($articles * $coef.ArticleStub) +
            ($articles * $coef.ArticleContent) +
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

        Relations =
            ($relationSourceObjects * $coef.RelationSourceObject) +
            ($estimatedRelationCount * $coef.RelationCreate)

        Archiving =
            $archivedRows * $coef.ArchiveItem
    }

    $rawSeconds = Get-Sum $parts.Values
    $etaSeconds = $rawSeconds * $Buffer
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
