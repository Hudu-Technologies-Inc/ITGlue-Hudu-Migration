#requires -Version 7.5.1
# Exercise real initialization and entry-point headers, with API/module loading
# and image dependencies replaced by offline stubs in an isolated temp repo.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$sandboxRoot = Join-Path ([IO.Path]::GetTempPath()) "ITGlue-Initialization-Test-$([guid]::NewGuid())"
$checks = 0
function Assert-Initialization {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    $script:checks++
}

function Invoke-InitializationScenario {
    param(
        [string]$EntryPoint = 'Initialize-Module.ps1',
        [ValidateSet('Full', 'Lite')][string]$Mode = 'Full',
        [ValidateSet('Environment', 'Saved', 'LoadedObject', 'LoadedDictionary')][string]$Source = 'Environment',
        [switch]$IncludeIDFalse,
        [switch]$ResumeFalse,
        [switch]$StaleSession
    )
    $caseRoot = Join-Path $sandboxRoot ([guid]::NewGuid().ToString())
    $null = New-Item -ItemType Directory -Path $caseRoot
    $debugFolder = Join-Path $caseRoot 'debug'
    $errorsfolder = Join-Path $debugFolder 'errors'
    $logs_folder = Join-Path $debugFolder 'logs'
    $settings_folder = Join-Path $debugFolder 'settings'
    $defaultSettingsPath = Join-Path $settings_folder 'settings.json'
    $HuduAPIKey = 'h' * 24
    $ITGKey = 'i' * 101
    $fixture = @{
        HuduBaseDomain = 'https://offline.huducloud.com'
        ITGURL = 'https://offline.itglue.com'
        ITGAPIEndpoint = ' https://api.eu.itglue.com/ '
        InternalCompany = 'Offline'
        ITGlueExportPath = (Join-Path $caseRoot 'export')
        MigrationLogs = $logs_folder
        PlaceInternalDocsInInternalCompany = $false
        GlobalKBFolder = 'n'
        ConPromptPrefix = ''
        FAPromptPrefix = ''
        HuduAPIKey = (ConvertTo-SecureString $HuduAPIKey -AsPlainText -Force | ConvertFrom-SecureString)
        ITGKey = (ConvertTo-SecureString $ITGKey -AsPlainText -Force | ConvertFrom-SecureString)
        customBrandedDomain = 'y'
        ITGCustomDomains = 'https://retired.invalid'
    }
    if ($IncludeIDFalse) { $fixture.IncludeITGlueID = $false }
    $settings = $null; $environmentSettings = $null
    $choice = $null; $importChoice = $null; $reenterChoice = $null; $resumeQuestion = $null
    $ResumePrevious = if ($ResumeFalse) { $false } else { $null }
    $FirstTimeLoad = 0
    if ($StaleSession) {
        $choice = 'I'; $importChoice = 'S'
        $ITGAPIEndpoint = 'https://api.au.itglue.com'
        $settingsPath = Join-Path $caseRoot 'previous-instance.json'
    }
    $AutoDownloadITGlueExport = $false
    # Full-only import preferences are supplied so any unexpected question fails.
    $ImportCompanies = $false; $ImportLocations = $false; $ImportDomains = $false
    $ImportConfigurations = $false; $ImportContacts = $false
    $ImportFlexibleAssetLayouts = $false; $ImportFlexibleAssets = $false
    $ImportArticles = $false; $ImportPasswords = $false
    $convertStandalonePhotoArticles = $false; $MergedOrganizationTypes = $false
    $DisableWebsiteMonitoring = $false; $IncludeIgnoredFirstArticleDirectory = $false
    $NonInteractive = $true; $ScopedMigration = $false; $importChecklists = $false
    $importPasswordFolders = $false; $ImportConfigInterfaces = $false; $skipIntegratorLayouts = $false
    if ($Mode -eq 'Lite' -or $EntryPoint -in @('Get-MissingRelations.ps1', 'Add-HuduAttachmentsViaAPI.ps1')) {
        foreach ($name in @('ImportCompanies', 'ImportLocations', 'ImportDomains', 'ImportConfigurations', 'ImportContacts', 'ImportFlexibleAssetLayouts', 'ImportFlexibleAssets', 'ImportArticles', 'ImportPasswords')) {
            Set-Variable -Name $name -Value $null
        }
    }
    $ConImportIcon = 'users'; $LocImportIcon = 'location-dot'; $ConfigImportIcon = 'desktop'
    $script:moduleInitCount = 0
    $script:connectedDomain = $null; $script:connectedKey = $null
    . (Join-Path $sandboxRoot 'Public/Init-OptionsAndLogs.ps1')
    switch ($Source) {
        Environment { $settings = $fixture }
        Saved {
            $null = New-Item -ItemType Directory -Path $settings_folder
            $fixture | ConvertTo-Json | Set-Content -LiteralPath $defaultSettingsPath
            # Neither plaintext keys nor a settings hashtable are needed on import.
            $HuduAPIKey = $null; $ITGKey = $null
        }
        LoadedObject { $environmentSettings = [pscustomobject]$fixture }
        LoadedDictionary { $environmentSettings = $fixture }
    }
    foreach ($pass in 1..2) {
        if ($EntryPoint -eq 'Initialize-Module.ps1') {
            $null = . (Join-Path $sandboxRoot $EntryPoint) -InitType $Mode
        } else {
            $null = . (Join-Path $sandboxRoot $EntryPoint)
        }
        Assert-Initialization ($FirstTimeLoad -eq 1) "$EntryPoint did not mark successful initialization."
        Assert-Initialization ($settings.IncludeITGlueID -eq (-not $IncludeIDFalse)) 'IncludeITGlueID default or explicit false was lost.'
        Assert-Initialization ($environmentSettings.IncludeITGlueID -eq $settings.IncludeITGlueID) 'Settings consumers received inconsistent defaults.'
        Assert-Initialization (-not $settings.ContainsKey('ITGCustomDomains') -and -not $settings.ContainsKey('customBrandedDomain')) 'Retired domains survived settings normalization.'
        Assert-Initialization ($ResumePrevious -eq (-not $ResumeFalse)) 'Resume default or explicit false was lost.'
        Assert-Initialization ($ITGAPIEndpoint -eq 'https://api.eu.itglue.com') 'Endpoint was not normalized.'
        Assert-Initialization ($settings.ITGAPIEndpoint -eq $ITGAPIEndpoint -and $environmentSettings.ITGAPIEndpoint -eq $ITGAPIEndpoint) 'Settings consumers received inconsistent endpoints.'
        if ($StaleSession) {
            Assert-Initialization ($settingsPath -eq $defaultSettingsPath) 'An earlier session redirected settings to the wrong file.'
        }
        Assert-Initialization ($script:connectedDomain -eq $settings.HuduBaseDomain -and $script:connectedKey -ceq ('h' * 24)) 'Module setup did not receive the resolved Hudu connection.'
        Assert-Initialization ($ITGKey -ceq ('i' * 101)) 'Saved ITGlue key did not round-trip.'
        Assert-Initialization ($CurrentVersion -eq [version]'2.48.0') 'Module initialization result was lost.'
        $mapping = Get-HuduNumberFieldMapping @{id='1';attributes=@{kind='Number';name='Monthly cost'}} -ITGAPIEndpoint $ITGAPIEndpoint
        Assert-Initialization ($mapping.LayoutAttributes.currency_code -eq 'EUR' -and $mapping.CurrencyDecimalPlaces -eq 2) 'Regional numeric defaults were not available after initialization.'
    }
    $expectedCalls = if ($EntryPoint -in @('Get-MissingRelations.ps1', 'Add-HuduAttachmentsViaAPI.ps1')) { 1 } else { 2 }
    Assert-Initialization ($script:moduleInitCount -eq $expectedCalls) "$EntryPoint repeated or skipped module initialization."
}

