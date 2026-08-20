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

function Get-ITGlueExport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ITGKey,

        [Parameter(Mandatory = $true)]
        [string]$ITGBaseURI
    )

    $headers = @{
        'x-api-key'    = $ITGKey
        'Content-Type' = 'application/vnd.api+json'
        'Accept'       = 'application/vnd.api+json'
    }

    Invoke-RestMethod -Uri "$($ITGBaseURI.TrimEnd('/'))/exports" -Method GET -Headers $headers -ErrorAction Stop
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

        [Parameter(Mandatory = $true)]
        [string]$ITGBaseURI
    )

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

        [Parameter(Mandatory = $true)]
        [string]$ITGBaseURI
    )

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

        [Parameter(Mandatory = $true)]
        [string]$ITGBaseURI
    )

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

        if ($PSCmdlet.ShouldProcess("IT Glue export $exportId", 'Delete before queuing a new encrypted export')) {
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

        [Parameter(Mandatory = $true)]
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

        [Int64[]]$FlexibleAssetTypeIDs = @()
    )

    if ($AllFlexibleAssets -and $FlexibleAssetTypeIDs.Count -gt 0) {
        throw "Use either -AllFlexibleAssets `$true or -FlexibleAssetTypeIDs, not both."
    }

    $headers = @{
        'x-api-key'    = $ITGKey
        'Content-Type' = 'application/vnd.api+json'
        'Accept'       = 'application/vnd.api+json'
    }

    $attributes = [ordered]@{
        'include-logs'        = $IncludeLogs
        'core-assets-types'   = $CoreAssetTypes
        'all-flexible-assets' = $AllFlexibleAssets
        'include-passwords'   = $true
    }

    if ($null -ne $OrganizationID) {
        $attributes['organization-id'] = [Int64]$OrganizationID
    }

    if (-not [string]::IsNullOrWhiteSpace($ZipPassword)) {
        $attributes['zip-password'] = $ZipPassword
    }

    if (-not $AllFlexibleAssets -and $FlexibleAssetTypeIDs.Count -gt 0) {
        $attributes['flexible-assets-types'] = @($FlexibleAssetTypeIDs)
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

    Invoke-RestMethod -Uri "$($ITGBaseURI.TrimEnd('/'))/exports" -Method POST -Headers $headers -Body $body -ErrorAction Stop
}

function Wait-ITGlueExport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ITGKey,

        [Parameter(Mandatory = $true)]
        [string]$ITGBaseURI,

        [AllowNull()]
        [Nullable[Int64]]$ExportID = $null,

        [ValidateRange(5, 3600)]
        [int]$PollSeconds = 60,

        [ValidateRange(1, 1440)]
        [int]$TimeoutMinutes = 240
    )

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)

    while ((Get-Date) -lt $deadline) {
        $export = if ($null -ne $ExportID) {
            Get-ITGlueExportById -ITGKey $ITGKey -ITGBaseURI $ITGBaseURI -ExportID $ExportID
        } else {
            Get-ITGlueExport -ITGKey $ITGKey -ITGBaseURI $ITGBaseURI
        }

        $downloadUrl = Get-ITGlueExportDownloadUrl -Export $export
        if (-not [string]::IsNullOrWhiteSpace([string]$downloadUrl)) {
            return [pscustomobject]@{
                Export      = $export
                DownloadUrl = $downloadUrl
            }
        }

        $status = $export.data.attributes.status ?? $export.data.attributes.'export-status' ?? $export.data.attributes.state
        $statusText = if ($status) { " Current status: $status." } else { "" }
        Write-Host "IT Glue export is not ready yet.$statusText Checking again in $PollSeconds seconds." -ForegroundColor Yellow
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

        [Parameter(Mandatory = $true)]
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
        [int]$TimeoutMinutes = 240
    )

    if ([string]::IsNullOrWhiteSpace($ExportPath)) {
        throw "IT Glue export path is blank."
    }

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

    Write-Host "No extracted IT Glue export content was found at $ExportPath. Starting a full-tenant export." -ForegroundColor Yellow
    $startedExport = $null
    $exportId = $null
    $usedExistingExport = $false
    $clearedExportIds = @()

    if ($true -eq $ClearExistingExports) {
        Write-Host "Clearing existing IT Glue exports before queueing a new encrypted export." -ForegroundColor Yellow
        $clearedExportIds = @(Clear-ITGlueExports -ITGKey $ITGKey -ITGBaseURI $ITGBaseURI)
    } else {
        Write-Host "Existing IT Glue exports will not be cleared before queueing. A duplicate export response may reuse an existing download." -ForegroundColor Yellow
    }

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            $startedExport = Start-ITGlueExport -ITGKey $ITGKey -ITGBaseURI $ITGBaseURI -ZipPassword $ZipPassword -IncludeLogs $IncludeLogs
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
                Write-Host "IT Glue reports a matching export is already available. Reusing the existing export download." -ForegroundColor Yellow
                break
            }

            if ($attempt -ge 3) {
                throw "IT Glue still reports a matching export is already available after clearing existing exports. Wait a few minutes and retry, or set ITGlueExportClearExistingExports to `$false only if you know the existing export password matches this run."
            }

            Write-Warning "IT Glue still reports a matching export after cleanup. Waiting 15 seconds, clearing again, and retrying export queue attempt $($attempt + 1) of 3."
            Start-Sleep -Seconds 15
            $clearedExportIds += @(Clear-ITGlueExports -ITGKey $ITGKey -ITGBaseURI $ITGBaseURI)
        }
    }

    $readyExport = Wait-ITGlueExport -ITGKey $ITGKey -ITGBaseURI $ITGBaseURI -ExportID $exportId -PollSeconds $PollSeconds -TimeoutMinutes $TimeoutMinutes
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
    while ($Job.State -in @('NotStarted', 'Running')) {
        $completedJob = Wait-Job -Job $Job -Timeout $StatusSeconds
        if ($completedJob) {
            break
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
