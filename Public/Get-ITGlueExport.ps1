function Get-ITGlueExportDownloadUrl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Export
    )

    $candidates = @(
        $Export.data.attributes.'download-url'
        $Export.data.attributes.download_url
        $Export.data.'download-url'
        $Export.data.download_url
        $Export.attributes.'download-url'
        $Export.attributes.download_url
        $Export.'download-url'
        $Export.download_url
    )

    return $candidates |
        Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
        Select-Object -First 1
}

function Get-ITGlueExportStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Export
    )

    $candidates = @(
        $Export.data.attributes.'export-status'
        $Export.data.attributes.status
        $Export.data.attributes.state
        $Export.attributes.'export-status'
        $Export.attributes.status
        $Export.attributes.state
        $Export.'export-status'
        $Export.status
        $Export.state
    )

    return $candidates |
        Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
        Select-Object -First 1
}

function Get-ITGlueExportId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Export
    )

    $id = @(
        $Export.data.id
        $Export.id
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -First 1

    if ($id) {
        return [Int64]$id
    }

    return $null
}

function Get-ITGlueExportTimestamp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Export,

        [Parameter(Mandatory = $true)]
        [ValidateSet('created-at', 'updated-at')]
        [string]$Name
    )

    $candidates = @(
        $Export.data.attributes.$Name
        $Export.attributes.$Name
        $Export.$Name
    )

    $rawValue = $candidates |
        Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
        Select-Object -First 1

    if ([string]::IsNullOrWhiteSpace([string]$rawValue)) {
        return $null
    }

    if ($rawValue -is [datetimeoffset]) {
        return $rawValue.UtcDateTime
    }

    if ($rawValue -is [datetime]) {
        if ($rawValue.Kind -eq [DateTimeKind]::Unspecified) {
            return [datetime]::SpecifyKind($rawValue, [DateTimeKind]::Utc)
        }

        return $rawValue.ToUniversalTime()
    }

    try {
        $dateStyles = [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
        return [datetimeoffset]::Parse([string]$rawValue, [System.Globalization.CultureInfo]::InvariantCulture, $dateStyles).UtcDateTime
    } catch {
        return $null
    }
}

function ConvertTo-ITGlueExportUtcDateTime {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [datetime]$Value
    )

    if ($Value.Kind -eq [DateTimeKind]::Unspecified) {
        return [datetime]::SpecifyKind($Value, [DateTimeKind]::Utc)
    }

    return $Value.ToUniversalTime()
}

function Format-ITGlueExportUtcTimestamp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [datetime]$Value
    )

    (ConvertTo-ITGlueExportUtcDateTime -Value $Value).ToString("yyyy-MM-ddTHH:mm:ss'Z'", [System.Globalization.CultureInfo]::InvariantCulture)
}

function Select-ITGlueExportRecordForPolling {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $ExportsResponse,

        [AllowNull()]
        [Nullable[datetime]]$QueuedAfter = $null
    )

    $records = @(Get-ITGlueExportRecords -ExportsResponse $ExportsResponse)
    if ($records.Count -eq 0) {
        return $null
    }

    if ($null -ne $QueuedAfter) {
        $queueWindowStart = (ConvertTo-ITGlueExportUtcDateTime -Value ([datetime]$QueuedAfter)).AddMinutes(-2)
        $records = @(
            $records | Where-Object {
                $createdAt = Get-ITGlueExportTimestamp -Export $_ -Name 'created-at'
                $createdAt -and $createdAt -ge $queueWindowStart
            }
        )
    }

    if ($records.Count -eq 0) {
        return $null
    }

    $records |
        Sort-Object -Property @(
            @{ Expression = { Get-ITGlueExportTimestamp -Export $_ -Name 'updated-at' }; Descending = $true }
            @{ Expression = { Get-ITGlueExportTimestamp -Export $_ -Name 'created-at' }; Descending = $true }
            @{ Expression = { Get-ITGlueExportId -Export $_ }; Descending = $true }
        ) |
        Select-Object -First 1
}

function Test-ITGlueExportPathHasContent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container -ErrorAction SilentlyContinue)) {
        return $false
    }

    return [bool](Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue | Select-Object -First 1)
}

