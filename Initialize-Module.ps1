# This file is used for setting the migration settings.
#
# Please Read the blog post at https://mspp.io/automated-it-glue-to-hudu-migration-script/ before running this script
# Version 2.0.0-beta
# Updated 07/04/2023
# If you found this script useful please consider sponsoring me at https://github.com/sponsors/lwhitelock?frequency=one-time
#
# References
# Determine image type https://devblogs.microsoft.com/scripting/psimaging-part-1-test-image/
# Parsing HTML https://stackoverflow.com/questions/28497902/finding-img-tags-in-html-files-in-powershell
# Nice Base64 conversion https://www.aaron-powell.com/posts/2010-11-07-base64-encoding-images-with-powershell/
# 
# Thank you!
# Luke Whitelock - Primary creator of the ITGlue Migration script and HuduAPI Powershell Module
# John Duprey - Adding file and image uploads to the Migration script, and heavy contributor to the HuduAPI Powershell Module
# Mendy Green - Adding URL rewrite, TOTP Seed imports, improved resilency in the migration, and contributor to the HuduAPI Powershell module
#
# Upcoming Changes
# Convert to a full blown module, prompts for interactive migration experience, save settings to an outside file for secure sharing
# Add/enhance the migration areas to use the new API features of Hudu


param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("Full", "Lite")]
    [string] $InitType
)
if ($MyInvocation.InvocationName -eq '.') {
    Write-Host "Script was dot-sourced" -ForegroundColor Green
} else {
    Write-Host "Script was executed without dot-sourcing, this is the recommended method of running the script to ensure settings are retained in the session" -ForegroundColor Yellow; write-warning "exiting to prevent issues later on, please dot-source the script by running `. .\ITGlue-Hudu-Migration.ps1` from powershell 7 or using the provided ITGlue-Hudu-Migration.exe frontend.";
    exit 1
}
[version]$MinimumPSVersion = '7.5.1'
if (-not ($IsWindows -and [Environment]::OSVersion.Version -ge [version]'10.0.10240' -and [Runtime.InteropServices.RuntimeInformation]::OSArchitecture -in 'X86', 'X64' -and $PSVersionTable.PSEdition -eq 'Core' -and $PSVersionTable.PSVersion -ge $MinimumPSVersion)) {
    Write-Error "Unsupported environment. Requires Windows 10+, x86/x64, and PowerShell 7.5.1–7.x."; exit 1;
} else {
    write-host "CPU arch $([Runtime.InteropServices.RuntimeInformation]::OSArchitecture) is good. Using windows $($iswindows). OS version is good $([Environment]::OSVersion.Version). PS edition is $($PSVersionTable.PSEdition) (greater than required minimum of $MinimumPSVersion." -foregroundColor Green
}
try {Set-StrictMode -Off} catch {}

$project_workdir=$project_workdir ?? "$PSScriptRoot"
$debugFolder = if ([string]::IsNullOrWhiteSpace($debugFolder)) {Join-Path $project_workdir "debug-$(Get-Date -Format 'yyyyMMdd-HHmmss-ffff')"} else {$debugFolder}
$errorsfolder = if ([string]::IsNullOrWhiteSpace($errorsfolder)) {Join-Path $debugFolder 'errors'} else {$errorsfolder}
if (-not (Get-Command -Name Get-EnsuredPath -ErrorAction SilentlyContinue)) { . $PSScriptRoot\Public\Init-OptionsAndLogs.ps1 }
foreach ($folder in @($debugFolder, $errorsfolder, $logs_folder, $settings_folder, $script:ITG_ERRORS_DIRECTORY)) {$null = Get-EnsuredPath -Path $folder}


############################### Settings ###############################
# Define the path to the settings.json file in the detected platform's folder:
$settingsTop = $env:APPDATA
$settingsFiles = $settingsFiles ?? $(Get-Item "$settingsTop\HuduMigration\*\settings.json")
$defaultSettingsPath = $defaultSettingsPath ?? "$settingsTop\HuduMigration\settings.json"

# Function to read back securely stored keys used in the settings.json file
function ConvertSecureStringToPlainText {
    param (
        [Parameter(Mandatory=$true)]
        [System.Security.SecureString] $SecureString
    )

    $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    $plainText = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
    return $plainText
}

