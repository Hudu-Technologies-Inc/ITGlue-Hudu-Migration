#requires -Version 7.5.1
# Offline checks for live caller state, reference updates, and nested run isolation.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$checks = 0
function Assert-HelperScope {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    $script:checks++
}

$tokens = $null; $parseErrors = $null
$mainAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'ITGlue-Hudu-Migration.ps1'), [ref]$tokens, [ref]$parseErrors)
Assert-HelperScope ($parseErrors.Count -eq 0) 'The main script failed to parse.'
$definitions = @($mainAst.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]}, $true))
Assert-HelperScope ($definitions.Count -eq 0) 'Function definitions remain in the main script.'

$initAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'Initialize-Module.ps1'), [ref]$tokens, [ref]$parseErrors)
Assert-HelperScope ($parseErrors.Count -eq 0) 'Initialization failed to parse.'
$helperPaths = @(
    'Private\Stop-ITGlueExportBootstrapJobIfRunning.ps1'
    'Public\Get-HuduLocationAssetTagValue.ps1'
    'Public\Add-HuduLocationAssetTagLayoutField.ps1'
)
# Exercise the real import statements without running setup, prompts, or API work.
$importCode = foreach ($relativePath in $helperPaths) {
    $statement = @($initAst.EndBlock.Statements | Where-Object { $_.Extent.Text -eq ". `$PSScriptRoot\$relativePath" })
    Assert-HelperScope ($statement.Count -eq 1) "Missing direct helper import: $relativePath"
    $statement[0].Extent.Text.Replace('$PSScriptRoot', '$repoRoot')
}
$importCode = $importCode -join "`n"

