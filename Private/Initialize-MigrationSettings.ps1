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

function New-MigrationRunContext {
    param(
        [ValidateSet('Full', 'Lite')][string]$InitType,
        [string]$ProjectDirectory,
        [string]$DebugDirectory,
        [string]$ErrorsDirectory,
        [string]$SettingsDirectory,
        [string]$LogsDirectory,
        [string]$SourceSettingsPath,
        [AllowNull()]$Configuration,
        [AllowNull()]$PreviousRun
    )

    if ($InitType -eq 'Lite' -and $null -ne $PreviousRun) {
        return $PreviousRun
    }

    if ($InitType -eq 'Full') {
        # The launcher may already have prepared a fresh folder. Paths retained
        # from our previous initialization are runtime state, not new input.
        $preparedFolder = -not [string]::IsNullOrWhiteSpace($DebugDirectory) -and
            ($null -eq $PreviousRun -or $DebugDirectory -ne $PreviousRun.DebugFolder)
        if ($preparedFolder) {
            $candidateLogs = if ($LogsDirectory) { $LogsDirectory } else { Join-Path $DebugDirectory 'logs' }
            if (Test-MigrationRunLogs $candidateLogs) { $preparedFolder = $false }
        }
        if ($preparedFolder -and $SourceSettingsPath) {
            $candidateFolder = if ($SettingsDirectory) { $SettingsDirectory } else { Join-Path $DebugDirectory 'settings' }
            $candidateFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath((Join-Path $candidateFolder 'settings.json'))
            $sourceFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($SourceSettingsPath)
            if ($candidateFile -eq $sourceFile -or (Test-Path -LiteralPath $candidateFile)) { $preparedFolder = $false }
        }
        if (-not $preparedFolder) {
            $DebugDirectory = Join-Path $ProjectDirectory "debug-$(Get-Date -Format 'yyyyMMdd-HHmmss-fffffff')-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
        }
        $paths = @{
            ErrorsFolder = @{Value=$ErrorsDirectory; Child='errors'}
            SettingsFolder = @{Value=$SettingsDirectory; Child='settings'}
            LogsFolder = @{Value=$LogsDirectory; Child='logs'}
        }
        foreach ($name in @($paths.Keys)) {
            $value = $paths[$name].Value
            if (-not $preparedFolder -or [string]::IsNullOrWhiteSpace($value) -or
                ($null -ne $PreviousRun -and $value -eq $PreviousRun.$name)) {
                $value = Join-Path $DebugDirectory $paths[$name].Child
            }
            $paths[$name] = $value
        }
    } else {
        # A standalone Lite launch attaches to the selected saved run.
        if ($Configuration.MigrationLogs) { $LogsDirectory = $Configuration.MigrationLogs }
        if ($SourceSettingsPath) { $SettingsDirectory = Split-Path $SourceSettingsPath -Parent }
        if ([string]::IsNullOrWhiteSpace($DebugDirectory)) {
            $DebugDirectory = if ($LogsDirectory) { Split-Path $LogsDirectory -Parent } else { Split-Path $SettingsDirectory -Parent }
        }
        if ([string]::IsNullOrWhiteSpace($DebugDirectory)) { throw 'Lite initialization needs an existing run or saved settings file.' }
        $paths = @{
            ErrorsFolder = $(if ($ErrorsDirectory) { $ErrorsDirectory } else { Join-Path $DebugDirectory 'errors' })
            SettingsFolder = $(if ($SettingsDirectory) { $SettingsDirectory } else { Join-Path $DebugDirectory 'settings' })
            LogsFolder = $(if ($LogsDirectory) { $LogsDirectory } else { Join-Path $DebugDirectory 'logs' })
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