# Prompt the user for various settings and save the responses
function CollectAndSaveSettings {
    # Create a hash table to store the settings
    $settings = $settings ?? @{}

    # 1. User Entry- Urls
    Write-Host "Settings- URLs:" -ForegroundColor Yellow
    $settings.HuduBaseDomain = $settings.HuduBaseDomain ?? 
        $((Read-Host -Prompt 'Set the base domain of your Hudu instance (e.g https://myinstance.huducloud.com)') -replace '[\\/]+$', '') -replace '^(?!https://)', 'https://'
    $settings.ITGURL = $settings.ITGURL ?? 
        $((Read-Host -Prompt 'Set the domain of your ITGlue instance (e.g https://your-company.itglue.com)') -replace '[\\/]+$', '') -replace '^(?!https://)', 'https://'
    $settings.ITGAPIEndpoint = $settings.ITGAPIEndpoint ?? 
        $(Select-ObjectFromList -objects @("https://api.itglue.com", "https://api.eu.itglue.com", "https://api.au.itglue.com") -message "Select ITGlue API Endpoint for your instance/region")
    $customBrandedDomain = $customBrandedDomain ?? 
        [bool]$($(Select-ObjectFromList -message "Do you have additional hostnames you'd like to include in the URL Replacement? For example custom branded ITGlue Domain Name." -objects @($false, $true) -allowNull $false) ?? $false)
    $instance = $settings.ITGURL.replace('https://','')
    if ($customBrandedDomain -eq $true -or $customBrandedDomain.ToString().ToLower() -eq 'y') {
    	$settings.ITGCustomDomains = Read-Host -Prompt "Please enter comma separated list of URLs to check for, following the same format of the main domain URL. If only one, don't include the comma."
    }

    # 2. User-Entry- Secrets
    Write-Host "Settings- Secrets:" -ForegroundColor Yellow
    $HuduAPIKey = $HuduAPIKey ?? ""
    $ITGKey = $ITGKey ?? ""
    while ($HuduAPIKey.Length -ne 24) {
        $HuduAPIKey = (Read-Host -Prompt "Get a Hudu API Key from $($settings.HuduBaseDomain)/admin/api_keys").Trim()
        if ($HuduAPIKey.Length -ne 24) {
            Write-Host "This doesn't seem to be a valid Hudu API key. It is $($HuduAPIKey.Length) characters long, but should be 24." -ForegroundColor Red
        }
    }
    while ($ITGKey.Length -notin 100..105) {
        $ITGKey = (Read-Host -Prompt 'Enter your ITGlue API Key (must have password access). Should be 101-104 characters.').Trim()
        if ($ITGKey.Length -notin 101..105) {
            Write-Host "This doesn't seem to be a valid ITGlue API key. It is $($ITGKey.Length) characters long, but should be 101-104." -ForegroundColor Red
        }
    }
    $settings.ITGKey = ConvertTo-SecureString -String $ITGKey -AsPlainText -Force | ConvertFrom-SecureString
    $settings.HuduAPIKey = ConvertTo-SecureString -String $HuduAPIKey -AsPlainText -Force | ConvertFrom-SecureString

    # 3. User-Entry Global KB Settings
    Write-Host "Settings- Global KnowledgeBase:" -ForegroundColor Yellow
    $settings.InternalCompany = $settings.InternalCompany ??
        $(Read-Host 'Enter the exact name of the ITGlue Organization that represents your Internal Company ').ToString().Trim()
    $settings.PlaceInternalDocsInInternalCompany = $settings.PlaceInternalDocsInInternalCompany ??
        [bool]$($(Select-ObjectFromList -message 'Do you want documents from your Internal Company to stay under that company instead of going to Global KB? [Default behavior is N/$false]' -objects @($false, $true) -allowNull $false) ?? $false)
    if ($true -ne $settings.PlaceInternalDocsInInternalCompany) {
        $settings.GlobalKBFolder = $settings.GlobalKBFolder ??
            $(Select-ObjectFromList -message 'Do you want all documents in Global KB to be placed into a subfolder?' -objects @("n", "y"))
        Write-Host "The documents from the company $($settings.InternalCompany) will be migrated to Hudu's Global KB section " -ForegroundColor Cyan
    } else {
        Write-Host "The documents from the company $($settings.InternalCompany) will stay under that company in Hudu" -ForegroundColor Cyan
    }
    $settings.ConPromptPrefix = $settings.ConPromptPrefix ?? 
        $(Read-Host "Would you like a Prefix in front of ️Configuration names️ created in Hudu? This can make it easy to review and you can rename them later. Enter the prefix here, otherwise leave it blank. (e.g. ITGlue-)")
    $settings.FAPromptPrefix = $settings.FAPromptPrefix ??
        $(Read-Host "Would you like a Prefix in front of Asset Layout names created in Hudu? This can make it easy to review and you can rename them later. Enter the prefix here, otherwise leave it blank. (e.g. ITGlue-)")
    $settings.IncludeITGlueID =  $settings.IncludeITGlueID ?? [bool]$($(Select-ObjectFromList -message "would you like to include ITGlue ID in your contacts, locations, and configurations layouts?" -objects @($true,$false) -allowNull $false) ?? $true)

    
    # 4. User-Entry Paths and Folders
    Write-Host "️Settings- Paths and Folders:" -ForegroundColor Yellow
    $settings.ITGlueExportPath = $settings.ITGlueExportPath ?? 
        $(Read-Host 'Enter the path of the ITGlue Export. (e.g. C:\Temp\ITGlue\Export) ️')
    $settings.MigrationLogs = $settings.MigrationLogs ??
        $(Read-Host "Enter the path for the migration logs, or press enter to accept the Default path ($settingsTop\HuduMigration\$instance\MigrationLogs)")
    # Fallback for Migrationlogs setting
    if (!($settings.MigrationLogs)) {
        $settings.MigrationLogs = "$settingsTop\HuduMigration\$instance\MigrationLogs"
    }
    # Ensure folder is created for settings file
    if (!(Test-Path -Path "$settingsTop\HuduMigration\$instance")) { New-Item "$settingsTop\HuduMigration\$instance" -ItemType Directory }


    # Verify settings, save or exit and retry
    $reenterChoice = $reenterChoice ?? 
        $(Select-ObjectFromList -message "Do these settings look alright? $(($settings | ConvertTo-Json -depth 4).ToString())\n-If you choose to re-enter, changes made will not be saved" -objects @("Continue", "Re-Enter"))
    if ($reenterChoice -eq "Continue") {
        Write-Host "Saving Settings to $defaultSettingsPath"
        # Convert the hash table to JSON
        $json = $settings | ConvertTo-Json
        $json | Out-File -FilePath $defaultSettingsPath
    } else {
        Clear-Host
        Write-Host "reinvoke script when you're ready!..." -ForegroundColor Yellow
        exit
    }
}

