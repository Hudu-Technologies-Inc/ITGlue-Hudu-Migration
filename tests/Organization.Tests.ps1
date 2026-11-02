#requires -Version 7.5.1
# Offline regression checks for moved jobs, caller scope, and fresh layout data.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$checks = 0
function Assert-Organization {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    $script:checks++
}

$files = @(Get-Item -LiteralPath (Join-Path $repoRoot 'ITGlue-Hudu-Migration.ps1'), (Join-Path $repoRoot 'Initialize-Module.ps1'), (Join-Path $repoRoot 'Get-MissingRelations.ps1'), (Join-Path $repoRoot 'Add-HuduAttachmentsViaAPI.ps1')) +
    @(Get-ChildItem -LiteralPath (Join-Path $repoRoot 'Public'), (Join-Path $repoRoot 'Private') -Recurse -File -Filter '*.ps1')
foreach ($file in $files) {
    $tokens = $null; $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
    Assert-Organization ($parseErrors.Count -eq 0) "Parse errors in $($file.Name)."
    foreach ($import in $ast.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.InvocationOperator -eq [Management.Automation.Language.TokenKind]::Dot}, $true)) {
        $element = $import.CommandElements[0]
        if (-not $element.PSObject.Properties['Value']) { continue }
        $path = $element.Value
        if ($path.StartsWith('$PSScriptRoot', [StringComparison]::OrdinalIgnoreCase)) {
            $path = $file.DirectoryName + $path.Substring('$PSScriptRoot'.Length)
        }
        if ($path -match '\$' -or $path -notlike '*.ps1') { continue }
        if (-not [IO.Path]::IsPathRooted($path)) { $path = Join-Path $repoRoot $path }
        Assert-Organization (Test-Path -LiteralPath $path -PathType Leaf) "Missing dot-source target in $($file.Name): $path"
    }
}

& {
    # Loading definitions must not reset arrays belonging to an existing run.
    $LocAssetLayoutFields = 'existing locations'; $ConfigAssetLayoutFields = 'existing configurations'
    $ConAssetLayoutFields = 'existing contacts'; $TempLayoutFields = 'existing flexible fields'
    . (Join-Path $repoRoot 'Public/LayoutFields.ps1')
    Assert-Organization ($LocAssetLayoutFields -eq 'existing locations' -and $ConfigAssetLayoutFields -eq 'existing configurations' -and $ConAssetLayoutFields -eq 'existing contacts' -and $TempLayoutFields -eq 'existing flexible fields') 'Importing layout helpers changed run state.'

    $expectedLabels = [ordered]@{
        Locations = 'Address 1|Address 2|City|Postal Code|Region|Country|Phone|Fax|Notes|ITG Date Created|ITG Date Last Updated'
        Configurations = 'Hostname|Primary IP|MAC Address|Default Gateway|Serial Number|Asset Tag|Position|Installed By|Purchased By|Notes|Operating System Notes|Warranty Expires At|Installed At|Purchased At|Configuration Type Name|Configuration Type Kind|Manufacturer Name|Model ID|Operating System Name|Model Name|Contact Name|ITG Date Created|ITG Date Last Updated'
        Contacts = 'First Name|Last Name|Title|Contact Type|Notes|Emails|Phones|ITG Date Created|ITG Date Last Updated'
        FlexibleAssets = 'ITG Date Created|ITG Date Last Updated|Imported from ITGlue|ITGlue URL|ITGlue ID'
    }
    foreach ($layoutType in $expectedLabels.Keys) {
        $first = @(New-MigrationLayoutFields -LayoutType $layoutType)
        $second = @(New-MigrationLayoutFields -LayoutType $layoutType)
        Assert-Organization (($first.label -join '|') -ceq $expectedLabels[$layoutType]) "Default field order changed for $layoutType."
        for ($index = 0; $index -lt $first.Count; $index++) {
            Assert-Organization (-not [object]::ReferenceEquals($first[$index], $second[$index])) "Layout field definitions are shared between requests: $layoutType."
        }
        $first[0].label = 'Modified by a request'
        $first += @{label='Location';field_type='AssetTag';position=999}
        $next = @(New-MigrationLayoutFields -LayoutType $layoutType)
        Assert-Organization (($next.label -join '|') -ceq $expectedLabels[$layoutType]) "A previous request changed later $layoutType fields."
    }
}

$mainAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'ITGlue-Hudu-Migration.ps1'), [ref]$tokens, [ref]$parseErrors)
$fieldAssignments = @($mainAst.FindAll({param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Right.Extent.Text -like 'New-MigrationLayoutFields *'}, $true))
Assert-Organization ($fieldAssignments.Count -eq 4) 'A layout is no longer initialized at its migration phase.'
$flexibleAssignment = $fieldAssignments | Where-Object { $_.Left.Extent.Text -eq '$TempLayoutFields' }
$ancestor = $flexibleAssignment.Parent
while ($ancestor -and $ancestor -isnot [Management.Automation.Language.ForEachStatementAst]) { $ancestor = $ancestor.Parent }
Assert-Organization ($null -ne $ancestor -and $ancestor.Variable.VariablePath.UserPath -eq 'UnmatchedLayout') 'Flexible asset fields are not recreated for each layout.'

& {
    . (Join-Path $repoRoot 'Private/User-Options.ps1')
    foreach ($name in @('Write-TimedMessage', 'Confirm-Import', 'Get-ImportMode', 'Get-FlexLayoutImportMode', 'Get-UserFlagSetup', 'Set-OptionalFlags')) {
        Assert-Organization ($null -ne (Get-Command -Name $name -CommandType Function -ErrorAction Ignore)) "Helper unavailable after initialization: $name."
    }
    $NonInteractive = $true
    $sleepCalls = [Collections.Generic.List[int]]::new()
    function Start-Sleep { param([int]$Seconds) $sleepCalls.Add($Seconds) }
    $choice = Get-ImportMode -ImportName 'Offline fixture' 6>$null
    Assert-Organization ($choice -eq 'A' -and $sleepCalls.Count -eq 1 -and $sleepCalls[0] -eq 8) 'The intentional timeout correction was lost.'

    # Preserve an existing helper override, as the original conditional import did.
    function Get-UserFlagSetup { return 'existing helper' }
    . (Join-Path $repoRoot 'Private/User-Options.ps1')
    Assert-Organization ((Get-UserFlagSetup) -eq 'existing helper') 'Loading options replaced an existing flag setup helper.'

    . (Join-Path $repoRoot 'Private/Import-Items.ps1')
    $MigrationName = 'Offline fixture'
    $seenPages = [Collections.Generic.List[int]]::new()
    $selection = {
        $seenPages.Add($i)
        if ($i -eq 1) { 1..1000 | ForEach-Object { [pscustomobject]@{id=$_} } }
        elseif ($i -eq 2) { 1001..1003 | ForEach-Object { [pscustomobject]@{id=$_} } }
        else { throw "Unexpected page $i." }
    }
    $items = @(Import-ITGlueItems -ItemSelect $selection 6>$null)
    Assert-Organization ($items.Count -eq 1003 -and ($seenPages -join ',') -eq '1,2') 'The consolidated paging helper lost callback scope.'
}

Write-Output "Passed $checks organization checks (offline; imports, layout lifetime, helper availability, and paging scope)."