function New-ITGlueExportZipPassword {
    [CmdletBinding()]
    param(
        [ValidateRange(16, 128)]
        [int]$ByteCount = 32
    )

    $bytes = [byte[]]::new($ByteCount)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    return [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function Get-ITGlueExportZipPasswordLogPath {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$LogsPath,

        [Parameter(Mandatory = $true)]
        [string]$FallbackPath
    )

    if ([string]::IsNullOrWhiteSpace($LogsPath)) {
        $LogsPath = $FallbackPath
    }

    $null = New-Item -Path $LogsPath -ItemType Directory -Force
    return Join-Path -Path $LogsPath -ChildPath 'ITGlueExportZipPassword.txt'
}

function Get-OrCreateITGlueExportZipPassword {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$LogsPath,

        [Parameter(Mandatory = $true)]
        [string]$FallbackPath
    )

    $passwordLogPath = Get-ITGlueExportZipPasswordLogPath -LogsPath $LogsPath -FallbackPath $FallbackPath
    if (Test-Path -LiteralPath $passwordLogPath -PathType Leaf -ErrorAction SilentlyContinue) {
        $existingLog = Get-Content -LiteralPath $passwordLogPath -Raw -ErrorAction Stop
        if ($existingLog -match '(?m)^Password:\s*(?<password>\S+)\s*$') {
            Write-Host "Reusing IT Glue export ZIP password from $passwordLogPath" -ForegroundColor Yellow
            return [pscustomobject]@{
                Password = $Matches.password
                Path     = $passwordLogPath
                Reused   = $true
            }
        }
    }

    $password = New-ITGlueExportZipPassword
    $createdAt = Get-Date -Format 'o'
    @(
        'IT Glue export ZIP password'
        "CreatedAt: $createdAt"
        "Password: $password"
        ''
        'Keep this file secure. The automated export bootstrap reuses this password on retry.'
    ) | Set-Content -LiteralPath $passwordLogPath -Encoding UTF8 -Force

    Write-Host "Generated IT Glue export ZIP password and wrote it to $passwordLogPath" -ForegroundColor Yellow
    return [pscustomobject]@{
        Password = $password
        Path     = $passwordLogPath
        Reused   = $false
    }
}

function Resolve-SevenZipPath {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$SevenZipPath
    )

    $projectRoot = Split-Path -Path $PSScriptRoot -Parent
    $candidates = @(
        $SevenZipPath
        $env:ITG_HUDU_7Z_PATH
        (Join-Path $projectRoot '7z.exe')
        (Join-Path $projectRoot '7za.exe')
        (Join-Path $projectRoot '7zr.exe')
        (Join-Path $projectRoot '7zip\7z.exe')
        (Join-Path $projectRoot '7zip\7za.exe')
        (Join-Path $projectRoot '7zip\7zr.exe')
        (Join-Path $projectRoot 'tools\7zip\7z.exe')
        (Join-Path $projectRoot 'tools\7zip\7za.exe')
        (Join-Path $projectRoot 'tools\7zip\7zr.exe')
        (Get-Command -Name 7z.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -First 1)
        (Get-Command -Name 7za.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -First 1)
        (Get-Command -Name 7zr.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -First 1)
    )

    if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
        $candidates += Join-Path $env:ProgramFiles '7-Zip\7z.exe'
    }

    if (-not [string]::IsNullOrWhiteSpace(${env:ProgramFiles(x86)}) -and $env:ProgramFiles -ne ${env:ProgramFiles(x86)}) {
        $candidates += Join-Path ${env:ProgramFiles(x86)} '7-Zip\7z.exe'
    }

    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace([string]$candidate)) {
            continue
        }

        if (Test-Path -LiteralPath $candidate -PathType Leaf -ErrorAction SilentlyContinue) {
            return (Get-Item -LiteralPath $candidate).FullName
        }
    }

    throw "7-Zip executable not found. Install 7-Zip or set `$SevenZipPath / `$ITGlueExportSevenZipPath / ITG_HUDU_7Z_PATH to the full path of 7z.exe."
}

function ConvertTo-SafeFileNamePart {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$Value,

        [string]$Fallback = 'export'
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $Fallback
    }

    $safeValue = $Value.Trim() -replace '^https?://', ''
    foreach ($invalidChar in [System.IO.Path]::GetInvalidFileNameChars()) {
        $safeValue = $safeValue.Replace($invalidChar, '-')
    }

    $safeValue = ($safeValue -replace '-+', '-').Trim(' ', '.', '-')
    if ([string]::IsNullOrWhiteSpace($safeValue)) {
        return $Fallback
    }

    return $safeValue
}

function Resolve-ITGlueExportBaseURI {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$ITGBaseURI
    )

    $candidates = @($ITGBaseURI)

    if (Get-Command -Name Get-ITGlueBaseURI -ErrorAction SilentlyContinue) {
        try {
            $candidates += Get-ITGlueBaseURI
        } catch {
        }
    }

    $candidates += @(
        $ITGAPIEndpoint
        $settings.ITGAPIEndpoint
        $environmentSettings.ITGAPIEndpoint
    )

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

