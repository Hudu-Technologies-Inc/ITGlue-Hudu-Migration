function Write-TimedMessage {
    Param(
        [string]$Message,
        [string]$DefaultResponse,
        [int]$Timeout = 0  # Optional timeout in seconds for non-interactive mode
    )

    # Check non-interactive mode
    if ($NonInteractive -eq $true) {
        if ($Timeout -gt 0) {
            $TimeoutStatement = "- Waiting for $Timeout seconds due to noninteractive mode. Control + c now if you do not wish to continue."
        } else {
            $TimeoutStatement = ""
        }
        if ($DefaultResponse -eq $null -or $DefaultResponse -eq ""){
            $DefaultResponse="Proceeding"
        }

        if ($null -eq $DefaultResponse) {
            Write-Host "$Message $TimeoutStatement"
        } else {
            Write-Host "$Message $TimeoutStatement - Noninteractive mode. Assuming response of ($DefaultResponse) after timeout."
        }

        # Apply timeout if specified
        if ($Timeout -gt 0) {
            Start-Sleep -Seconds $Timeout
        }

        return $DefaultResponse
    } else {
        # Interactive mode
        return Read-Host -Prompt $Message
    }
}
function Confirm-Import {
    param(
        [string]$ImportObjectName,
        [PSCustomObject]$ImportObject,
        [String]$ImportSetting
    )
    if ($ImportSetting -eq "S") {
        $ImportConfirm = Read-Host "Would you like to migrate: $ImportObjectName Y/n"
        if ($ImportConfirm -notin @("Y", "y")) {
            Write-Host "$ImportObjectName has been skipped"
            $ImportObject.imported = "Not-Migrated"
            continue
        }	
    }
}
function Get-ConfigurationsImportMode {
    $ImportOption = Write-TimedMessage -Message "[1] [2] [3]" -Timeout 3 -DefaultResponse $(if ($true -eq $settings.SplitConfigurations) {2} else {1})
    if (!($ImportOption -in @(1, 2, 3))) {
        Write-Host "Please select 1, 2 or 3"
        $ImportOption = Get-ConfigurationsImportMode -ImportName $ImportName
    }
		
    return $ImportOption
}

function Get-ImportMode {
    param(
        [string]$ImportName
    )
    Write-Host "Importing $ImportName"
    $ImportOption = $(Write-TimedMessage -Timeout 8 -DefaultResponse "A" -Message "[A] Import All unmapped $ImportName. [N] Import None of the unmapped $ImportName. [S] Select for each individual $ImportName (A/N/S)")
    if (!($ImportOption -in @("A", "N", "S"))) {
        Write-Host "Please select A, N or S"
        $ImportOption = Get-ImportMode -ImportName $ImportName
    }
		
    return $ImportOption
}
function Get-FlexLayoutImportMode {
    $ImportOption = Write-TimedMessage -Message "[1] [2]" -Timeout 3 -DefaultResponse 1
    if (!($ImportOption -in @(1, 2))) {
        Write-Host "Please select 1 or 2"
        $ImportOption = Get-FlexLayoutImportMode -ImportName $ImportName
    }
		
    return $ImportOption
}