function UpdateSavedSettings {
    param(
        $newSettings
    )
    if ($settingsPath) {
        if (Test-Path $settingsPath) {
            # Convert the hash table to JSON
            Write-Host "️Overwriting existing settings file with updated settings." -ForegroundColor Cyan
            $json = $newSettings | ConvertTo-Json
            $json | Out-File -FilePath $settingsPath
        }
        else {
            Write-Host "Creating new settings file in $settingsPath" -ForegroundColor Yellow
            $json = $newSettings | ConvertTo-Json
            $json | Out-File -FilePath $settingsPath
        }
    }
    else {
        
        if (Test-Path $defaultSettingsPath) {
            # Convert the hash table to JSON
            Write-Host "️Overwriting existing settings file with updated settings." -ForegroundColor Cyan
            $json = $newSettings | ConvertTo-Json
            $json | Out-File -FilePath $defaultSettingsPath
        }
        else {
            Write-Host "Creating new settings file in $defaultSettingsPath" -ForegroundColor Yellow
            $json = $newSettings | ConvertTo-Json
            $json | Out-File -FilePath $defaultSettingsPath
        }
    }
}


# Prompt the user for a settings file
# Prompt the user for a settings file
function PromptForSettingsPath {
    param(
        [switch]$Default
    )
    if ($Default) {
        $userPath = Read-Host -Prompt "Enter the full path to the settings.json file, or press Enter to use the default settings file ($defaultSettingsPath)"
    } else {
        $userPath = Read-Host -Prompt '️Enter the full path to the settings.json file.'
    }
    
    
    if ($userPath -eq '') { 
        $userPath = $defaultSettingsPath
        $fileNotExistMessage = 'The default settings file does not exist. Please specify a path.'
    } else {
        $fileNotExistMessage = 'The specified path does not exist or is not accessible. Please try again.'
    }
    
    if (Test-Path -Path $userPath) {
        return $userPath
    } else {
        Write-Warning $fileNotExistMessage
        return PromptForSettingsPath
    }
}

# Ask the user what they want to do
if ($environmentSettings -and $InitType -eq 'Lite') {
    Write-Host "Lite init and settings detected."
 }