function Get-ITGlueExport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ITGKey,

        [AllowNull()]
        [Alias('ITGAPIEndpoint')]
        [string]$ITGBaseURI,

        [ValidateRange(1, 100000)]
        [int]$PageNumber = 1,

        [ValidateRange(1, 1000)]
        [int]$PageSize = 100,

        [AllowNull()]
        [string]$Sort = '-updated-at'
    )

    $ITGBaseURI = Resolve-ITGlueExportBaseURI -ITGBaseURI $ITGBaseURI
    $headers = @{
        'x-api-key'    = $ITGKey
        'Content-Type' = 'application/vnd.api+json'
        'Accept'       = 'application/vnd.api+json'
    }

    $queryParts = @(
        "page[number]=$PageNumber"
        "page[size]=$PageSize"
    )

    if (-not [string]::IsNullOrWhiteSpace($Sort)) {
        $queryParts += "sort=$([uri]::EscapeDataString($Sort))"
    }

    Invoke-RestMethod -Uri "$($ITGBaseURI.TrimEnd('/'))/exports?$($queryParts -join '&')" -Method GET -Headers $headers -ErrorAction Stop
}

Set-Alias -Name List-ITGlueExports -Value Get-ITGlueExport -ErrorAction SilentlyContinue

function Get-ITGlueExportRecords {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $ExportsResponse
    )

    if ($null -eq $ExportsResponse) {
        return @()
    }

    if ($null -ne $ExportsResponse.data) {
        return @($ExportsResponse.data)
    }

    return @($ExportsResponse)
}

function Get-ITGlueLatestExport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ITGKey,

        [AllowNull()]
        [Alias('ITGAPIEndpoint')]
        [string]$ITGBaseURI
    )

    $exportsResponse = Get-ITGlueExport -ITGKey $ITGKey -ITGBaseURI $ITGBaseURI -PageNumber 1 -PageSize 1 -Sort '-updated-at'
    Get-ITGlueExportRecords -ExportsResponse $exportsResponse | Select-Object -First 1
}

function Test-ITGlueExportAlreadyAvailableError {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $statusCode = try {
        [int]$ErrorRecord.Exception.Response.StatusCode
    } catch {
        $null
    }

    $errorText = @(
        $ErrorRecord.ErrorDetails.Message
        $ErrorRecord.Exception.Message
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Out-String

    $isDuplicateExportError = $errorText -match 'same attributes|already available'
    $isUnprocessableEntity = ($statusCode -eq 422 -or $errorText -match '\b422\b|Unprocessable')

    return ($isUnprocessableEntity -and $isDuplicateExportError)
}

function Get-ITGlueExportById {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ITGKey,

        [Parameter(Mandatory = $true)]
        [Int64]$ExportID,

        [AllowNull()]
        [Alias('ITGAPIEndpoint')]
        [string]$ITGBaseURI
    )

    $ITGBaseURI = Resolve-ITGlueExportBaseURI -ITGBaseURI $ITGBaseURI
    $headers = @{
        'x-api-key'    = $ITGKey
        'Content-Type' = 'application/vnd.api+json'
        'Accept'       = 'application/vnd.api+json'
    }

    Invoke-RestMethod -Uri "$($ITGBaseURI.TrimEnd('/'))/exports/$ExportID" -Method GET -Headers $headers -ErrorAction Stop
}

Set-Alias -Name Show-ITGlueExport -Value Get-ITGlueExportById -ErrorAction SilentlyContinue

function Remove-ITGlueExport {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ITGKey,

        [Parameter(Mandatory = $true)]
        [Int64]$ExportID,

        [AllowNull()]
        [Alias('ITGAPIEndpoint')]
        [string]$ITGBaseURI
    )

    $ITGBaseURI = Resolve-ITGlueExportBaseURI -ITGBaseURI $ITGBaseURI
    if (-not $PSCmdlet.ShouldProcess("IT Glue export $ExportID", 'Delete')) {
        return
    }

    $headers = @{
        'x-api-key'    = $ITGKey
        'Content-Type' = 'application/vnd.api+json'
        'Accept'       = 'application/vnd.api+json'
    }

    $null = Invoke-RestMethod -Uri "$($ITGBaseURI.TrimEnd('/'))/exports/$ExportID" -Method DELETE -Headers $headers -ErrorAction Stop
}

