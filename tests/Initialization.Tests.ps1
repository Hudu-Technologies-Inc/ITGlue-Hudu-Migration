#requires -Version 7.5.1
# Exercise real initialization, local helpers, and entry-point headers. Only
# external operations and interactive prompts are stubbed in an isolated repo.
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
        [switch]$StaleSession,
        [switch]$FailModuleLoad
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
    $script:failModuleLoad = [bool]$FailModuleLoad
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
    if ($FailModuleLoad) {
        $failure = $null
        try { $null = . (Join-Path $sandboxRoot 'Initialize-Module.ps1') -InitType $Mode }
        catch { $failure = $_ }
        Assert-Initialization ($null -ne $failure -and $failure.Exception.Message -eq 'Simulated module initialization failure.') 'Expected module failure was not propagated.'
        Assert-Initialization ($FirstTimeLoad -eq 0) 'A helper marked failed initialization as complete.'
        return
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

function Test-RelationHelper {
    # A standalone import must also work before settings or log variables exist.
    . (Join-Path $sandboxRoot 'Public/Add-HuduRelation.ps1')
    Assert-Initialization ($null -eq (Get-Variable -Name FirstTimeLoad -ValueOnly -ErrorAction Ignore)) 'Importing the relation helper changed initialization state.'
    $script:relationCalls = 0
    function New-HuduRelation {
        param($FromableType, $FromableID, $ToableType, $ToableID)
        $script:relationCalls++
        return @{relation=@{Target=$ToableID;Type=$ToableType;From=$FromableID}}
    }
    $request = @{relation_type='Company';itg_to_id=1;hudu_from_id=9}
    Assert-Initialization ($null -eq (Add-HuduRelation $request) -and $script:relationCalls -eq 0) 'Relation lookup failed without a log directory.'
    $FirstTimeLoad = 0
    $MigrationLogs = Join-Path $sandboxRoot 'relation-logs'
    $null = New-Item -ItemType Directory -Path $MigrationLogs
    foreach ($type in @('Company', 'Article', 'AssetPassword')) {
        $request.relation_type = $type
        Assert-Initialization ($null -eq (Add-HuduRelation $request) -and $script:relationCalls -eq 0) 'Missing optional relation logs triggered an API call.'
    }
    @(@{ITGID=1;HuduID=101}) | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $MigrationLogs 'Companies.json')
    @(@{ITGID=2;HuduID=202}) | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $MigrationLogs 'Passwords.json')
    @(@{ITGID=1;HuduID=303}) | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $MigrationLogs 'AssetPasswords.json')
    $request.relation_type = 'Company'
    Assert-Initialization ((Add-HuduRelation $request).Target -eq 101) 'Company relation did not load its existing log.'
    $MatchedCompanies = @(@{ITGID=1;HuduID=404})
    Assert-Initialization ((Add-HuduRelation $request).Target -eq 404) 'A saved relation log overwrote an in-memory match.'
    $request.relation_type = 'AssetPassword'
    Assert-Initialization ((Add-HuduRelation $request).Target -eq 303) 'Flexible-asset password fallback did not load its existing log.'
    $request.itg_to_id = 2
    Assert-Initialization ((Add-HuduRelation $request).Target -eq 202) 'Primary password lookup did not take precedence.'
    # Partial runs may lack Articles.json, while other relation logs exist.
    $request.relation_type = 'Article'
    Assert-Initialization ($null -eq (Add-HuduRelation $request) -and $script:relationCalls -eq 4) 'A partial run with no articles caused a relation request.'
    Assert-Initialization ($FirstTimeLoad -eq 0) 'Relation lookup changed module initialization state.'
}

try {
    $null = New-Item -ItemType Directory -Path $sandboxRoot
    Copy-Item -LiteralPath (Join-Path $repoRoot 'Initialize-Module.ps1') -Destination $sandboxRoot
    foreach ($directory in @('Private', 'Public')) {
        Copy-Item -LiteralPath (Join-Path $repoRoot $directory) -Destination $sandboxRoot -Recurse
    }
    Set-Content -LiteralPath (Join-Path $sandboxRoot 'Private/Initialize-ImageMagik.ps1') -Value ''
    @'
function Get-EnsuredPath {
    param([string]$Path)
    $null = New-Item -ItemType Directory -Path $Path -Force
    return $Path
}
function Read-Host { param($Prompt) throw "Unexpected input prompt: $Prompt" }
function Select-ObjectFromList { param($objects, $message, $allowNull) throw "Unexpected selection prompt: $message" }
function Invoke-WebRequest { throw 'Unexpected web request during offline initialization.' }
function Invoke-RestMethod { throw 'Unexpected API request during offline initialization.' }
function Set-ExternalModulesInitialized {
    param($RequiredHuduVersion, $DisallowedVersions, $HuduBaseURL, $HuduAPIKey)
    $script:moduleInitCount++
    if ($script:failModuleLoad) { throw 'Simulated module initialization failure.' }
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
    Test-RelationHelper
    foreach ($mode in @('Full', 'Lite')) {
        foreach ($source in @('Environment', 'Saved', 'LoadedObject', 'LoadedDictionary')) {
            Invoke-InitializationScenario -Mode $mode -Source $source
        }
    }
    Invoke-InitializationScenario -Source Saved -IncludeIDFalse -ResumeFalse
    Invoke-InitializationScenario -Source Environment -IncludeIDFalse -ResumeFalse
    Invoke-InitializationScenario -Source Environment -StaleSession
    Invoke-InitializationScenario -Mode Full -FailModuleLoad
    Invoke-InitializationScenario -Mode Lite -FailModuleLoad
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