else {
    $choice = $choice ?? $(Select-ObjectFromList -message "Do you want to import settings or start from new?" -objects @("I", "N"))

    switch ($choice) {
        'I' { 
            if (Test-Path -Path $defaultSettingsPath) {
                Write-Host "Default settings file found at $defaultSettingsPath" -ForegroundColor Cyan
                $importChoice = $importChoice ?? $(Select-ObjectFromList -message "Do you want to use the default settings file or specify a different path?" -objects @("D", "S"))
                
                switch ($importChoice) {
                    'D' {
                        Write-Host "Importing settings from $defaultSettingsPath" -ForegroundColor Yellow
                        $environmentSettings = Get-Content -Path $defaultSettingsPath | ConvertFrom-Json -Depth 50
                    }
                    'S' {
                        $settingsPath = PromptForSettingsPath -Default
                        Write-Host "Importing settings from $settingsPath" -ForegroundColor Yellow
                        $environmentSettings = Get-Content -Path $settingsPath | ConvertFrom-Json -Depth 50
                    }
                    default {
                        Write-Host 'Invalid choice. Please choose (D)efault or (S)pecify.'
                    }
                }
            } else {
                $settingsPath = PromptForSettingsPath
                Write-Host "Importing settings from $settingsPath" -ForegroundColor Yellow
                $environmentSettings = Get-Content -Path $settingsPath | ConvertFrom-Json -Depth 50
            }
        }
        'N' {
            Write-Host "Starting with a new settings file" -ForegroundColor Cyan
            CollectAndSaveSettings
            $environmentSettings = Get-Content -Path $defaultSettingsPath | ConvertFrom-Json -Depth 50
        }
        default {
            throw 'Invalid choice. Please choose (I)mport or (N)ew '
        }
    }
}
############################### API Settings ###############################
# Hudu
# Get a Hudu API Key from https://yourhududomain.com/admin/api_keys
try {
    $HuduAPIKey = ConvertSecureStringToPlainText -SecureString ($environmentSettings.HuduAPIKey|ConvertTo-SecureString)
}
catch {
    Write-Host "Your Hudu API Key is not readable!!!" -ForegroundColor Yellow
    $HuduAPIKey = Read-Host -Prompt "Enter the Hudu API Key from $($environmentSettings.HuduBaseDomain)/admin/api_keys"
    $environmentSettings.HuduAPIKey = ConvertTo-SecureString -String $HuduAPIKey -AsPlainText -Force | ConvertFrom-SecureString
    UpdateSavedSettings -newSettings $environmentSettings
}

# Set the base domain of your Hudu instance without a trailing /
$HuduBaseDomain = $environmentSettings.HuduBaseDomain

# IT Glue - MAKE SURE TO USE AN API KEY WITH PASSWORD ACCESS
$ITGAPIEndpoint = @(
    $ITGAPIEndpoint
    $environmentSettings.ITGAPIEndpoint
    $settings.ITGAPIEndpoint
) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1
if ([string]::isNullOrWhiteSpace($ITGAPIEndpoint)){
    $ITGAPIEndpoint = $(Select-ObjectFromList -objects @("https://api.itglue.com", "https://api.eu.itglue.com", "https://api.au.itglue.com") -message "Select ITGlue API Endpoint for your instance/region")
}
$ITGAPIEndpoint = $ITGAPIEndpoint.Trim() -replace '[\\/]+$', ''
if ($environmentSettings) {
    $savedITGAPIEndpoint = if ($environmentSettings -is [hashtable]) {
        $environmentSettings['ITGAPIEndpoint']
    } else {
        $environmentSettings.ITGAPIEndpoint
    }

    if ($savedITGAPIEndpoint -ne $ITGAPIEndpoint) {
        if ($environmentSettings -is [hashtable]) {
            $environmentSettings['ITGAPIEndpoint'] = $ITGAPIEndpoint
        } else {
            $environmentSettings | Add-Member -MemberType NoteProperty -Name ITGAPIEndpoint -Value $ITGAPIEndpoint -Force
        }
        UpdateSavedSettings -newSettings $environmentSettings
    }
}

try {
    $ITGKey = ConvertSecureStringToPlainText -SecureString ($environmentSettings.ITGKey|ConvertTo-SecureString)
}
catch {
    Write-Host "Your ITG API Key is not readable!!!" -ForegroundColor Yellow
    $ITGKey = Read-Host 'Enter your ITGlue API Key. MAKE SURE TO USE AN API KEY WITH PASSWORD ACCESS'
    $environmentSettings.ITGKey = ConvertTo-SecureString -String $ITGKey -AsPlainText -Force | ConvertFrom-SecureString
    UpdateSavedSettings -newSettings $environmentSettings
}

#Enter your primary IT Glue internal URL
$ITGURL = $environmentSettings.ITGURL

# IT Glue Internal Company Name
$InternalCompany = $environmentSettings.InternalCompany
$PlaceInternalDocsInInternalCompany = [bool]$environmentSettings.PlaceInternalDocsInInternalCompany ?? $false

$ITGlueExportPath = $environmentSettings.ITGlueExportPath

if (-not (Get-Command -Name Ensure-ITGlueExportAvailable -ErrorAction SilentlyContinue)) {
    . $PSScriptRoot\Public\Get-ITGlueExport.ps1
}


