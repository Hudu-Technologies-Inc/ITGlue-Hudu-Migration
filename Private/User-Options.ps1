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