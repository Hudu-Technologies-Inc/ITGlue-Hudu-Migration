function Get-ITGlueMigrationETA {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $ExportPath,

        [int] $PasswordFolderCount = 0,

        [double] $Buffer = 1.0,
        [switch] $Detailed
    )

    $coef = @{
        SimpleRow      = 0.45
        FlexibleAsset  = 0.95
        FlexibleLayout = 5.00
        Article        = 0.62
        File           = 0.162
        MB             = 1.323
        Password       = 0.20
        PasswordFolder = 0.85
        IPAM           = 7.00
        Relation       = 0.48
    }

    # CSVs that represent built-in IT Glue object types, not flexible assets
    $standardCsvs = @(
        'organizations.csv'
        'contacts.csv'
        'domains.csv'
        'locations.csv'
        'configurations.csv'
        'documents.csv'
        'passwords.csv'
    )

    # Directories that aren't flexible-asset attachment fields
    $reservedDirectories = @(
        'documents'
        'attachments'
        'vaulted'
    )

    function Get-FileStats {
        param([System.IO.FileInfo[]] $Files)

        $Files = @($Files)

        [pscustomobject]@{
            Count = $Files.Count
            MB    = [double](($Files | Measure-Object Length -Sum).Sum ?? 0) / 1MB
        }
    }

    # ------------------------------------------------------------
    # CSV counts
    # ------------------------------------------------------------

    $csvFiles = @(
        Get-ChildItem -LiteralPath $ExportPath -File -Filter '*.csv'
    )

    $csvCounts = @{}

    foreach ($csv in $csvFiles) {
        $csvCounts[$csv.Name.ToLowerInvariant()] = @(
            Import-Csv -LiteralPath $csv.FullName
        ).Count
    }
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

    $companies      = $companyRows.Count
    $contacts       = $contactRows.Count
    $websites       = $websiteRows.Count
    $locations      = $locationRows.Count
    $configurations = $configurationRows.Count
    $articles       = $articleRows.Count
    $passwords      = $passwordRows.Count
    $ipamCount = @(
        $configurationRows |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_.primary_ip) }
    ).Count

    # Anything else is a flexible asset CSV/layout
    $flexCsvs = @(
        $csvFiles |
            Where-Object { $_.Name -notin $standardCsvs }
    )

    $flexibleLayouts = $flexCsvs.Count

    $flexibleAssets = (
        $flexCsvs |
            ForEach-Object {
                $csvCounts[$_.Name.ToLowerInvariant()]
            } |
            Measure-Object -Sum
    ).Sum ?? 0

    $simpleRows =
        $companies +
        $contacts +
        $websites +
        $locations +
        $configurations

    # One IT Glue relation metadata API lookup for each of these objects
    $relationObjects =
        $simpleRows +
        $flexibleAssets

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

    # One document file per article; anything beyond that is embedded media
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
        SimpleObjects =
            $simpleRows * $coef.SimpleRow

        FlexibleAssets =
            $flexibleAssets * $coef.FlexibleAsset

        FlexibleLayouts =
            $flexibleLayouts * $coef.FlexibleLayout

        Articles =
            ($articles * $coef.Article) +
            ($articlePhotos * $coef.File) +
            ($documents.MB * $coef.MB)

        Passwords =
            $passwords * $coef.Password

        PasswordFolders =
            $PasswordFolderCount * $coef.PasswordFolder

        Attachments =
            ($attachmentFileCount * $coef.File) +
            ($attachmentMB * $coef.MB)

        IPAM =
            $IPAMCount * $coef.IPAM

        Relations =
            $relationObjects * $coef.Relation
    }

    $rawSeconds = ($parts.Values | Measure-Object -Sum).Sum
    $etaSeconds = $rawSeconds * $Buffer
    $eta        = [timespan]::FromSeconds($etaSeconds)

    if (-not $Detailed) {
        return $eta
    }

    [pscustomobject]@{
        EstimatedTime        = $eta
        EstimatedHours       = [math]::Round($eta.TotalHours, 2)
        Buffer               = $Buffer

        Companies            = $companies
        Locations            = $locations
        Websites             = $websites
        Configurations       = $configurations
        Contacts             = $contacts
        SimpleRows           = $simpleRows

        FlexibleLayouts      = $flexibleLayouts
        FlexibleAssets       = $flexibleAssets
        FlexibleLayoutNames  = $flexCsvs.BaseName

        Articles             = $articles
        ArticlePhotos        = $articlePhotos
        DocumentFiles        = $documents.Count
        DocumentMB           = [math]::Round($documents.MB, 2)

        Passwords            = $passwords
        PasswordFolders      = $PasswordFolderCount

        AttachmentFiles      = $attachments.Count
        AttachmentMB         = [math]::Round($attachments.MB, 2)
        AttachmentFieldFiles = $attachmentFields.Count
        AttachmentFieldMB    = [math]::Round($attachmentFields.MB, 2)
        TotalAttachmentFiles = $attachmentFileCount
        TotalAttachmentMB    = [math]::Round($attachmentMB, 2)

        IPAMObjects          = $IPAMCount
        RelationObjects      = $relationObjects

        RawEstimate          = [timespan]::FromSeconds($rawSeconds)
        BufferedEstimate     = $eta
    }
}