# Choose if you want to resume previous attempts from the last successful section
$resumeQuestion = $resumeQuestion ?? $(Select-ObjectFromList -message "Would you like to resume a previous migration?" -objects @($true, $false) -allowNull $false)
$ResumePrevious = $ResumePrevious ?? $(if ($resumeQuestion -eq 'yes' -or $resumeQuestion -eq $true) {$true} else {$false})
$GlobalKBFolder = if ($PlaceInternalDocsInInternalCompany) { $null } else { $environmentSettings.GlobalKBFolder }

# These settings should only run when doing a full settings initialization.
if ($InitType -eq 'Full') {
    ############################### Company Settings ###############################
    $ImportCompanies = $ImportCompanies ?? $(Select-ObjectFromList -message "Import Companies?" -objects @($true, $false) -allowNull $false)

    ############################### Location Settings ###############################
    $ImportLocations = $ImportLocations ?? $(Select-ObjectFromList -message "Import Locations?" -objects @($true, $false) -allowNull $false)

    # The asset layout names and icons
    $ConImportIcon = $ConImportIcon ?? "fas fa-users"
    $LocImportIcon = $LocImportIcon ?? "fas fa-building"
    $ConfigImportIcon = $ConfigImportIcon ?? "fas fa-sitemap"
    $ConfigMigrationName = $ConfigMigrationName ?? "Configurations" # name for configs layout
    $ConImportAssetLayoutName = $ConImportAssetLayoutName ?? "People" # name for people layout
    $LocImportAssetLayoutName = $LocImportAssetLayoutName ?? "Locations" # name for location layout
    $LayoutIconBackGroundColor = $LayoutIconBackGroundColor ?? "#6136ff" # hudu-purple background for layout icons (fallback)
    $LayoutIconForegroundColor = $LayoutIconForegroundColor ?? "#ffffff" # White Foreground for layout icons (fallback)


    # The font awesome name for the locations icon in Hudu
    # Here set two arrays of the different names you have used to identify the primary location in both ITGlue And Hudu
    $ITGPrimaryLocationNames = @("Primary Address", "Main", "Head Office", "Main Office")
    $HuduPrimaryLocationNames = @("Primary Address")

    ############################### Domain / Website Settings ###############################
    $ImportDomains = $ImportDomains ?? $(Select-ObjectFromList -message "Domains are used for Website, DNS and SSL Monitoring. Import Domains?" -objects @($true, $false) -allowNull $false)

    $MergedOrganizationTypes = $MergedOrganizationTypes ?? $(Select-ObjectFromList -message "Would you like to merge certain organization types in ITGlue to a given existing Hudu company?" -objects @($false, $true) -allowNull $false)

    # Choose if you would like to enable monitoring for the imported websites.
    $DisableWebsiteMonitoring = $DisableWebsiteMonitoring ?? $(Select-ObjectFromList -message "Would you like to disable website monitoring?" -objects @($false, $true) -allowNull $false)

    ############################### Configuration Settings ###############################
    $ImportConfigurations = $ImportConfigurations ?? $(Select-ObjectFromList -message "Import Configurations?" -objects @($true, $false) -allowNull $false)

    $ConfigurationPrefix = $settings.ConPromptPrefix ?? $environmentSettings.ConPromptPrefix ?? ""
    $FlexibleLayoutPrefix = $environmentSettings.FAPromptPrefix

    ############################### Contact Settings ###############################
    $ImportContacts = $ImportContacts ?? $(Select-ObjectFromList -message "Import Contacts?" -objects @($true, $false) -allowNull $false)

    ############################### Flexible Asset Layouts ###############################
    $ImportFlexibleAssetLayouts = $ImportFlexibleAssetLayouts ?? $(Select-ObjectFromList -message "Import Asset Layouts?" -objects @($true, $false) -allowNull $false)

    ############################### Flexible Assets ###############################
    $ImportFlexibleAssets = $ImportFlexibleAssets ?? $(Select-ObjectFromList -message "Import Assets?" -objects @($true, $false) -allowNull $false)

    ############################### Articles ###############################
    $ImportArticles = $ImportArticles ?? $(Select-ObjectFromList -message "Import Articles?" -objects @($true, $false) -allowNull $false)
    $IncludeIgnoredFirstArticleDirectory = $IncludeIgnoredFirstArticleDirectory ?? [bool]($(Select-ObjectFromList -message "would you like to include root directories when migrating article folders? default behavior is no/false" -objects @($false,$true) -allowNull $false) ?? $false)

    ############################### Passwords ###############################
    $ImportPasswords = $ImportPasswords ?? $(Select-ObjectFromList -message "Import Passwords?" -objects @($true, $false) -allowNull $false)

    ############################### Unattended ###############################
    $NonInteractive = $NonInteractive ?? $(Select-ObjectFromList -message "Would you like to perform this migration noninteractively?" -objects @($false, $true) -allowNull $false)

    ############################### Scoping ###############################
    $ScopedMigration = $ScopedMigration ?? $(Select-ObjectFromList -message "Would you like to perform migration scoped to certain companies?" -objects @($false, $true) -allowNull $false)

    ############################## Checklists ##############################
    $importChecklists = $importChecklists ?? $(Select-ObjectFromList -message "Would you like to import Checklists? (requires web access to ITGlue)." -objects @($true, $false) -allowNull $false)

    $importPasswordFolders = $importPasswordFolders ?? $(Select-ObjectFromList -message "Would you like to import Password Folders?" -objects @($true, $false) -allowNull $false)
    if ($true -eq $importPasswordFolders) {
        $GlobalPasswordFolderMode = $GlobalPasswordFolderMode ?? [bool]("global" -eq $(Select-ObjectFromList -message "Password folder import mode-" -objects @("global","per-company")))
        $companyPasswordFolderAttributionMove = $companyPasswordFolderAttributionMove ?? $(if ($true -eq $GlobalPasswordFolderMode) {[bool]($(Select-ObjectFromList -message "Password Folders with only one company of passwords- do you want to move those to company-scope password folders? (if you aren't sure, 'yes' is generally a good bet)" -objects @($true,$false)) ?? $true)} else {$false})
    } else {
        $GlobalPasswordFolderMode = $null
        $companyPasswordFolderAttributionMove = $false
    }

    ############################## Interfaces ##############################
    $ImportConfigInterfaces = $ImportConfigInterfaces ?? $(Select-ObjectFromList -message "Would you like to import configuration interfaces (IP Addresses) into IPam in Hudu (requires more time)?" -objects @($true, $false) -allowNull $false)

    ############################# Junk Layouts #############################
    $skipIntegratorLayouts = $skipIntegratorLayouts ?? $(Select-ObjectFromList -message "[Other, default false] Would you like to skip importing Integrator Layouts? These are often containing data that goes unused." -objects @($true, $false) -allowNull $false)
    
    ############################ Sane deafaults that can be overridden ############################
    $OptionalImageAnchorReplace = $OptionalImageAnchorReplace ?? $true
    $allowSettingFlagsAndTypes = $allowSettingFlagsAndTypes ?? $false
    $AllowEmptyPasswords = $AllowEmptyPasswords ?? $true


    # $AllowEmptyPasswords = $AllowEmptyPasswords ?? [bool]($(Select-ObjectFromList -message "would you like to skip empty passwords if there are any in ITGlue. Make sure this is false if you have vaulted passwords. (default - no - keep empty passwords/false)" -objects @($false,$true) -allowNull $false) ?? $false)

}