# Seed a parent run so accidentally using script/global state is detectable.
$ITGLocationsHashTable = @{'7' = @{HuduID=700;Name='Parent'}}
$LocationLayout = @{ID=700}
$ITGlueExportBootstrapJob = [pscustomobject]@{Id=700;State='Running'}
& {
    . ([scriptblock]::Create($importCode))

    # State is assigned after importing, as it is in the main migration.
    $ITGLocationsHashTable = @{}
    $LocationLayout = $null
    $ITGlueExportBootstrapJob = $null
    Assert-HelperScope ($null -eq (Get-HuduLocationAssetTagValue -ITGLocationId $null)) 'A null location produced a tag.'
    Assert-HelperScope ($null -eq (Get-HuduLocationAssetTagValue -ITGLocationId '7')) 'The helper used the parent run instead of the empty current mapping.'
    $fields = @(@{label='Existing'})
    $added = Add-HuduLocationAssetTagLayoutField -AssetLayoutFields ([ref]$fields) -Position 5 -LayoutName 'Contacts' 6>$null
    Assert-HelperScope (-not $added -and $fields.Count -eq 1) 'A missing current layout used parent state or changed the fields.'

    $ITGLocationsHashTable = @{'7' = @{HuduID=71;Name='First';id=$null}}
    $LocationLayout = @{ID=71}
    $tag = @(Get-HuduLocationAssetTagValue -ITGLocationId 7 | ConvertFrom-Json)
    Assert-HelperScope ($tag.Count -eq 1 -and $tag[0].id -eq 71 -and $tag[0].name -eq 'First') 'The helper did not read mappings populated after import.'
    $added = Add-HuduLocationAssetTagLayoutField -AssetLayoutFields ([ref]$fields) -Position 5 -LayoutName 'Contacts'
    Assert-HelperScope ($added -and $fields.Count -eq 2 -and $fields[1].linkable_id -eq 71 -and $fields[1].position -eq 5) 'Reference updates did not reach the caller array.'

    # Replacing state must affect subsequent calls without reimporting helpers.
    $ITGLocationsHashTable = @{'7' = @{HuduID=$null;id=72;name='Second'}}
    $LocationLayout = @{ID=72}
    $tag = @(Get-HuduLocationAssetTagValue -ITGLocationId '7' | ConvertFrom-Json)
    Assert-HelperScope ($tag[0].id -eq 72 -and $tag[0].name -eq 'Second') 'Location replacement or the fallback id/name mapping was lost.'
    $null = Add-HuduLocationAssetTagLayoutField -AssetLayoutFields ([ref]$fields) -Position 21 -LayoutName 'Configurations'
    Assert-HelperScope ($fields.Count -eq 3 -and $fields[2].linkable_id -eq 72 -and $fields[1].linkable_id -eq 71) 'Layout replacement used stale state or changed an existing field.'
    $ITGLocationsHashTable['8'] = @{HuduID=$null;id=$null;Name='Unmigrated'}
    Assert-HelperScope ($null -eq (Get-HuduLocationAssetTagValue -ITGLocationId '8')) 'An unmigrated location produced a tag.'

    $jobActions = [Collections.Generic.List[object]]::new()
    function Stop-Job {
        param($Job, $ErrorAction)
        $jobActions.Add([pscustomobject]@{Action='Stop';Job=$Job})
    }
    function Remove-Job {
        param($Job, [switch]$Force, $ErrorAction)
        $jobActions.Add([pscustomobject]@{Action='Remove';Job=$Job})
    }
    Stop-ITGlueExportBootstrapJobIfRunning
    Assert-HelperScope ($jobActions.Count -eq 0) 'A null current job affected the parent run.'
    $ITGlueExportBootstrapJob = [pscustomobject]@{Id=71;State='Running'}
    Stop-ITGlueExportBootstrapJobIfRunning 6>$null
    Assert-HelperScope ($jobActions.Count -eq 2 -and $jobActions[0].Action -eq 'Stop' -and $jobActions[1].Action -eq 'Remove') 'A running job was not stopped and removed.'
    Assert-HelperScope ([object]::ReferenceEquals($jobActions[0].Job, $ITGlueExportBootstrapJob) -and [object]::ReferenceEquals($jobActions[1].Job, $ITGlueExportBootstrapJob)) 'Cleanup targeted a different run job.'
    $ITGlueExportBootstrapJob = [pscustomobject]@{Id=72;State='Completed'}
    Stop-ITGlueExportBootstrapJobIfRunning
    Assert-HelperScope ($jobActions.Count -eq 3 -and $jobActions[2].Action -eq 'Remove' -and $jobActions[2].Job.Id -eq 72) 'Cleanup did not use the replacement completed job.'

    & {
        # These calls also represent preparation callbacks running in child scopes.
        $ITGLocationsHashTable = @{'7' = @{HuduID=73;Name='Nested'}}
        $LocationLayout = @{ID=73}
        $ITGlueExportBootstrapJob = [pscustomobject]@{Id=73;State='Completed'}
        $nestedFields = @()
        $tag = @(Get-HuduLocationAssetTagValue -ITGLocationId 7 | ConvertFrom-Json)
        Assert-HelperScope ($tag[0].id -eq 73) 'A nested caller used another scope location mapping.'
        $null = Add-HuduLocationAssetTagLayoutField -AssetLayoutFields ([ref]$nestedFields) -Position 5 -LayoutName 'Nested'
        Assert-HelperScope ($nestedFields.Count -eq 1 -and $nestedFields[0].linkable_id -eq 73) 'Nested reference updates or layout lookup escaped the caller scope.'
        Stop-ITGlueExportBootstrapJobIfRunning
        Assert-HelperScope ($jobActions.Count -eq 4 -and $jobActions[3].Job.Id -eq 73) 'Nested cleanup used another scope job.'
    }
    Assert-HelperScope ($LocationLayout.ID -eq 72 -and $ITGLocationsHashTable['7'].id -eq 72 -and $ITGlueExportBootstrapJob.Id -eq 72) 'Nested helper calls changed the owning run state.'
}
Assert-HelperScope ($LocationLayout.ID -eq 700 -and $ITGLocationsHashTable['7'].HuduID -eq 700 -and $ITGlueExportBootstrapJob.Id -eq 700) 'Helper calls changed the parent run state.'
Assert-HelperScope ($null -eq (Get-Command Get-HuduLocationAssetTagValue -ErrorAction Ignore)) 'Dot-sourcing helpers leaked functions into the parent scope.'
Write-Output "Passed $checks migration helper scope checks (offline)."