function Clear-ITGlueExports {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ITGKey,

        [AllowNull()]
        [Alias('ITGAPIEndpoint')]
        [string]$ITGBaseURI
    )

    $ITGBaseURI = Resolve-ITGlueExportBaseURI -ITGBaseURI $ITGBaseURI
    $exportsResponse = Get-ITGlueExport -ITGKey $ITGKey -ITGBaseURI $ITGBaseURI
    $exports = @(Get-ITGlueExportRecords -ExportsResponse $exportsResponse)
    if ($exports.Count -eq 0) {
        Write-Host "No existing IT Glue exports found to clear." -ForegroundColor Green
        return @()
    }

    $removed = foreach ($export in $exports) {
        $exportId = Get-ITGlueExportId -Export $export
        if ($null -eq $exportId) {
            Write-Warning "Skipping an existing IT Glue export because it did not include an id."
            continue
        }

        if ($PSCmdlet.ShouldProcess("IT Glue export $exportId", 'Delete before queuing a new export')) {
            Remove-ITGlueExport -ITGKey $ITGKey -ITGBaseURI $ITGBaseURI -ExportID $exportId
            Write-Host "Deleted existing IT Glue export $exportId." -ForegroundColor Yellow
            $exportId
        }
    }

    return @($removed)
}

function Start-ITGlueExport {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ITGKey,

        [AllowNull()]
        [Alias('ITGAPIEndpoint')]
        [string]$ITGBaseURI,

        [AllowNull()]
        [string]$ZipPassword,

        [Nullable[Int64]]$OrganizationID = $null,

        [bool]$IncludeLogs = $false,

        [string[]]$CoreAssetTypes = @(
            'contacts',
            'configurations',
            'documents',
            'domains',
            'locations',
            'passwords',
            'ssl_certificates'
        ),

        [bool]$AllFlexibleAssets = $true,

        [Int64[]]$FlexibleAssetTypeIDs = @(),

        [ValidateSet('Hyphen', 'Snake')]
        [string]$AttributeNameStyle = 'Hyphen'
    )

    if ($AllFlexibleAssets -and $FlexibleAssetTypeIDs.Count -gt 0) {
        throw "Use either -AllFlexibleAssets `$true or -FlexibleAssetTypeIDs, not both."
    }

    $ITGBaseURI = Resolve-ITGlueExportBaseURI -ITGBaseURI $ITGBaseURI
    $headers = @{
        'x-api-key'    = $ITGKey
        'Content-Type' = 'application/vnd.api+json'
        'Accept'       = 'application/vnd.api+json'
    }

    $attributeNames = if ($AttributeNameStyle -eq 'Snake') {
        @{
            IncludeLogs          = 'include_logs'
            CoreAssetTypes       = 'core_assets_types'
            AllFlexibleAssets    = 'all_flexible_assets'
            IncludePasswords     = 'include_passwords'
            OrganizationID       = 'organization_id'
            ZipPassword          = 'zip_password'
            FlexibleAssetTypeIDs = 'flexible_assets_types'
        }
    } else {
        @{
            IncludeLogs          = 'include-logs'
            CoreAssetTypes       = 'core-assets-types'
            AllFlexibleAssets    = 'all-flexible-assets'
            IncludePasswords     = 'include-passwords'
            OrganizationID       = 'organization-id'
            ZipPassword          = 'zip-password'
            FlexibleAssetTypeIDs = 'flexible-assets-types'
        }
    }

    $attributes = [ordered]@{
        $attributeNames.IncludeLogs       = $IncludeLogs
        $attributeNames.CoreAssetTypes    = $CoreAssetTypes
        $attributeNames.AllFlexibleAssets = $AllFlexibleAssets
        $attributeNames.IncludePasswords  = $true
    }

    if ($null -ne $OrganizationID) {
        $attributes[$attributeNames.OrganizationID] = [Int64]$OrganizationID
    }

    if (-not [string]::IsNullOrWhiteSpace($ZipPassword)) {
        $attributes[$attributeNames.ZipPassword] = $ZipPassword
    }

    if (-not $AllFlexibleAssets -and $FlexibleAssetTypeIDs.Count -gt 0) {
        $attributes[$attributeNames.FlexibleAssetTypeIDs] = @($FlexibleAssetTypeIDs)
    }

    $body = @{
        data = @{
            type       = 'exports'
            attributes = $attributes
        }
    } | ConvertTo-Json -Depth 10

    $target = if ($null -ne $OrganizationID) { "organization $OrganizationID" } else { 'all organizations' }
    if (-not $PSCmdlet.ShouldProcess($target, 'Start IT Glue export')) {
        return
    }

    Write-Verbose "IT Glue export create payload: $body"
    Invoke-RestMethod -Uri "$($ITGBaseURI.TrimEnd('/'))/exports" -Method POST -Headers $headers -Body $body -ErrorAction Stop
}