############################ Migration Logs Path ##############################
$MigrationLogs = $environmentSettings.MigrationLogs

$AutoDownloadITGlueExport = $AutoDownloadITGlueExport ?? $environmentSettings.AutoDownloadITGlueExport ?? $true
if ($true -eq $AutoDownloadITGlueExport) {
    $autoExportParams = @{
        ITGKey         = $ITGKey
        ITGBaseURI     = $ITGAPIEndpoint
        ExportPath     = $ITGlueExportPath
        DownloadPath   = $ITGlueExportDownloadPath ?? $environmentSettings.ITGlueExportDownloadPath ?? $null
        SevenZipPath   = $ITGlueExportSevenZipPath ?? $environmentSettings.ITGlueExportSevenZipPath ?? $null
        ZipPassword    = $ITGlueExportZipPassword ?? $environmentSettings.ITGlueExportZipPassword ?? $null
        DownloadFileNameTag = $HuduBaseDomain ?? $settings.HuduBaseDomain ?? $environmentSettings.HuduBaseDomain ?? $settings.ITGURL ?? $environmentSettings.ITGURL ?? $ITGAPIEndpoint
        LogsPath       = $MigrationLogs
        GenerateZipPassword = [bool]($ITGlueExportGenerateZipPassword ?? $environmentSettings.ITGlueExportGenerateZipPassword ?? $true)
        ClearExistingExports = [bool]($ITGlueExportClearExistingExports ?? $environmentSettings.ITGlueExportClearExistingExports ?? $true)
        IncludeLogs    = [bool]($ITGlueExportIncludeLogs ?? $environmentSettings.ITGlueExportIncludeLogs ?? $false)
        PollSeconds    = [int]($ITGlueExportPollSeconds ?? $environmentSettings.ITGlueExportPollSeconds ?? 60)
        TimeoutMinutes = [int]($ITGlueExportTimeoutMinutes ?? $environmentSettings.ITGlueExportTimeoutMinutes ?? 240)
    }

    try {
        $ITGlueExportRunInBackground = [bool]($ITGlueExportRunInBackground ?? $environmentSettings.ITGlueExportRunInBackground ?? $true)
        if ($ITGlueExportRunInBackground -and -not (Test-ITGlueExportPathHasContent -Path $ITGlueExportPath)) {
            $ITGlueExportBootstrapJob = Start-ITGlueExportBootstrapJob `
                -ExportParameters $autoExportParams `
                -HelperScriptPath (Join-Path -Path $PSScriptRoot -ChildPath 'Public\Get-ITGlueExport.ps1')
            Write-Host "Started IT Glue export download/extract in the background as job $($ITGlueExportBootstrapJob.Id)." -ForegroundColor Green
        } else {
            $ITGlueExportBootstrap = Ensure-ITGlueExportAvailable @autoExportParams
            $ITGlueExportPath = $ITGlueExportBootstrap.ExportPath
            if ($environmentSettings) {
                $environmentSettings | Add-Member -MemberType NoteProperty -Name ITGlueExportPath -Value $ITGlueExportPath -Force
            }
        }
    } catch {
        Write-Host "Automatic IT Glue export download/extract failed: $($_.Exception.Message)" -ForegroundColor Red
        throw
    }
} else {
    Write-Host "Automatic IT Glue export download/extract is disabled. Using configured export path: $ITGlueExportPath" -ForegroundColor Yellow
}

