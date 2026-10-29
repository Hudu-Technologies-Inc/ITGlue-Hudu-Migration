function Initialize-MigrationSettings {
    param([AllowNull()]$Settings)

    if ($null -eq $Settings) { $Settings = @{} }
    # Old environment files and saved JSON can still contain retired CNAME settings.
    foreach ($name in @('customBrandedDomain', 'ITGCustomDomains')) {
        if ($Settings -is [System.Collections.IDictionary]) {
            [void]$Settings.Remove($name)
        } else {
            $Settings.PSObject.Properties.Remove($name)
        }
    }
    if ($Settings -is [System.Collections.IDictionary]) {
        if ($null -eq $Settings['IncludeITGlueID']) {
            $Settings['IncludeITGlueID'] = $true
        }
    } else {
        $property = $Settings.PSObject.Properties['IncludeITGlueID']
        if ($null -eq $property -or $null -eq $property.Value) {
            $Settings | Add-Member -MemberType NoteProperty -Name IncludeITGlueID -Value $true -Force
        }
    }
    return $Settings
}

function Copy-MigrationSettings {
    param([AllowNull()]$Settings)
    $copy = @{}
    if ($Settings -is [System.Collections.IDictionary]) {
        foreach ($key in $Settings.Keys) { $copy[$key] = $Settings[$key] }
    } elseif ($null -ne $Settings) {
        foreach ($property in $Settings.PSObject.Properties) { $copy[$property.Name] = $property.Value }
    }
    return Initialize-MigrationSettings -Settings $copy
}

function Test-MigrationRunLogs {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    foreach ($name in @('Companies', 'Locations', 'Websites', 'Configurations', 'Contacts', 'AssetLayouts', 'AssetLayoutsFields', 'Assets', 'ArticleBase', 'Articles', 'Passwords')) {
        if (Test-Path -LiteralPath (Join-Path $Path "$name.json") -PathType Leaf) { return $true }
    }
    return $false
}

function Assert-MigrationRunFolderAvailable {
    param([string]$Path, [switch]$ClaimCreated)

    if (-not (Test-Path -LiteralPath $Path -ErrorAction Stop)) { return }
    $root = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (-not $root.PSIsContainer -or ($root.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Debug folder must be a regular directory: $Path"
    }
    # The GUI may have already created these empty directories. No files,
    # links, or other directories may be adopted by a new Full run.
    $allowedDirectories = @('errors', 'errors/itglue', 'settings', 'logs') | ForEach-Object { Join-Path $Path $_ }
    $claimPath = Join-Path $Path '.hudu-migration-run.json'
    Get-ChildItem -LiteralPath $Path -Force -Recurse -ErrorAction Stop | ForEach-Object {
        if ($ClaimCreated -and $_.FullName -eq $claimPath -and -not $_.PSIsContainer) { return }
        if (-not $_.PSIsContainer -or ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $_.FullName -notin $allowedDirectories) {
            throw "Debug folder is already claimed or contains existing data: $Path. Choose a new debug folder; use Lite with -SettingsFile for an existing run."
        }
    }
}

function New-MigrationRunFolderClaim {
    param([string]$Path)

    Assert-MigrationRunFolderAvailable -Path $Path
    $null = [IO.Directory]::CreateDirectory($Path)
    $claimPath = Join-Path $Path '.hudu-migration-run.json'
    $claim = $null
    try {
        # CreateNew is the claim: the filesystem permits only one creator,
        # including when independent PowerShell processes race for this path.
        $claim = [IO.File]::Open($claimPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $metadata = @{
            RunId = [guid]::NewGuid().ToString('N')
            ProcessId = $PID
            CreatedUtc = [datetime]::UtcNow.ToString('o')
        } | ConvertTo-Json
        $bytes = [Text.Encoding]::UTF8.GetBytes($metadata)
        $claim.Write($bytes, 0, $bytes.Length)
    } catch {
        throw "Could not claim debug folder '$Path'. It may already belong to another run or be inaccessible. Choose a new debug folder. $($_.Exception.Message)"
    } finally {
        if ($null -ne $claim) { $claim.Dispose() }
    }
    # Recheck after claiming to catch changes between the first check and claim.
    # Keep the marker after failure, interruption, and completion: it is a
    # permanent ownership record, not a lock to remove when a process exits.
    Assert-MigrationRunFolderAvailable -Path $Path -ClaimCreated
}

function New-MigrationRunContext {
    param(
        [ValidateSet('Full', 'Lite')][string]$InitType,
        [string]$ProjectDirectory,
        [string]$RequestedDebugFolder,
        [string]$SourceSettingsPath,
        [AllowNull()]$Configuration,
        [AllowNull()]$PreviousRun
    )

    if ($InitType -eq 'Lite' -and $null -ne $PreviousRun) {
        return $PreviousRun
    }

    if ($InitType -eq 'Full') {
        if (-not [string]::IsNullOrWhiteSpace($RequestedDebugFolder)) {
            if (-not [IO.Path]::IsPathFullyQualified($RequestedDebugFolder)) {
                throw 'debugFolder must be an absolute filesystem path (for example C:\Migrations\debug-acme).'
            }
            $DebugDirectory = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($RequestedDebugFolder))
            if ($DebugDirectory -eq [IO.Path]::GetPathRoot($DebugDirectory)) {
                throw 'debugFolder must be a dedicated run directory, not a drive or share root.'
            }
        } else {
            $DebugDirectory = [IO.Path]::GetFullPath((Join-Path $ProjectDirectory "debug-$(Get-Date -Format 'yyyyMMdd-HHmmss-fffffff')-$([guid]::NewGuid().ToString('N').Substring(0, 8))"))
        }
        New-MigrationRunFolderClaim -Path $DebugDirectory
        $paths = @{
            ErrorsFolder = Join-Path $DebugDirectory 'errors'
            SettingsFolder = Join-Path $DebugDirectory 'settings'
            LogsFolder = Join-Path $DebugDirectory 'logs'
        }
    } else {
        if (-not $SourceSettingsPath -or -not $Configuration.MigrationLogs) {
            throw 'Lite initialization requires an active run or an explicitly selected settings file containing MigrationLogs.'
        }
        $LogsDirectory = $Configuration.MigrationLogs
        $DebugDirectory = Split-Path $LogsDirectory -Parent
        if (-not $DebugDirectory) { throw 'The selected settings file has an invalid MigrationLogs path.' }
        $paths = @{
            ErrorsFolder = Join-Path $DebugDirectory 'errors'
            SettingsFolder = Split-Path $SourceSettingsPath -Parent
            LogsFolder = $LogsDirectory
        }
    }
    $settingsFile = if ($InitType -eq 'Lite' -and $SourceSettingsPath) { $SourceSettingsPath } else { Join-Path $paths.SettingsFolder 'settings.json' }
    return [pscustomobject]@{
        DebugFolder = $DebugDirectory
        ErrorsFolder = $paths.ErrorsFolder
        SettingsFolder = $paths.SettingsFolder
        LogsFolder = $paths.LogsFolder
        SettingsPath = $settingsFile
        SourceSettingsPath = $SourceSettingsPath
        Settings = $null
        SettingsAlias = $null
    }
}
