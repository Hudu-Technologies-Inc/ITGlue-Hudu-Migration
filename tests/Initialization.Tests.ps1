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
        [ValidateSet('Environment', 'Saved', 'CustomSaved', 'Interactive', 'LoadedObject', 'LoadedDictionary')][string]$Source = 'Environment',
        [switch]$IncludeIDFalse,
        [switch]$ResumeFalse,
        [switch]$StaleSession,
        [switch]$FailModuleLoad,
        [switch]$SwitchConfiguration,
        [switch]$StandaloneLite,
        [switch]$PassThru
    )
    $caseRoot = Join-Path $sandboxRoot ([guid]::NewGuid().ToString())
    $null = New-Item -ItemType Directory -Path $caseRoot
    $script:MigrationRunContext = $null
    $script:testSettingsImportPath = $null
    $script:testReadAnswers = @{}
    $script:testSelectAnswers = @{}
    $project_workdir = $caseRoot
    $debugFolder = Join-Path $caseRoot 'debug'
    $errorsfolder = Join-Path $debugFolder 'errors'
    $errors_folder = $null
    $logs_folder = Join-Path $debugFolder 'logs'
    $settings_folder = Join-Path $debugFolder 'settings'
    $defaultSettingsPath = Join-Path $settings_folder 'settings.json'
    $HuduAPIKey = 'h' * 24
    $ITGKey = 'i' * 101
    $expectedHuduKey = $HuduAPIKey; $expectedITGKey = $ITGKey
    $expectedCurrency = 'EUR'
    $fixture = @{
        HuduBaseDomain = 'https://offline.huducloud.com'
        ITGURL = 'https://offline.itglue.com'
        ITGAPIEndpoint = ' https://api.eu.itglue.com/ '
        InternalCompany = 'Offline'
        ITGlueExportPath = (Join-Path $sandboxRoot 'export')
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
    $settingsPath = $null
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
        $AutoDownloadITGlueExport = $true # Lite must not start an export, even with the default enabled.
        foreach ($name in @('ImportCompanies', 'ImportLocations', 'ImportDomains', 'ImportConfigurations', 'ImportContacts', 'ImportFlexibleAssetLayouts', 'ImportFlexibleAssets', 'ImportArticles', 'ImportPasswords')) {
            Set-Variable -Name $name -Value $null
        }
    }
    $ConImportIcon = 'users'; $LocImportIcon = 'location-dot'; $ConfigImportIcon = 'desktop'
    $script:moduleInitCount = 0
    $script:failModuleLoad = [bool]$FailModuleLoad
    $script:connectedDomain = $null; $script:connectedKey = $null
    . (Join-Path $sandboxRoot 'Public/Init-OptionsAndLogs.ps1')
    $sourceFiles = @()
    switch ($Source) {
        Environment { $settings = $fixture }
        Saved {
            $null = New-Item -ItemType Directory -Path $settings_folder
            $fixture | ConvertTo-Json | Set-Content -LiteralPath $defaultSettingsPath
            $sourceFiles += @{Path=$defaultSettingsPath;Text=(Get-Content -LiteralPath $defaultSettingsPath -Raw)}
            # Neither plaintext keys nor a settings hashtable are needed on import.
            $HuduAPIKey = $null; $ITGKey = $null
        }
        CustomSaved {
            $null = New-Item -ItemType Directory -Path $settings_folder
            $fixture | ConvertTo-Json | Set-Content -LiteralPath $defaultSettingsPath
            $sourceFiles += @{Path=$defaultSettingsPath;Text=(Get-Content -LiteralPath $defaultSettingsPath -Raw)}
            $customFile = Join-Path $caseRoot 'custom-input.json'
            $fixture | ConvertTo-Json | Set-Content -LiteralPath $customFile
            $sourceFiles += @{Path=$customFile;Text=(Get-Content -LiteralPath $customFile -Raw)}
            $script:testSettingsImportPath = $customFile
            $choice = 'I'; $importChoice = 'S'
            $HuduAPIKey = $null; $ITGKey = $null
        }
        Interactive {
            $HuduAPIKey = $null; $ITGKey = $null
            $script:testReadAnswers = @{
                '*Set the base domain*' = $fixture.HuduBaseDomain
                '*Set the domain of your ITGlue*' = $fixture.ITGURL
                '*Get a Hudu API Key*' = ('h' * 24)
                '*Enter your ITGlue API Key*' = ('i' * 101)
                '*exact name of the ITGlue Organization*' = $fixture.InternalCompany
                '*Prefix*Configuration*' = ''
                '*Prefix*Asset Layout*' = ''
                '*path of the ITGlue Export*' = $fixture.ITGlueExportPath
            }
            $script:testSelectAnswers = @{
                '*ITGlue API Endpoint*' = 'https://api.eu.itglue.com'
                '*documents from your Internal Company*' = $false
                '*documents in Global KB*' = 'n'
            }
        }
        LoadedObject { $environmentSettings = [pscustomobject]$fixture }
        LoadedDictionary { $environmentSettings = $fixture }
    }
    if ($StandaloneLite) {
        $settingsPath = $defaultSettingsPath
        $defaultSettingsPath = $null
        $debugFolder = $null; $errorsfolder = $null; $errors_folder = $null
        $settings_folder = $null; $logs_folder = $null
    }
    if ($EntryPoint -in @('environment.ps1', 'gui-environment.ps1')) {
        $example = Get-Content -LiteralPath (Join-Path $repoRoot 'environ.example') -Raw
        $example = $example.Replace('ITG.key', ('i' * 101)).Replace('HUDU.key', ('h' * 24)).Replace('https://api.itglue.com', 'https://api.eu.itglue.com').Replace('https://changeme.huducloud.com', $fixture.HuduBaseDomain).Replace('https://changeme.itglue.com', $fixture.ITGURL).Replace('changeme inc.', $fixture.InternalCompany).Replace('c:\tmp\export', $fixture.ITGlueExportPath)
        if ($EntryPoint -eq 'gui-environment.ps1') {
            # Contract inspected in the executable's embedded Python launcher:
            # it generates the same template, using errors_folder and old controls.
            $example = $example.Replace('$errorsfolder', '$errors_folder')
            $example = '$resumeQuestion="yes"; $reenterChoice="Continue"; $choice="N";' + "`n" + $example
            $example = $example.Replace('. "$PSScriptRoot\ITGlue-Hudu-Migration.ps1"', '$guiSettingsDir=$settings_folder; . "$PSScriptRoot\ITGlue-Hudu-Migration.ps1"')
        }
        $preparedCapture = '$script:testPreparedPaths=@{Debug=$debugFolder;Errors=$script:GLOBAL_ERRORS_DIRECTORY;Settings=$settings_folder;Logs=$logs_folder;File=$defaultSettingsPath}; '
        $example = $example.Replace('. "$PSScriptRoot\ITGlue-Hudu-Migration.ps1"', $preparedCapture + '. "$PSScriptRoot\ITGlue-Hudu-Migration.ps1"')
        $example | Set-Content -LiteralPath (Join-Path $sandboxRoot $EntryPoint)
    }
    if ($FailModuleLoad) {
        $failure = $null
        try { $null = . (Join-Path $sandboxRoot 'Initialize-Module.ps1') -InitType $Mode }
        catch { $failure = $_ }
        Assert-Initialization ($null -ne $failure -and $failure.Exception.Message -eq 'Simulated module initialization failure.') 'Expected module failure was not propagated.'
        Assert-Initialization ($FirstTimeLoad -eq 0) 'A helper marked failed initialization as complete.'
        return
    }
    $priorFolder = $null
    $isLite = $Mode -eq 'Lite' -or $EntryPoint -in @('Get-MissingRelations.ps1', 'Add-HuduAttachmentsViaAPI.ps1')
    foreach ($pass in 1..2) {
        $MatchedAssets = @(@{ITGID='old-tenant';HuduID=999})
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
        Assert-Initialization ($ITGAPIEndpoint -eq $fixture.ITGAPIEndpoint.Trim().TrimEnd('/')) 'Endpoint was not normalized or came from an old configuration.'
        Assert-Initialization ($settings.ITGAPIEndpoint -eq $ITGAPIEndpoint -and $environmentSettings.ITGAPIEndpoint -eq $ITGAPIEndpoint) 'Settings consumers received inconsistent endpoints.'
        Assert-Initialization ($settingsPath -eq (Join-Path $settings_folder 'settings.json') -or $isLite) 'Full init did not select the run-owned settings file.'
        Assert-Initialization ($settings.MigrationLogs -eq $logs_folder -and $environmentSettings.MigrationLogs -eq $logs_folder) 'The selected run and effective log paths disagree.'
        if ($priorFolder) {
            Assert-Initialization (($debugFolder -eq $priorFolder) -eq $isLite) 'Full did not start fresh or Lite did not reuse the active run.'
        }
        if (-not $isLite) {
            Assert-Initialization ($null -eq $MatchedAssets -and $ResumeFound -eq $false) 'Fresh initialization retained old matches or resume state.'
            foreach ($file in $sourceFiles) {
                Assert-Initialization ((Get-Content -LiteralPath $file.Path -Raw) -ceq $file.Text) "Full initialization ($EntryPoint/$Mode/$Source pass $pass) overwrote input $($file.Path); active file: $settingsPath."
            }
            if ($EntryPoint -in @('environment.ps1', 'gui-environment.ps1')) {
                $prepared = $script:testPreparedPaths
                Assert-Initialization ($debugFolder -eq $prepared.Debug -and $errorsfolder -eq $prepared.Errors -and $settings_folder -eq $prepared.Settings -and $MigrationLogs -eq $prepared.Logs -and $settingsPath -eq $prepared.File) 'Initialization replaced fresh folders supplied by the launcher.'
            }
        } else {
            Assert-Initialization ($MatchedAssets[0].ITGID -eq 'old-tenant') 'Lite initialization discarded existing migration matches.'
        }
        $priorFolder = $debugFolder
        if ($StaleSession) {
            Assert-Initialization ($settingsPath -eq $defaultSettingsPath) 'An earlier session redirected settings to the wrong file.'
        }
        Assert-Initialization ($script:connectedDomain -eq $fixture.HuduBaseDomain -and $script:connectedKey -ceq $expectedHuduKey) 'Module setup did not receive the selected Hudu connection.'
        Assert-Initialization ($ITGKey -ceq $expectedITGKey -and $ITGURL -eq $fixture.ITGURL) 'Saved ITGlue credentials or URL came from an old configuration.'
        Assert-Initialization ($CurrentVersion -eq [version]'2.48.0') 'Module initialization result was lost.'
        $mapping = Get-HuduNumberFieldMapping @{id='1';attributes=@{kind='Number';name='Monthly cost'}} -ITGAPIEndpoint $ITGAPIEndpoint
        Assert-Initialization ($mapping.LayoutAttributes.currency_code -eq $expectedCurrency -and $mapping.CurrencyDecimalPlaces -eq 2) 'Regional numeric defaults were not available after initialization.'
        if ($SwitchConfiguration -and $pass -eq 1) {
            $fixture.HuduBaseDomain = 'https://other-target.huducloud.com'
            $fixture.ITGURL = 'https://other-source.itglue.com'
            $fixture.ITGAPIEndpoint = 'https://api.au.itglue.com'
            $expectedHuduKey = 'j' * 24; $expectedITGKey = 'k' * 101; $expectedCurrency = 'AUD'
            $fixture.HuduAPIKey = ConvertTo-SecureString $expectedHuduKey -AsPlainText -Force | ConvertFrom-SecureString
            $fixture.ITGKey = ConvertTo-SecureString $expectedITGKey -AsPlainText -Force | ConvertFrom-SecureString
            $settingsPath = Join-Path $caseRoot 'other-tenant-input.json'
            $fixture | ConvertTo-Json | Set-Content -LiteralPath $settingsPath
            $sourceFiles += @{Path=$settingsPath;Text=(Get-Content -LiteralPath $settingsPath -Raw)}
        }
    }
    $expectedCalls = if ($EntryPoint -in @('Get-MissingRelations.ps1', 'Add-HuduAttachmentsViaAPI.ps1')) { 1 } else { 2 }
    Assert-Initialization ($script:moduleInitCount -eq $expectedCalls) "$EntryPoint repeated or skipped module initialization."
    # Full-to-Lite handoff must keep the exact run, even with stale defaults present.
    if (-not $isLite) {
        $activePath = $settingsPath
        $activeLogs = $MigrationLogs
        $null = . (Join-Path $sandboxRoot 'Initialize-Module.ps1') -InitType Lite
        Assert-Initialization ($settingsPath -eq $activePath -and $MigrationLogs -eq $activeLogs -and $debugFolder -eq $priorFolder) 'Lite initialization switched away from the completed Full run.'
    }
    if ($PassThru) {
        return @{HuduBaseDomain=$HuduBaseDomain;ITGURL=$ITGURL;Endpoint=$ITGAPIEndpoint;InternalCompany=$InternalCompany;IncludeITGlueID=$settings.IncludeITGlueID;GlobalKBFolder=$GlobalKBFolder;ConfigurationPrefix=$settings.ConPromptPrefix;FlexiblePrefix=$settings.FAPromptPrefix;ExportPath=$ITGlueExportPath;HuduKey=$HuduAPIKey;ITGKey=$ITGKey}
    }
}