function Wait-ITGlueExport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ITGKey,

        [AllowNull()]
        [Alias('ITGAPIEndpoint')]
        [string]$ITGBaseURI,

        [AllowNull()]
        [Nullable[Int64]]$ExportID = $null,

        [ValidateRange(5, 3600)]
        [int]$PollSeconds = 60,

        [ValidateRange(1, 1440)]
        [int]$TimeoutMinutes = 240,

        [AllowNull()]
        [Nullable[datetime]]$QueuedAfter = $null,

        [ValidateRange(5, 1440)]
        [int]$StalledMinutes = 90
    )

    $deadline = [datetime]::UtcNow.AddMinutes($TimeoutMinutes)
    $ITGBaseURI = Resolve-ITGlueExportBaseURI -ITGBaseURI $ITGBaseURI
    $failedStatuses = @(
        'failed',
        'failure',
        'error',
        'errored',
        'cancelled',
        'canceled'
    )

    while ([datetime]::UtcNow -lt $deadline) {
        $exportResponse = if ($null -ne $ExportID) {
            Get-ITGlueExportById -ITGKey $ITGKey -ITGBaseURI $ITGBaseURI -ExportID $ExportID
        } else {
            Get-ITGlueExport -ITGKey $ITGKey -ITGBaseURI $ITGBaseURI
        }

        $export = if ($null -ne $ExportID) {
            $exportResponse
        } else {
            Select-ITGlueExportRecordForPolling -ExportsResponse $exportResponse -QueuedAfter $QueuedAfter
        }

        if ($null -eq $export) {
            $queueText = if ($null -ne $QueuedAfter) { " created after $(Format-ITGlueExportUtcTimestamp -Value ([datetime]$QueuedAfter))" } else { "" }
            Write-Host "No IT Glue export record$queueText was found yet. Checking again in $PollSeconds seconds." -ForegroundColor Yellow
            Start-Sleep -Seconds $PollSeconds
            continue
        }

        $downloadUrl = Get-ITGlueExportDownloadUrl -Export $export
        if (-not [string]::IsNullOrWhiteSpace([string]$downloadUrl)) {
            return [pscustomobject]@{
                Export      = $export
                DownloadUrl = $downloadUrl
            }
        }

        $status = Get-ITGlueExportStatus -Export $export
        $exportRecordId = Get-ITGlueExportId -Export $export
        $createdAt = Get-ITGlueExportTimestamp -Export $export -Name 'created-at'
        $updatedAt = Get-ITGlueExportTimestamp -Export $export -Name 'updated-at'

        if ($status -and ($failedStatuses -contains ([string]$status).ToLowerInvariant())) {
            $idText = if ($null -ne $exportRecordId) { " $exportRecordId" } else { "" }
            throw "IT Glue export$idText reported terminal status '$status' before a download URL was available."
        }

        $stalledAfter = [datetime]::UtcNow.AddMinutes(-1 * $StalledMinutes)
        if ($updatedAt -and $updatedAt -lt $stalledAfter) {
            $idText = if ($null -ne $exportRecordId) { " $exportRecordId" } else { "" }
            $statusText = if ($status) { " Status: $status." } else { "" }
            throw "IT Glue export$idText appears stalled; updated-at is $(Format-ITGlueExportUtcTimestamp -Value $updatedAt), which is older than $StalledMinutes minutes.$statusText"
        }

        $details = @()
        if ($null -ne $exportRecordId) { $details += "id: $exportRecordId" }
        if ($status) { $details += "status: $status" }
        if ($createdAt) { $details += "created: $(Format-ITGlueExportUtcTimestamp -Value $createdAt)" }
        if ($updatedAt) { $details += "updated: $(Format-ITGlueExportUtcTimestamp -Value $updatedAt)" }
        $detailText = if ($details.Count -gt 0) { " ($($details -join '; '))" } else { "" }
        Write-Host "IT Glue export is not ready yet$detailText. Checking again in $PollSeconds seconds." -ForegroundColor Yellow
        Start-Sleep -Seconds $PollSeconds
    }

    throw "Timed out after $TimeoutMinutes minutes waiting for IT Glue export readiness."
}

