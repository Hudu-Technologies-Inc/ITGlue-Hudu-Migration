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
        [string]$SourceSettingsPath,
        [AllowNull()]$Configuration,
        [AllowNull()]$PreviousRun
    )

    if ($InitType -eq 'Lite' -and $null -ne $PreviousRun) {
        return $PreviousRun
    }

    if ($InitType -eq 'Full') {
        # Full always owns a new directory. Neither launcher paths nor retained
        # session variables can select an old run's output folders.
        $DebugDirectory = Join-Path $ProjectDirectory "debug-$(Get-Date -Format 'yyyyMMdd-HHmmss-fffffff')-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
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
