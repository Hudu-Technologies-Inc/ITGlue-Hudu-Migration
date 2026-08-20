if (-not (Get-Command -Name Get-ITGPasswordFolders -ErrorAction SilentlyContinue)) { . "$($(get-childitem -path "." -Recurse -file "Get-PasswordFolders.ps1" | Select-Object -first 1).fullname)"}
if (-not (Get-Command -Name Get-EnsuredPath -ErrorAction SilentlyContinue)) { . "$($(get-childitem -path "." -Recurse -file "Init-OptionsAndLogs.ps1" | Select-Object -first 1).fullname)"}
if (-not (Get-Command -Name Get-SimilaritySafe -ErrorAction SilentlyContinue)) { . "$($(get-childitem -path "." -Recurse -file "normalize-string.ps1" | Select-Object -first 1).fullname)"}

$global_password_folders = @()
$PFMappings = $PFMappings ?? @{}
$ITGPasswordFolders =  @{}; $MatchedPasswordFolders = @()
$GlobalPasswordFolderMode = $GlobalPasswordFolderMode ?? $([bool]$("global" -eq $(Select-ObjectFromList -message "Password folder import mode-" -objects @("global","per-company"))))
$PWFPageSize = $PWFPageSize ?? 250
$PasswordFolderPathDelimiter = $PasswordFolderPathDelimiter ?? "<FDELIM>"
$PasswordFolderNameDelimiter = $PasswordFolderNameDelimiter ?? " - "
if (-not $MatchedCompanies -or $matchedCompanies.count -lt 1){
    write-host "Can't preload password folders without matched companies, skipping preload of password folders."
    return
} 

$FolderNamingMode = [string]($FolderNamingMode ?? $(Select-ObjectFromList -message "Since Hudu doesnt support multiple password folder layers, would you like to do one of the following?" -objects @("Name Based on Root-Level-Directory","Name Based on Full Path with Delimiter","Name Based on Current/Leaf-Level Directory")))

function Get-HuduPasswordFolderNameFromPath {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Mode,

        [Parameter(Mandatory)]
        [string]$PathDelimiter,

        [Parameter(Mandatory)]
        [string]$NameDelimiter
    )

    $parts = @("$Path" -split [regex]::Escape($PathDelimiter)) |
        ForEach-Object { "$_".Trim() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    if ($parts.Count -eq 0) { return "" }

    switch ($Mode) {
        "Name Based on Root-Level-Directory" {
            return $parts[0]
        }
        "Name Based on Full Path with Delimiter" {
            return ($parts -join $NameDelimiter)
        }
        { $_ -in @("Name Based on Current/Leaf-Level Directory", "Name Based on topmost level") } {
            return $parts[-1]
        }
        default {
            Write-Warning "Unknown password folder naming mode '$Mode'. Using full path with delimiter."
            return ($parts -join $NameDelimiter)
        }
    }
}

if (-not $MatchedCompanies -or $matchedCompanies.count -lt 1){
    write-host "Can't preload password folders without matched companies, skipping preload of password folders."
    return
} 

# $PFMappings["Software &"]="Software & Applications"
# $PFMappings["Software and"]="Software & Applications"

function ChoseBest-ByName {
    param ([string]$Name,[array]$choices)
return $($choices | ForEach-Object {
[pscustomobject]@{Choice = $_; Score  = $(Get-SimilaritySafe -a "$Name" -b $_.name);}} | where-object {$_.Score -ge 0.98} | Sort-Object Score -Descending | select-object -First 1).Choice
}

function Get-HuduAssetPasswordFromResponse {
    param (
        [object]$InputObject,

        [int]$Id = 0
    )

    if ($null -eq $InputObject) { return $null }

    if ($null -ne $InputObject.PSObject.Properties['asset_password']) {
        return $InputObject.asset_password
    }

    if ($null -ne $InputObject.PSObject.Properties['asset_passwords']) {
        $passwords = @($InputObject.asset_passwords)
        if ($Id -gt 0) {
            return $passwords | Where-Object { [int]$_.id -eq $Id } | Select-Object -First 1
        }
        if ($passwords.Count -eq 1) { return $passwords[0] }
        return $passwords
    }

    $items = @($InputObject)
    if ($Id -gt 0 -and $items.Count -gt 1) {
        return $items | Where-Object { [int]$_.id -eq $Id } | Select-Object -First 1
    }
    if ($items.Count -eq 1) { return $items[0] }
    return $items
}