function Save-ITGlueExportArchive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$DownloadUrl,

        [Parameter(Mandatory = $true)]
        [string]$OutputPath
    )

    $outputParent = Split-Path -Path $OutputPath -Parent
    if (-not [string]::IsNullOrWhiteSpace($outputParent)) {
        $null = New-Item -Path $outputParent -ItemType Directory -Force
    }

    Write-Host "Downloading IT Glue export to $OutputPath" -ForegroundColor Cyan
    $null = Invoke-WebRequest -Uri $DownloadUrl -OutFile $OutputPath -ErrorAction Stop
    return (Get-Item -LiteralPath $OutputPath).FullName
}

function Expand-ITGlueExportArchive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ArchivePath,

        [Parameter(Mandatory = $true)]
        [string]$DestinationPath,

        [AllowNull()]
        [string]$SevenZipPath,

        [AllowNull()]
        [string]$ZipPassword
    )

    $resolvedSevenZip = Resolve-SevenZipPath -SevenZipPath $SevenZipPath
    $null = New-Item -Path $DestinationPath -ItemType Directory -Force

    $arguments = @(
        'x'
        '-y'
        "-o$DestinationPath"
        $ArchivePath
    )

    if (-not [string]::IsNullOrWhiteSpace($ZipPassword)) {
        $arguments += "-p$ZipPassword"
    }

    Write-Host "Extracting IT Glue export to $DestinationPath with $resolvedSevenZip" -ForegroundColor Cyan
    $sevenZipOutput = & $resolvedSevenZip @arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        if ($sevenZipOutput) {
            $sevenZipOutput | ForEach-Object { Write-Warning $_ }
        }
        throw "7-Zip failed to extract $ArchivePath with exit code $LASTEXITCODE."
    }

    return (Get-Item -LiteralPath $DestinationPath).FullName
}