# Password CSV validation is deferred until after any background export job has finished.
$resolvedITGlueExportPath = $ITGlueExportPath ?? $environmentSettings.ITGlueExportPath ?? $settings.ITGlueExportPath
$passwordsCSVPath = if (-not [string]::IsNullOrWhiteSpace($resolvedITGlueExportPath)) { Join-Path -Path $resolvedITGlueExportPath -ChildPath "passwords.csv" } else { $null }
$vaultedCSVPath = if (-not [string]::IsNullOrWhiteSpace($resolvedITGlueExportPath)) { Join-Path -Path $resolvedITGlueExportPath -ChildPath "vaulted" } else { $null }
$passwordsCSVOptional = ($InitType -ne 'Full' -or ((2,$false) -contains $ImportPasswords -and (2,$false) -contains $ImportFlexibleAssets))
$passwordsCSVOptionalReason = if ($InitType -ne 'Full') { "this is a Lite initialization, so password and flexible asset imports are not being configured" } else { "you have chosen to skip both flexible assets and passwords" }
$passwordsCSVvalidated = $false
$passwordsCSVFound = $false

$VaultedPasswords = @()
$possiblyVaultedPasswords = $false
$uniqueVaultedOrgs = @()
$userVaultedPasswordsDirPresent = $false
$vaultCSVsPresent = @()
$shouldRunVaultJob = $false

function Confirm-ITGlueExportPasswordCsv {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$ExportPath,

        [bool]$PasswordsCSVOptional,

        [AllowNull()]
        [string]$PasswordsCSVOptionalReason
    )

    if ([string]::IsNullOrWhiteSpace($ExportPath)) {
        throw "ITGlue export path is blank. Please set ITGlueExportPath before checking for passwords.csv."
    }

    $resolvedPath = (Resolve-Path -LiteralPath $ExportPath -ErrorAction SilentlyContinue).Path
    if ([string]::IsNullOrWhiteSpace($resolvedPath)) {
        $resolvedPath = $ExportPath
    }

    $candidatePasswordCsvPath = Join-Path -Path $resolvedPath -ChildPath "passwords.csv"
    $validated = $false
    $found = $false
    $override = $null

    while ($validated -eq $false) {
        if (Test-Path -LiteralPath $candidatePasswordCsvPath -PathType Leaf -ErrorAction SilentlyContinue) {
            Write-Host "Password CSV found at $candidatePasswordCsvPath" -ForegroundColor Cyan
            $found = $true
            $validated = $true
        } elseif ($PasswordsCSVOptional) {
            Write-Host "passwords.csv not found at $candidatePasswordCsvPath, but since $PasswordsCSVOptionalReason, this file is not needed specifically for your migration. If you later choose to migrate either of those sections, make sure to have a passwords.csv in your export folder." -ForegroundColor Yellow; Start-Sleep -Seconds 2
            $validated = $true
        } else {
            Write-Host "passwords.csv not found at $candidatePasswordCsvPath. You'll want to take another export, this time ensuring that passwords are included. Failure to do so will result in missing password data. Passwords.csv is used in both flexible assets and passwords portions of the migration." -ForegroundColor Red; Start-Sleep -Seconds 2
            $override = Read-Host "Press Enter to re-check for the file if you have extracted a new export to $resolvedPath, or Ctrl+C to exit. To continue anyway without passwords CSV (not recommended), please enter this phrase exactly with no quotes: 'migrate-anyway'"
            if ($override -ieq 'migrate-anyway') {
                Write-Host "Continuing without passwords.csv. Password data will be missing from the migration." -ForegroundColor Yellow
                $validated = $true
            }
        }
    }

    [pscustomobject]@{
        ExportPath          = $resolvedPath
        PasswordsCSVPath    = $candidatePasswordCsvPath
        VaultedCSVPath      = Join-Path -Path $resolvedPath -ChildPath "vaulted"
        PasswordsCSVFound   = $found
        OverrideNoPassCSV   = $override
    }
}