function Get-HuduAssetPasswordList {
    param ([object]$InputObject)

    if ($null -eq $InputObject) { return @() }
    if ($null -ne $InputObject.PSObject.Properties['asset_passwords']) { return @($InputObject.asset_passwords) }
    if ($null -ne $InputObject.PSObject.Properties['asset_password']) { return @($InputObject.asset_password) }
    return @($InputObject)
}

function Get-HuduPasswordFolderFromResponse {
    param ([object]$InputObject)

    if ($null -eq $InputObject) { return $null }
    if ($null -ne $InputObject.PSObject.Properties['password_folder']) { return $InputObject.password_folder }
    if ($null -ne $InputObject.PSObject.Properties['password_folders']) {
        $folders = @($InputObject.password_folders)
        if ($folders.Count -eq 1) { return $folders[0] }
        return $folders
    }
    return $InputObject
}

function Get-HuduPasswordIdFromMatch {
    param ([object]$MatchedPassword)

    $candidates = @(
        $MatchedPassword.HuduID
        $MatchedPassword.HuduObject.id
        $MatchedPassword.HuduObject.asset_password.id
    )

    if ($null -ne $MatchedPassword.HuduObject.PSObject.Properties['asset_passwords']) {
        $passwords = @($MatchedPassword.HuduObject.asset_passwords)
        if ($passwords.Count -eq 1) {
            $candidates += $passwords[0].id
        }
    }

    foreach ($candidate in $candidates) {
        foreach ($value in @($candidate)) {
            $parsed = 0
            if ([int]::TryParse([string]$value, [ref]$parsed) -and $parsed -gt 0) {
                return $parsed
            }
        }
    }

    return $null
}

function Get-HuduPasswordCompanyIdFromMatch {
    param ([object]$MatchedPassword)

    $candidates = @(
        $MatchedPassword.HuduObject.company_id
        $MatchedPassword.HuduObject.asset_password.company_id
    )

    if ($null -ne $MatchedPassword.HuduObject.PSObject.Properties['asset_passwords']) {
        $passwords = @($MatchedPassword.HuduObject.asset_passwords)
        if ($passwords.Count -eq 1) {
            $candidates += $passwords[0].company_id
        }
    }

    foreach ($candidate in $candidates) {
        foreach ($value in @($candidate)) {
            $parsed = 0
            if ([int]::TryParse([string]$value, [ref]$parsed) -and $parsed -gt 0) {
                return $parsed
            }
        }
    }

    return $null
}

function Set-HuduPasswordFolderAssignment {
    param (
        [Parameter(Mandatory = $true)]
        [int]$Id,

        [Alias('company_id')]
        [int]$CompanyId,

        [Alias('password_folder_id')]
        [AllowNull()]
        [object]$PasswordFolderId
    )

    if ($Id -lt 1) {
        throw "Refusing to update Hudu password without a valid id. Resolved id was '$Id'."
    }

    $assetPassword = Get-HuduAssetPasswordFromResponse -InputObject (Get-HuduPasswords -Id $Id) -Id $Id
    if ($null -eq $assetPassword -or @($assetPassword).Count -ne 1) {
        throw "Expected one Hudu password for id $Id, received $(@($assetPassword).Count)."
    }

    # Hudu GET returns the service URL as login_url, while PUT expects it as url.
    # The GET url value is the Hudu record URL, so never echo that back as url.
    $loginUrl = $assetPassword.login_url
    if ($assetPassword.PSObject.Properties['url']) {
        $assetPassword.PSObject.Properties.Remove('url')
    }
    if ($assetPassword.PSObject.Properties['login_url']) {
        $assetPassword | Add-Member -MemberType NoteProperty -Name url -Force -Value $loginUrl
        $assetPassword.PSObject.Properties.Remove('login_url')
    }

    if ($CompanyId -gt 0) {
        $assetPassword | Add-Member -MemberType NoteProperty -Name company_id -Force -Value $CompanyId
    }
    $assetPassword | Add-Member -MemberType NoteProperty -Name password_folder_id -Force -Value $PasswordFolderId

    $body = @{asset_password = $assetPassword} | ConvertTo-Json -Depth 10
    Invoke-HuduRequest -Method put -Resource "/api/v1/asset_passwords/$Id" -Body $body
}