function Ensure-ITGlueExportAvailable {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ITGKey,

        [AllowNull()]
        [Alias('ITGAPIEndpoint')]
        [string]$ITGBaseURI,

        [Parameter(Mandatory = $true)]
        [string]$ExportPath,

        [AllowNull()]
        [string]$DownloadPath,

        [AllowNull()]
        [string]$SevenZipPath,

        [AllowNull()]
        [string]$ZipPassword,

        [AllowNull()]
        [string]$DownloadFileNameTag,

        [AllowNull()]
        [string]$LogsPath,

        [bool]$GenerateZipPassword = $true,

        [bool]$ClearExistingExports = $true,

        [bool]$IncludeLogs = $false,

        [ValidateRange(5, 3600)]
        [int]$PollSeconds = 60,

        [ValidateRange(1, 1440)]
        [int]$TimeoutMinutes = 240,

        [ValidateRange(5, 1440)]
        [int]$StalledMinutes = 90,

        [ValidateSet('Hyphen', 'Snake')]
        [string]$AttributeNameStyle = 'Hyphen',

        [bool]$UseExistingExportOnly = $false,

        [AllowNull()]
        [Nullable[Int64]]$ExistingExportID = $null
    )

    if ([string]::IsNullOrWhiteSpace($ExportPath)) {
        throw "IT Glue export path is blank."
    }

    $ITGBaseURI = Resolve-ITGlueExportBaseURI -ITGBaseURI $ITGBaseURI
    if (Test-ITGlueExportPathHasContent -Path $ExportPath) {
        Write-Host "IT Glue export path already contains files at $ExportPath; skipping automatic export download." -ForegroundColor Green
        return [pscustomobject]@{
            ExportPath   = (Get-Item -LiteralPath $ExportPath).FullName
            DownloadPath = $null
            Started      = $false
            Extracted    = $false
        }
    }

    if (-not $PSCmdlet.ShouldProcess($ExportPath, 'Request, download, and extract IT Glue tenant export')) {
        return
    }

    $exportParent = Split-Path -Path $ExportPath -Parent
    if ([string]::IsNullOrWhiteSpace($exportParent)) {
        $exportParent = (Get-Location).Path
    }
    $null = New-Item -Path $exportParent -ItemType Directory -Force
    $null = New-Item -Path $ExportPath -ItemType Directory -Force
    $resolvedSevenZipPath = Resolve-SevenZipPath -SevenZipPath $SevenZipPath

    $generatedPasswordInfo = $null
    if ([string]::IsNullOrWhiteSpace($ZipPassword) -and $true -eq $GenerateZipPassword) {
        $generatedPasswordInfo = Get-OrCreateITGlueExportZipPassword -LogsPath $LogsPath -FallbackPath $exportParent
        $ZipPassword = $generatedPasswordInfo.Password
    }

    if ([string]::IsNullOrWhiteSpace($DownloadPath)) {
        $safeTimestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $safeTenantName = ConvertTo-SafeFileNamePart -Value ($DownloadFileNameTag ?? $ITGBaseURI) -Fallback 'itglue'
        $DownloadPath = Join-Path -Path $exportParent -ChildPath "ITGlueExport-$safeTenantName-$safeTimestamp.zip"
    }

    Write-Host "No extracted IT Glue export content was found at $ExportPath. Preparing IT Glue export download/extract." -ForegroundColor Yellow
    if ($true -ne $UseExistingExportOnly) {
        Write-Host "Using IT Glue export attribute name style: $AttributeNameStyle." -ForegroundColor Cyan
    }
    $startedExport = $null
    $exportId = $null
    $usedExistingExport = $false
    $clearedExportIds = @()
    $queueRequestedAt = $null

    if ($true -eq $UseExistingExportOnly) {
        $usedExistingExport = $true
        if ($null -ne $ExistingExportID) {
            $exportId = [Int64]$ExistingExportID
            Write-Host "Using existing IT Glue export id $exportId; no new export will be queued." -ForegroundColor Cyan
        } else {
            $latestExport = Get-ITGlueLatestExport -ITGKey $ITGKey -ITGBaseURI $ITGBaseURI
            $exportId = Get-ITGlueExportId -Export $latestExport
            if ($null -eq $exportId) {
                throw "No existing IT Glue export id was found to download. Create an export in IT Glue first, or disable ITGlueExportUseExistingExportOnly."
            }
            Write-Host "Using latest existing IT Glue export id $exportId; no new export will be queued." -ForegroundColor Cyan
        }
    } else {
        $exportProtectionText = if ([string]::IsNullOrWhiteSpace($ZipPassword)) { 'passwordless' } else { 'encrypted' }
        if ($true -eq $ClearExistingExports) {
            Write-Host "Clearing existing IT Glue exports before queueing a new $exportProtectionText export." -ForegroundColor Yellow
            $clearedExportIds = @(Clear-ITGlueExports -ITGKey $ITGKey -ITGBaseURI $ITGBaseURI)
        } else {
            Write-Host "Existing IT Glue exports will not be cleared before queueing. A duplicate export response may reuse an existing download." -ForegroundColor Yellow
        }

        for ($attempt = 1; $attempt -le 3; $attempt++) {
            try {
                $queueRequestedAt = [datetime]::UtcNow
                $startedExport = Start-ITGlueExport -ITGKey $ITGKey -ITGBaseURI $ITGBaseURI -ZipPassword $ZipPassword -IncludeLogs $IncludeLogs -AttributeNameStyle $AttributeNameStyle
                $exportId = Get-ITGlueExportId -Export $startedExport
                if ($null -eq $exportId) {
                    Write-Warning "IT Glue did not return an export id. Falling back to export list polling."
                } else {
                    Write-Host "IT Glue export queued with id $exportId." -ForegroundColor Green
                }
                break
            } catch {
                if (-not (Test-ITGlueExportAlreadyAvailableError -ErrorRecord $_)) {
                    throw
                }

                if ($true -ne $ClearExistingExports) {
                    $usedExistingExport = $true
                    $queueRequestedAt = $null
                    Write-Host "IT Glue reports a matching export is already available. Reusing the existing export download." -ForegroundColor Yellow
                    break
                }

                if ($attempt -ge 3) {
                    $retryGuidance = if ([string]::IsNullOrWhiteSpace($ZipPassword)) {
                        "Wait a few minutes and retry, or set ITGlueExportClearExistingExports to `$false only if you know the existing export is also passwordless."
                    } else {
                        "Wait a few minutes and retry, or set ITGlueExportClearExistingExports to `$false only if you know the existing export password matches this run."
                    }
                    throw "IT Glue still reports a matching export is already available after clearing existing exports. $retryGuidance"
                }

                Write-Warning "IT Glue still reports a matching export after cleanup. Waiting 15 seconds, clearing again, and retrying export queue attempt $($attempt + 1) of 3."
                Start-Sleep -Seconds 15
                $clearedExportIds += @(Clear-ITGlueExports -ITGKey $ITGKey -ITGBaseURI $ITGBaseURI)
            }
        }
    }

    $readyExport = Wait-ITGlueExport -ITGKey $ITGKey -ITGBaseURI $ITGBaseURI -ExportID $exportId -PollSeconds $PollSeconds -TimeoutMinutes $TimeoutMinutes -QueuedAfter $queueRequestedAt -StalledMinutes $StalledMinutes
    $archivePath = Save-ITGlueExportArchive -DownloadUrl $readyExport.DownloadUrl -OutputPath $DownloadPath
    $expandedPath = Expand-ITGlueExportArchive -ArchivePath $archivePath -DestinationPath $ExportPath -SevenZipPath $resolvedSevenZipPath -ZipPassword $ZipPassword

    if (-not (Test-ITGlueExportPathHasContent -Path $expandedPath)) {
        throw "IT Glue export extraction completed but $expandedPath is still empty."
    }

    [pscustomobject]@{
        ExportPath   = $expandedPath
        DownloadPath = $archivePath
        Started      = (-not $usedExistingExport)
        Reused       = $usedExistingExport
        Extracted    = $true
        PasswordLog  = $generatedPasswordInfo.Path
        ClearedExports = $clearedExportIds
    }
}