############################### Functions ###############################
# Import ImageMagick for Invoke-ImageTest Function (Disabled)
 . $PSScriptRoot\Private\Initialize-ImageMagik.ps1

# Used to determine if a file is an image and what type of image
. $PSScriptRoot\Private\Invoke-ImageTest.ps1

# Confirm Object Import
. $PSScriptRoot\Private\Confirm-Import.ps1

# Matches items from IT Glue to Hudu and creates new items in Hudu
. $PSScriptRoot\Private\Import-Items.ps1

# Select Item Import Mode
. $PSScriptRoot\Private\Get-ImportMode.ps1

# Get Flexible Asset Layout Option
. $PSScriptRoot\Private\Get-FlexLayoutImportMode.ps1

# Fetch Items from ITGlue
. $PSScriptRoot\Private\Import-ITGlueItems.ps1

# Find migrated items
. $PSScriptRoot\Private\Find-MigratedItem.ps1

# Lookup table to upgrade from Font Awesome 4 to 5
. $PSScriptRoot\Private\Get-FontAwesomeMap.ps1
$FontAwesomeUpgrade = Get-FontAwesomeMap

# Add Replace URL functions
. $PSScriptRoot\Private\ConvertTo-HuduURL.ps1

# Add Hudu Relations Function
. $PSScriptRoot\Public\Add-HuduRelation.ps1

# Add Timed (Noninteractive) Messages Helper
. $PSScriptRoot\Public\Write-TimedMessage.ps1

# Add numeral casting, password folder fetching, and article stub starting helpers
. $PSScriptRoot\Public\Get-CastIfNumeric.ps1
. $PSScriptRoot\Public\Start-ArticleStubs.ps1
. $PSScriptRoot\Public\ArticleContentLocalCache.ps1
. $PSScriptRoot\Public\Resolve-ArticleAttachmentImage.ps1
. $PSScriptRoot\Public\Get-PasswordFolders.ps1

# Add migration scope helper
. $PSScriptRoot\Public\Set-MigrationScope.ps1

# Other JWT-Auth / Advanced Post-Run Imports
. $PSScriptRoot\Public\Get-Checklists.ps1

# Add String/Filename Normalization Helper, image Normalization helper
. $PSScriptRoot\Public\Normalize-String.ps1
. $PSScriptRoot\Public\Normalize-And-ConvertImage.ps1
# initialization helper and field requirement helper, logging, selection helper
. $PSScriptRoot\Public\Get-ITGFieldPopulated.ps1
. $PSScriptRoot\Public\JWT-Auth.ps1
. $PSScriptRoot\Public\NetworkInformation.ps1
. $PSScriptRoot\Public\PreFlightTests.ps1
. $PSScriptRoot\Public\ReplaceAttachmentLinks.ps1
. $PSScriptRoot\Public\Invoke-FastArticleCommit.ps1
. $PSScriptRoot\Public\Timed-Job.ps1
. $PSScriptRoot\Public\Set-LabelTypeHelpers.ps1
. $PSScriptRoot\Public\Get-ITGTimeEstimate.ps1
if (-not (Get-Command -Name Get-UserFlagSetup -ErrorAction SilentlyContinue)) { . $PSScriptRoot\Public\Add-OptionalFlags.ps1 }
$requiredHuduVersion = ([version]"2.44.0")
$CurrentVersion =  Set-ExternalModulesInitialized -RequiredHuduVersion $requiredHuduVersion -DisallowedVersions @([version]"2.37.0") -HuduBaseURL $($hudubaseurl ?? $settings.HuduBaseDomain ?? $null) -HuduAPIKey $($huduapikey ?? $settings.HuduApiKey ?? $null)
if (get-command -name Set-HapiErrorsDirectory -ErrorAction SilentlyContinue){try {Set-HapiErrorsDirectory -Path "$errorsfolder" -skipRetry $false} catch {}}