try {
    $null = New-Item -ItemType Directory -Path $sandboxRoot
    $initializer = Get-Content -LiteralPath (Join-Path $repoRoot 'Initialize-Module.ps1') -Raw
    Copy-Item -LiteralPath (Join-Path $repoRoot 'Initialize-Module.ps1') -Destination $sandboxRoot
    # Stub every dot-sourced dependency; restore the helpers under test below.
    foreach ($match in [regex]::Matches($initializer, '\$PSScriptRoot\\([\w\\.-]+\.ps1)')) {
        $dependency = Join-Path $sandboxRoot $match.Groups[1].Value
        $null = New-Item -ItemType Directory -Path (Split-Path $dependency -Parent) -Force
        Set-Content -LiteralPath $dependency -Value ''
    }
    foreach ($relative in @('Private/Initialize-MigrationSettings.ps1', 'Private/ConvertTo-HuduURL.ps1', 'Public/ConvertTo-HuduNumber.ps1')) {
        Copy-Item -LiteralPath (Join-Path $repoRoot $relative) -Destination (Join-Path $sandboxRoot $relative) -Force
    }
    @'
function Get-EnsuredPath {
    param([string]$Path)
    $null = New-Item -ItemType Directory -Path $Path -Force
    return $Path
}
function Read-Host { param($Prompt) throw "Unexpected input prompt: $Prompt" }
function Select-ObjectFromList { param($objects, $message, $allowNull) throw "Unexpected selection prompt: $message" }
function Set-ExternalModulesInitialized {
    param($RequiredHuduVersion, $DisallowedVersions, $HuduBaseURL, $HuduAPIKey)
    $script:moduleInitCount++
    $script:connectedDomain = $HuduBaseURL
    $script:connectedKey = $HuduAPIKey
    return [version]'2.48.0'
}
function Get-ParalellismSettingsInfo { param($MigrationParallelismLimit) return 'Offline module stub' }
'@ | Set-Content -LiteralPath (Join-Path $sandboxRoot 'Public/Init-OptionsAndLogs.ps1')

    # Keep each real entry point through its initialization statement/guard.
    # The migration/API work that follows is deliberately excluded.
    foreach ($name in @('ITGlue-Hudu-Migration.ps1', 'Get-MissingRelations.ps1', 'Add-HuduAttachmentsViaAPI.ps1')) {
        $path = Join-Path $repoRoot $name
        $tokens = $null; $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors)
        $initStatement = $ast.EndBlock.Statements | Where-Object { $_.Extent.Text -like '*Initialize-Module.ps1*' } | Select-Object -First 1
        $sourceText = Get-Content -LiteralPath $path -Raw
        $sourceText.Substring(0, $initStatement.Extent.EndOffset) | Set-Content -LiteralPath (Join-Path $sandboxRoot $name)
    }
    $example = Get-Content -LiteralPath (Join-Path $repoRoot 'environ.example') -Raw
    $example.Replace('ITG.key', ('i' * 101)).Replace('HUDU.key', ('h' * 24)).Replace('https://api.itglue.com', 'https://api.eu.itglue.com').Replace('https://changeme.huducloud.com', 'https://offline.huducloud.com') |
        Set-Content -LiteralPath (Join-Path $sandboxRoot 'environment.ps1')

    Push-Location -LiteralPath $sandboxRoot
    foreach ($mode in @('Full', 'Lite')) {
        foreach ($source in @('Environment', 'Saved', 'LoadedObject', 'LoadedDictionary')) {
            Invoke-InitializationScenario -Mode $mode -Source $source
        }
    }
    Invoke-InitializationScenario -Source Saved -IncludeIDFalse -ResumeFalse
    Invoke-InitializationScenario -Source Environment -IncludeIDFalse -ResumeFalse
    Invoke-InitializationScenario -Source Environment -StaleSession
    Invoke-InitializationScenario -EntryPoint 'ITGlue-Hudu-Migration.ps1' -Source Saved
    Invoke-InitializationScenario -EntryPoint 'environment.ps1'
    foreach ($entry in @('Get-MissingRelations.ps1', 'Add-HuduAttachmentsViaAPI.ps1')) {
        Invoke-InitializationScenario -EntryPoint $entry -Source Saved
        Invoke-InitializationScenario -EntryPoint $entry -Source Environment
    }
    Write-Output "Passed $checks initialization checks (offline; repeated Full/Lite, environment, saved JSON, and companion entry points)."
} finally {
    if ($PWD.Path -eq $sandboxRoot) { Pop-Location }
    # Resolve and verify the exact test-owned temp directory before recursive cleanup.
    $tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
    $resolvedSandbox = [IO.Path]::GetFullPath($sandboxRoot)
    if ((Split-Path $resolvedSandbox -Parent) -eq $tempParent -and (Split-Path $resolvedSandbox -Leaf) -like 'ITGlue-Initialization-Test-*') {
        if (Test-Path -LiteralPath $resolvedSandbox) { Remove-Item -LiteralPath $resolvedSandbox -Recurse -Force }
    } else {
        throw 'Refusing cleanup outside the test-owned temp directory.'
    }
}