function Test-RunFolderSelection {
    . (Join-Path $sandboxRoot 'Private/Initialize-MigrationSettings.ps1')
    $root = Join-Path $sandboxRoot 'occupied-run'
    $logs = Join-Path $root 'logs'
    $null = New-Item -ItemType Directory -Path $logs
    $oldLog = Join-Path $logs 'Assets.json'
    '[{"ITGID":1}]' | Set-Content -LiteralPath $oldLog
    $configuration = @{MigrationLogs=$logs}
    $argsForRun = @{ProjectDirectory=$sandboxRoot;DebugDirectory=$root;LogsDirectory=$logs;Configuration=$configuration}
    $full = New-MigrationRunContext -InitType Full @argsForRun
    Assert-Initialization ($full.DebugFolder -ne $root -and $full.LogsFolder -ne $logs) 'Full initialization reused a folder containing old migration checkpoints.'
    Assert-Initialization ((Get-Content -LiteralPath $oldLog -Raw).Trim() -ceq '[{"ITGID":1}]') 'Full initialization modified an existing checkpoint.'
    $lite = New-MigrationRunContext -InitType Lite -SourceSettingsPath (Join-Path $root 'settings/settings.json') @argsForRun
    Assert-Initialization ($lite.DebugFolder -eq $root -and $lite.LogsFolder -eq $logs) 'Lite initialization moved an existing run to a new folder.'
    $freshLogs = Join-Path $sandboxRoot 'fresh-logs'
    $null = New-Item -ItemType Directory -Path $freshLogs
    '{}' | Set-Content -LiteralPath (Join-Path $freshLogs 'export-bootstrap.json')
    Assert-Initialization (-not (Test-MigrationRunLogs $freshLogs)) 'Export metadata was treated as a previous migration.'
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
function Read-Host {
    param($Prompt)
    if ($script:testSettingsImportPath -and $Prompt -like '*settings.json*') { return $script:testSettingsImportPath }
    foreach ($pattern in $script:testReadAnswers.Keys) { if ($Prompt -like $pattern) { return $script:testReadAnswers[$pattern] } }
    throw "Unexpected input prompt: $Prompt"
}
function Select-ObjectFromList {
    param($objects, $message, $allowNull)
    foreach ($pattern in $script:testSelectAnswers.Keys) { if ($message -like $pattern) { return $script:testSelectAnswers[$pattern] } }
    throw "Unexpected selection prompt: $message"
}
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
        $prefix = $sourceText.Substring(0, $initStatement.Extent.EndOffset)
        if ($name -eq 'ITGlue-Hudu-Migration.ps1') {
            $resumeBlock = $ast.EndBlock.Statements | Where-Object { $_.Extent.Text -like '*No previous runs found creating log directory*' } | Select-Object -First 1
            $prefix += "`n" + $resumeBlock.Extent.Text
        }
        $prefix | Set-Content -LiteralPath (Join-Path $sandboxRoot $name)
    }
    $example = Get-Content -LiteralPath (Join-Path $repoRoot 'environ.example') -Raw
    $example.Replace('ITG.key', ('i' * 101)).Replace('HUDU.key', ('h' * 24)).Replace('https://api.itglue.com', 'https://api.eu.itglue.com').Replace('https://changeme.huducloud.com', 'https://offline.huducloud.com') |
        Set-Content -LiteralPath (Join-Path $sandboxRoot 'environment.ps1')

    Push-Location -LiteralPath $sandboxRoot
    Test-RunFolderSelection
    Test-RelationHelper
    foreach ($mode in @('Full', 'Lite')) {
        foreach ($source in @('Environment', 'Saved', 'LoadedObject', 'LoadedDictionary')) {
            Invoke-InitializationScenario -Mode $mode -Source $source
        }
    }
    Invoke-InitializationScenario -Source Saved -IncludeIDFalse -ResumeFalse
    Invoke-InitializationScenario -Source Environment -IncludeIDFalse -ResumeFalse
    Invoke-InitializationScenario -Source Environment -StaleSession
    Invoke-InitializationScenario -Source CustomSaved
    Invoke-InitializationScenario -SwitchConfiguration
    Invoke-InitializationScenario -Mode Full -FailModuleLoad
    Invoke-InitializationScenario -Mode Lite -FailModuleLoad
    Invoke-InitializationScenario -EntryPoint 'ITGlue-Hudu-Migration.ps1' -Source Saved
    Invoke-InitializationScenario -EntryPoint 'environment.ps1'
    $launchResults = @(
        (Invoke-InitializationScenario -EntryPoint 'ITGlue-Hudu-Migration.ps1' -Source Interactive -PassThru),
        (Invoke-InitializationScenario -EntryPoint 'environment.ps1' -PassThru),
        (Invoke-InitializationScenario -EntryPoint 'gui-environment.ps1' -PassThru)
    )
    foreach ($key in $launchResults[0].Keys) {
        Assert-Initialization ($launchResults[0][$key] -ceq $launchResults[1][$key] -and $launchResults[0][$key] -ceq $launchResults[2][$key]) "Launch methods produced different effective settings: $key"
    }
    foreach ($entry in @('Get-MissingRelations.ps1', 'Add-HuduAttachmentsViaAPI.ps1')) {
        Invoke-InitializationScenario -EntryPoint $entry -Source Saved
        Invoke-InitializationScenario -EntryPoint $entry -Source Environment
        Invoke-InitializationScenario -EntryPoint $entry -Source Saved -StandaloneLite
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