function Start-ITGlueExportBootstrapJob {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$ExportParameters,

        [Parameter(Mandatory = $true)]
        [string]$HelperScriptPath
    )

    if (-not (Test-Path -LiteralPath $HelperScriptPath -PathType Leaf -ErrorAction SilentlyContinue)) {
        throw "IT Glue export helper script was not found at $HelperScriptPath."
    }

    $jobName = "ITGlueExportBootstrap-$([guid]::NewGuid().ToString('N'))"
    Start-Job -Name $jobName -ArgumentList $HelperScriptPath, $ExportParameters -ScriptBlock {
        param(
            [string]$ScriptPath,
            [hashtable]$Parameters
        )

        . $ScriptPath
        Ensure-ITGlueExportAvailable @Parameters
    }
}

function Wait-ITGlueExportBootstrapJob {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Job]$Job,

        [ValidateRange(5, 3600)]
        [int]$StatusSeconds = 60,

        [switch]$KeepJob
    )

    Write-Host "Waiting for background IT Glue export job $($Job.Id) to finish." -ForegroundColor Cyan
    $waitStarted = Get-Date
    $lastReceivedCount = 0
    while ($Job.State -in @('NotStarted', 'Running')) {
        $completedJob = Wait-Job -Job $Job -Timeout $StatusSeconds
        if ($completedJob) {
            break
        }

        $jobOutput = @(Receive-Job -Job $Job -Keep -ErrorAction SilentlyContinue)
        if ($jobOutput.Count -gt $lastReceivedCount) {
            $newJobOutput = @($jobOutput[$lastReceivedCount..($jobOutput.Count - 1)])
            foreach ($item in $newJobOutput) {
                $message = if ($item -is [string]) { $item } else { ($item | Out-String).Trim() }
                if (-not [string]::IsNullOrWhiteSpace($message)) {
                    Write-Host "[IT Glue export job] $message" -ForegroundColor DarkCyan
                }
            }
            $lastReceivedCount = $jobOutput.Count
        }

        $elapsed = (Get-Date) - $waitStarted
        Write-Host "Background IT Glue export job $($Job.Id) is still $($Job.State) after $($elapsed.ToString('hh\:mm\:ss')). Checking again in $StatusSeconds seconds." -ForegroundColor Yellow
    }

    try {
        $received = @(Receive-Job -Job $Job -ErrorAction Stop)
    } catch {
        if (-not $KeepJob) {
            Remove-Job -Job $Job -Force -ErrorAction SilentlyContinue
        }
        throw "Background IT Glue export job failed while receiving output: $($_.Exception.Message)"
    }

    if ($Job.State -ne 'Completed') {
        $jobErrors = @(
            $Job.ChildJobs |
                ForEach-Object { $_.JobStateInfo.Reason } |
                Where-Object { $_ }
        )
        if (-not $KeepJob) {
            Remove-Job -Job $Job -Force -ErrorAction SilentlyContinue
        }
        $reason = if ($jobErrors.Count -gt 0) { ($jobErrors | Out-String).Trim() } else { "State: $($Job.State)" }
        throw "Background IT Glue export job did not complete successfully. $reason"
    }

    if (-not $KeepJob) {
        Remove-Job -Job $Job -Force -ErrorAction SilentlyContinue
    }

    $bootstrapResult = $received |
        Where-Object { $_ -and $_.PSObject.Properties['ExportPath'] } |
        Select-Object -Last 1

    if (-not $bootstrapResult) {
        throw "Background IT Glue export job completed but did not return an export path."
    }

    return $bootstrapResult
}