function remove-hudupasswordfromfolder {
    Param (
        [Parameter(Mandatory = $true)]
        [Int]$Id
    )
    Set-HuduPasswordFolderAssignment -Id $Id -PasswordFolderId $null
}

function New-HuduGlobalPasswordFolder {
    param ([Parameter(Mandatory)] [string]$Name)
    try {
        $res = Invoke-HuduRequest -Method POST -Resource "/api/v1/password_folders" -Body $(@{password_folder = @{name = $Name; security = "all_users"; allowed_groups  = @()}} | ConvertTo-Json -Depth 10)
        return $res
    } catch {
        Write-Warning "Failed to create new password folder '$Name'- $_"; return $null;
    }
}
$ITGAPIEndpoint = $settings.ITGAPIEndpoint ?? 
    $(Select-ObjectFromList -objects @("https://api.itglue.com", "https://api.eu.itglue.com", "https://api.au.itglue.com") -message "Select ITGlue API Endpoint for your instance/region")


$global_password_folders = $(get-hudupasswordfolders | where-object {-not $_.company_id -or $_.company_id -lt 1})

Write-Host "Please Wait, obtaining password folders from ITGlue"
foreach ($itgcompanyID in ($matchedpasswords.ITGObject.attributes.'organization-id' | Select-Object -Unique)) {

    # 1) Scope matches to this IT Glue org
    $matchesForOrg = $matchedpasswords | Where-Object {
        [string]$_.ITGObject.attributes.'organization-id' -eq [string]$itgcompanyID    
    }
    if (-not $matchesForOrg -or $matchesForOrg.Count -eq 0) {
        Write-Host "No matched passwords for ITG org $itgcompanyID — skipping."
        continue
    }
    # 2) Get folders for this org (paths already computed)
    $passwordFolderArray = $null
    $passwordFolderArray = Get-ITGPasswordFolders -ITGKEY $ITGKey -organization_id $itgcompanyID -ComputePaths -Separator $PasswordFolderPathDelimiter -PageSize $PWFPageSize -ITGBaseuRI $ITGAPIEndpoint
    
    if (-not $passwordFolderArray -or $passwordFolderArray.Count -eq 0) {
        Write-Host "No password folders for company $itgcompanyID — skipping."
        continue
    }
    Write-Host "Retrieved $($passwordFolderArray.Count) password folders for $itgcompanyID"
    $ITGPasswordFolders["$itgcompanyID"] = $passwordFolderArray

    # 3) Only consider folders that actually have passwords *in this org’s matches*
    $foldersWithPasswords = foreach ($pf in $passwordFolderArray) {
        $has = $matchesForOrg | Where-Object {
            [string]$_.ITGObject.attributes.'password-folder-id' -eq [string]$pf.id
        }
        if ($has) { $pf }
    }

    foreach ($passwordFolder in $foldersWithPasswords) {
        $companyError = $null; $folderError = $null; $passwordError = $null; $Modified = $false; $existingpass = $null;
        
        $FolderName = Get-HuduPasswordFolderNameFromPath -Path $passwordFolder.path -Mode $FolderNamingMode -PathDelimiter $PasswordFolderPathDelimiter -NameDelimiter $PasswordFolderNameDelimiter
        $match = $null
        $match = $PFMappings.Keys | Sort-Object { $_.Length } -Descending | Where-Object { $FolderName.StartsWith($_, [System.StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1
        if ($match) {
            Write-Host "Matched map term $match"
            $FolderName = $PFMappings[$match]
        }


        write-host "folder name $foldername from path $($passwordFolder.path)" -ForegroundColor DarkCyan


    # 4) Get the passwords for THIS folder but only from THIS org
        $passwordsForFolder = $matchesForOrg | Where-Object {
            [string]$_.ITGObject.attributes.'password-folder-id' -eq [string]$passwordFolder.id
        }
        if (-not $passwordsForFolder -or $passwordsForFolder.Count -lt 1) {
            $folderError= "Seemingly no MATCHED passwords for folder: $FolderName"
            $MatchedPasswordFolders+=[PSCustomObject]@{FolderError=$FolderError; companyError=$companyError; ITGCompanyID= $itgcompanyID; HuduCompanyID=$($existingpass.company_id ?? $HuduCompanyId); ITGPasswordFolder= $passwordFolder; HuduPasswordFolder=$existingFolder; HuduPasswords=$passwordsForFolder; FolderName=$FolderName; PasswordError=$passwordError; Modified = $passChanged; existingFolderPresent=$existingFolderPresent}
            continue
        }

    # 5) Derive the Hudu company id from those passwords; ensure they all agree
        $companyGroups = $passwordsForFolder | Where-Object {
            (Get-HuduPasswordCompanyIdFromMatch -MatchedPassword $_) -ge 1
        } | Group-Object { Get-HuduPasswordCompanyIdFromMatch -MatchedPassword $_ }
        if ($companyGroups.Count -lt 1) {
            $HuduCompanyId = $null
        } elseif ($companyGroups.Count -ne 1) {
            $dominant = $companyGroups | Sort-Object Count -Descending | Select-Object -First 1
            $HuduCompanyId = [int]$dominant.Name
            $passwordsForFolder = $dominant.Group
        } else {
            $HuduCompanyId = [int]$companyGroups[0].Name
            if ($HuduCompanyId -lt 1) {
                $HuduCompanyId = [int]$companyGroups[1].Name
            }
        }
        Write-Host "$($passwordsForFolder.Count) passwords for '$FolderName' in Hudu company $HuduCompanyId"
        if (-not $HuduCompanyId -or $HuduCompanyId -lt 1){
            $companyError= "Company doesnt seem to exist?"
            $MatchedPasswordFolders+=[PSCustomObject]@{FolderError=$FolderError; companyError=$companyError; ITGCompanyID= $itgcompanyID; HuduCompanyID=$($existingpass.company_id ?? $HuduCompanyId); ITGPasswordFolder= $passwordFolder; HuduPasswordFolder=$existingFolder; HuduPasswords=$passwordsForFolder; FolderName=$FolderName; PasswordError=$passwordError; Modified = $passChanged; existingFolderPresent=$existingFolderPresent}
            continue
        }

        # 6) Ensure the Hudu password folder exists for company
        try {
            if ($true -ne $GlobalPasswordFolderMode){
            # company-specific 
                $existingFolder = Get-HuduPasswordFolders -CompanyId $HuduCompanyId -Name $FolderName | Select-Object -First 1
                if (-not $existingFolder) {
                    Write-Host "Creating Hudu password folder '$FolderName' for company $HuduCompanyId"
                    $existingFolder = New-HuduPasswordFolder -CompanyId $HuduCompanyId -Name $FolderName
                }
                $existingFolder = Get-HuduPasswordFolderFromResponse -InputObject $existingFolder
            } else {
            # globals only - fuzzy-match for naming differences ohn source
                $existingFolder = ChoseBest-ByName -name "$FolderName" -choices $(get-hudupasswordfolders | where-object {-not $_.company_id -or $_.company_id -lt 1 -or $null -eq $_.company_id})
                if (-not $existingFolder) {
                    Write-Host "Creating Hudu password folder '$FolderName' for company $HuduCompanyId"
                    $existingFolder = New-HuduGlobalPasswordFolder -Name $FolderName
                    # $global_password_folders = $(get-hudupasswordfolders | where-object {-not $_.company_id -or $_.company_id -lt 1 -or $null -eq $_.company_id})
                }
                $existingFolder = Get-HuduPasswordFolderFromResponse -InputObject $existingFolder
            }
            if (-not $existingFolder) {
                $folderError = "No folder $FolderName for company $HuduCompanyId"
            } else {write-host "$folderName -> $($existingFolder.name)"}
        } catch {
                $folderError = "folder error during fetch / create for folder $FolderName for company $HuduCompanyId $_"
        }
        if ($null -ne $folderError){
            $MatchedPasswordFolders+=[PSCustomObject]@{FolderError=$FolderError; companyError=$companyError; ITGCompanyID= $itgcompanyID; HuduCompanyID=$($existingpass.company_id ?? $HuduCompanyId); ITGPasswordFolder= $passwordFolder; HuduPasswordFolder=$existingFolder; HuduPasswords=$passwordsForFolder; FolderName=$FolderName; PasswordError=$passwordError; Modified = $passChanged; existingFolderPresent=$existingFolderPresent}
            continue
        } 
            

    # 7) Move/place each password
        foreach ($updatePass in $passwordsForFolder) {
            $modified=$false
            $passwordError = $null
            $passChanged = $null
            $existingpass = $null
            $passwordId = Get-HuduPasswordIdFromMatch -MatchedPassword $updatePass
            try {
                if (-not $passwordId -or $passwordId -lt 1) {
                    $passwordError = "No valid Hudu password id could be resolved for IT Glue password $($updatePass.ITGID). Skipping to avoid PUT /asset_passwords/0."
                    $MatchedPasswordFolders+=[PSCustomObject]@{FolderError=$FolderError; companyError=$companyError; ITGCompanyID= $itgcompanyID; HuduCompanyID=$($existingpass.company_id ?? $HuduCompanyId); ITGPasswordFolder= $passwordFolder; HuduPasswordFolder=$existingFolder; HuduPasswords=$passwordsForFolder; FolderName=$FolderName; PasswordError=$passwordError; Modified = $passChanged; existingFolderPresent=$existingFolderPresent}
                    continue
                }

                $existingpass = Get-HuduAssetPasswordFromResponse -InputObject (Get-HuduPasswords -Id $passwordId) -Id $passwordId
                if (-not $existingpass) {$passwordError =  "no pass can be retrieved"
                    $passwordError =  "no pass can be retrieved without error $_"
                }
            } catch {
                $passwordError = "Error encounted validating password $_"
            }
            try {
                if ($null -ne $passwordError){
                    $MatchedPasswordFolders+=[PSCustomObject]@{FolderError=$FolderError; companyError=$companyError; ITGCompanyID= $itgcompanyID; HuduCompanyID=$($existingpass.company_id ?? $HuduCompanyId); ITGPasswordFolder= $passwordFolder; HuduPasswordFolder=$existingFolder; HuduPasswords=$passwordsForFolder; FolderName=$FolderName; PasswordError=$passwordError; Modified = $passChanged; existingFolderPresent=$existingFolderPresent}
                    continue
                }
                try {
                    $passChanged=$null; $passChanged=Set-HuduPasswordFolderAssignment `
                        -Id $passwordId `
                        -Company_Id $($existingpass.company_id ?? $HuduCompanyId) `
                        -Password_Folder_Id $existingFolder.id
                    $Modified = [bool]$($passChanged -ne $null)
                } catch {
                    $passwordError = "Error placing password id $passwordId in '$FolderName' (Company $HuduCompanyId): $_"
                    $Modified = $false
                }
            } catch {
                $passwordError = "error encountered assigning folder $_"
            }
            $MatchedPasswordFolders+=[PSCustomObject]@{FolderError=$FolderError; companyError=$companyError; ITGCompanyID= $itgcompanyID; HuduCompanyID=$($existingpass.company_id ?? $HuduCompanyId); ITGPasswordFolder= $passwordFolder; HuduPasswordFolder=$existingFolder; HuduPasswords=$passwordsForFolder; FolderName=$FolderName; PasswordError=$passwordError; Modified = $passChanged; existingFolderPresent=$existingFolderPresent}
        }
    }
}

$companyPasswordFolderAttributionMove = $companyPasswordFolderAttributionMove ?? $true
$minCompanyPctForGlobalFolder = $minCompanyPctForGlobalFolder ?? 0.125 # defaults to 1/8th of companies with passwords as threshold for moving to global folder if using global password folder mode but allowing company attribution move

if ($true -eq $companyPasswordFolderAttributionMove -and $true -eq $GlobalPasswordFolderMode) {
    $allPasswordFolders = Get-HuduPasswordFolders | Where-Object { -not $_.company_id -or $_.company_id -lt 1 }
    $allPasswords = @(Get-HuduAssetPasswordList -InputObject (Get-HuduPasswords))
    $companyIdsWithAnyPasswords = $allPasswords.company_id | Where-Object { $_ -ge 1 } | Sort-Object -Unique
    $denom = [math]::Max(1, $companyIdsWithAnyPasswords.Count)

    foreach ($folder in $allPasswordFolders) {
        $passwordsInFolder = $allPasswords | Where-Object { $_.password_folder_id -eq $folder.id }
        $companyGroups = $passwordsInFolder.company_id | Where-Object { $_ -ge 1 } | Sort-Object -Unique

        $representedPct = $companyGroups.Count / $denom
        Write-Host ("Folder '{0}' has passwords from {1} company(ies) ({2:P1} of companies-with-passwords)" -f $folder.name, $companyGroups.Count, $representedPct)

        if ($companyGroups.count -eq 1 -or $representedPct -lt $minCompanyPctForGlobalFolder) {
            Write-Host ("Moving folder '{0}' because {1:P1} < threshold {2:P1}" -f $folder.name, $representedPct, $minCompanyPctForGlobalFolder)
            foreach ($companyId in $companyGroups) {
                Write-Host "Company $companyId has password(s) in folder '$($folder.name)'"

                $companyPasswords = $passwordsInFolder | Where-Object { $_.company_id -eq $companyId }
                $companyScopedFolder = Get-HuduPasswordFolders -CompanyId $companyId -Name $folder.name | Select-Object -First 1

                if ($null -eq $companyScopedFolder) {
                    Write-Host "Creating company-scoped folder for company $companyId for folder '$($folder.name)'"
                    $companyScopedFolder = New-HuduPasswordFolder -CompanyId $companyId -Name $folder.name
                    $companyScopedFolder = $companyScopedFolder.password_folder ?? $companyScopedFolder
                } else {
                    Write-Host "Company-scoped folder already exists for company $companyId for folder '$($folder.name)'"
                }

                Write-Host "Moving $($companyPasswords.Count) password(s) to company-scoped folder '$($companyScopedFolder.name)' for company $companyId"

                foreach ($pass in $companyPasswords) {
                    try {
                        Set-HuduPasswordFolderAssignment -Id $pass.id -Company_Id $companyId -Password_Folder_Id $companyScopedFolder.id
                    } catch {
                        Write-Warning "Failed to move password id $($pass.id) to company-scoped folder '$($companyScopedFolder.name)' for company $companyId $_"
                    }
                }
            }
            write-host "Deleting global folder '$($folder.name)' since it now should have no passwords in it"
            Remove-HuduPasswordFolder -Id $folder.id
        } else {
            Write-Host ("Keeping folder '{0}' because {1:P1} >= threshold {2:P1}" -f $folder.name, $representedPct, $minCompanyPctForGlobalFolder)
        }
    }
}
# quick cleaning pass
$allPasswords = @(Get-HuduAssetPasswordList -InputObject (get-hudupasswords))
 foreach ($p in $(get-hudupasswordfolders)) {
     $pwf = Get-HuduPasswordFolderFromResponse -InputObject $p

     $infolder = $allpasswords | Where-Object {
         $_.password_folder_id -eq $pwf.id
     }

     Write-Host "$($infolder.Count) in $($pwf.name)"
    if ($infolder.Count -eq 0) {
        Write-Host "No passwords in folder '$($pwf.name)' — deleting"
        Remove-HuduPasswordFolder -Id $pwf.id
    }
 }