# Keep the optional flag helpers available after Full/Lite initialization, as before.
if (-not (Get-Command -Name Get-UserFlagSetup -ErrorAction SilentlyContinue)) {
    function Set-OptionalFlags {
      param(
        [system.object[]]$ObjectFlagMap,
        [pscustomobject]$Object,
        [string]$ObjectType
      )
      if ($null -eq $Object -or $null -eq $object.id -or $object.id -lt 1) {
        write-warning "bad object id $($object.id)"
        return
      }

      # possible cononical names for object types (itglue-side). Generally mapped in flag map as plurals
      $mapKey = switch ($ObjectType.ToLower()) {
        'company'        { 'Companies' }
        'configuration'  { 'Configurations' }
        'location'       { 'Locations' }
        'Checklist'      { 'Checklists' }
        default          { $ObjectType }
      }

      # cononical names from itglue-side mapped to flagable_types on hudu-side. these have more open-ended naming
      $flagableType = switch ($ObjectType.ToLower()) {
        'company'        { 'Company' }
        'companies'      { 'Company' }
        'articles'       { 'Article' }
        'websites'       { 'Website' }
        'passwords'      { 'AssetPassword' }
        'contacts'       { 'Asset' }
        'configuration'  { 'Asset' }
        'location'       { 'Asset' }
        'checklist'      { 'Procedure' }
        'checklists'     { 'Procedure' }
        default          { 'Asset' }
      }

      $flagType = $ObjectFlagMap.$mapKey
      if (-not $flagType) {
        Write-Warning "No FlagType configured for ObjectType='$ObjectType' (mapKey='$mapKey'). Skipping."
        return
      }

      try {
        New-HuduFlag -FlagTypeID $flagType.id -FlagableType $flagableType -Flagable_Id $Object.id
      } catch {
        Write-Error "Failed to add flag to $ObjectType '$($Object.Name)'. Error: $_"
      }
    }

    function Get-UserFlagSetup {

            $ObjectFlagMap = @{}
            $completedFlagSetup = $false
            while ($completedFlagSetup -ne $true){
                $flagColor = $null; $flagColor = Select-ObjectFromList -message "Select the color to use for a new flag type. First we create flag types, then we attribute flag types to the objects that you'd like. Select a Color or Enter '0' or 1-'None' to skip creating FlagTypes if you already created some in Hudu." -objects @('None', 'red', 'crimson', 'scarlet', 'rot', 'karminrot', 'scharlachrot', 'rouge', 'cramoisi', 'écarlate', 'rosso', 'cremisi', 'scarlatto', 'rojo', 'carmesí', 'escarlata', 'blue', 'navy', 'blau', 'marineblau', 'bleu', 'bleu marine', 'blu', 'blu navy', 'azul', 'azul marino', 'green', 'lime', 'grün', 'limettengrün', 'vert', 'vert citron', 'verde', 'verde lime', 'verde lima', 'yellow', 'gold', 'gelb', 'jaune', 'or', 'giallo', 'oro', 'amarillo', 'purple', 'violet', 'lila', 'violett', 'pourpre', 'viola', 'porpora', 'púrpura', 'violeta', 'orange', 'arancione', 'naranja', 'light pink', 'pink', 'baby pink', 'hellrosa', 'rosa', 'rose clair', 'rose', 'rosa chiaro', 'rosa claro', 'light blue', 'baby blue', 'sky blue', 'hellblau', 'babyblau', 'himmelblau', 'bleu clair', 'bleu ciel', 'azzurro', 'blu chiaro', 'azul claro', 'celeste', 'light green', 'mint', 'hellgrün', 'mintgrün', 'vert clair', 'menthe', 'verde chiaro', 'menta', 'verde claro', 'light purple', 'lavender', 'helllila', 'lavendel', 'violet clair', 'lavande', 'viola chiaro', 'lavanda', 'morado claro', 'light orange', 'peach', 'hellorange', 'pfirsich', 'orange clair', 'pêche', 'arancione chiaro', 'pesca', 'naranja claro', 'melocotón', 'light yellow', 'cream', 'hellgelb', 'creme', 'jaune clair', 'crème', 'giallo chiaro', 'crema', 'amarillo claro', 'white', 'weiß', 'blanc', 'bianco', 'blanco', 'grey', 'gray', 'silver', 'grau', 'silber', 'gris', 'argent', 'grigio', 'argento', 'plateado', 'lightpink', 'lightblue', 'lightgreen', 'lightpurple', 'lightorange', 'lightyellow') -allowNull $true;
                if ($null -eq $flagColor -or $flagColor -ieq "None"){
                    $completedFlagSetup = $true
                    break
                }
                $flagName = $null; $flagName = $(Read-Host "Enter the Name of your New Flag Type to use with color $flagColor") ?? "$flagColor Flag"
                if ([string]::IsNullOrWhiteSpace($flagName)){
                    write-error "Empty flag name, try again or enter NONE at the next prompt to finish."
                } else {
                    try {
                        New-HuduFlagType -Color $flagColor -Name $flagName
                    } catch {
                        Write-Error "Failed to create FlagType $flagName with color $flagColor. It may already exist. Error: $_" -ForegroundColor Yellow
                    }
                }
            }
            $SelectableFlagTypes = Get-HuduFlagTypes
            if ($SelectableFlagTypes.count -eq 0){
                Write-Error "No flag types found in Hudu. You can either create these in this setup or create them directly in Hudu, but you'll need flag types to exist before you can attribute flag types to objects"
                return [PSCustomObject]@{
                    AllowSettingFlags = $false
                    ObjectFlagMap     = @{}
                    $passwordFlagCategories = $false
                }
            }
            $passwordFlagCategories = ("yes" -eq $(Select-Objectfromlist -objects @("yes","no") -message "Would you like to attribute flags to passwords per password-category" -allowNull $false -inspectObjects $false) -eq "no")
            if ($true -eq $passwordFlagCategories){
                $FlagableObjects = @("Companies","Locations","Contacts","Configurations","Assets","Articles","Websites","Checklists")
            } else {
                $FlagableObjects = @("Companies","Locations","Contacts","Configurations","Assets","Articles","Websites","Passwords","Checklists")
            }


            Write-Host "Done setting up flagtypes, Now we can attribute them to certain source objects to-be migrated."
            foreach ($flagable in $FlagableObjects){
                $selectedFlagType = $null; $selectedFlagType = Select-ObjectFromList -message "Select the Flag Type to attribute to incoming '$($flagable)' objects. Select '0' or 'None' to skip attributing this flagtype." -objects $SelectableFlagTypes -allowNull $true -inspectObjects $true;
                if ($null -eq $selectedFlagType){continue}
                $ObjectFlagMap["$flagable"] = $selectedFlagType
            }
            if ($ObjectFlagMap.Keys.count -gt 0){
                $allowSettingFlagsAndTypes = $true
            } else {
                Write-Host "No Flag Types were selected for any objects, skipping flag attribution." -ForegroundColor Yellow
                return [PSCustomObject]@{
                    AllowSettingFlags = $false
                    ObjectFlagMap     = $ObjectFlagMap
                    passwordFlagCategories = $passwordFlagCategories
                }
            }
        $completedFlagSetup = $true

        return [PSCustomObject]@{
            AllowSettingFlags = $allowSettingFlagsAndTypes
            ObjectFlagMap     = $ObjectFlagMap
            passwordFlagCategories = $passwordFlagCategories
        }
    }
}
