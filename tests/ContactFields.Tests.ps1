#requires -Version 7.5.1
# Offline contact selection, preservation, layout, and real callback checks.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
. "$repoRoot/Public/Get-HuduContactCommunicationFields.ps1"
. "$repoRoot/Public/LayoutFields.ps1"
$checks = 0
function Assert-Contact {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    $script:checks++
}

$layout = @(New-MigrationLayoutFields -LayoutType Contacts)
foreach ($definition in @(@{Label='Emails';Type='Email'}, @{Label='Phones';Type='Phone'}, @{Label='Notes';Type='RichText'})) {
    $field = @($layout | Where-Object { $_.label -eq $definition.Label })
    Assert-Contact ($field.Count -eq 1 -and $field[0].field_type -eq $definition.Type) "Wrong field type or duplicate $($definition.Label) field."
    if ($definition.Label -ne 'Notes') {
        Assert-Contact ($field[0].show_in_list -eq 'true') "$($definition.Label) is hidden in the grid."
    }
}

# Same shape as the supplied ITGlue contact, deserialized as API data would be.
$contact = @{
    id = '59401285'
    attributes = @{
        name = 'Daniel Crews'; 'first-name' = 'Daniel'; 'last-name' = 'Crews'
        title = $null; 'contact-type-name' = 'GONE/no longer there'; 'location-id' = $null
        notes = $null; 'created-at' = '2025-03-05T10:22:33Z'; 'updated-at' = '2026-10-31T22:52:17Z'
        'contact-emails' = @(@{primary=$true;value='Daniel.Crews@example.com';'label-name'='Email'})
        'contact-phones' = @(@{primary=$true;value='+19514543551';extension=$null;'label-name'='Direct';'label-type'='phone';'formatted-value'='+1 (951) 454-3551'})
    }
} | ConvertTo-Json -Depth 10 | ConvertFrom-Json
$fields = Get-HuduContactCommunicationFields -Attributes $contact.attributes
Assert-Contact ($fields.emails -ceq 'Daniel.Crews@example.com' -and $fields.phones -ceq '+19514543551') 'Single primary values did not reach native fields as plain strings.'
Assert-Contact ($fields.notes -ceq '') 'A contact without notes or overflow gained empty markup.'

foreach ($attributes in @($null, @{}, @{notes='<p>Keep <strong>original notes</strong>.</p>'}, @{'contact-emails'=@();'contact-phones'=@()})) {
    $fields = Get-HuduContactCommunicationFields -Attributes $attributes
    Assert-Contact ($null -eq $fields.emails -and $null -eq $fields.phones) 'Empty contact arrays produced nonempty native fields.'
    $expectedNotes = if ($null -ne $attributes -and $attributes.ContainsKey('notes')) { $attributes.notes } else { '' }
    Assert-Contact ($fields.notes -ceq $expectedNotes) 'Empty arrays changed existing notes or added empty headings.'
}

$attributes = @{
    notes = '<p>Existing <strong>rich notes</strong>.</p>'
    'contact-emails' = @(
        @{value='   ';primary=$true},
        @{value='personal@example.com';'label-name'='Personal'},
        @{value='work@example.com';'label-name'='Work';primary=$true},
        @{value='other@example.com';primary=$true}
    )
    'contact-phones' = @(
        @{value='+15550001';'label-name'='Mobile';primary=$true},
        @{value='+15550002';'label-name'='Work';primary=$true},
        @{value='+15550003';'label-name'='Direct'},
        @{value='+15550004';'label-name'='direct';primary=$true;extension='042';'formatted-value'='+1 (555) 0004'}
    )
}
$before = $attributes | ConvertTo-Json -Depth 10 -Compress
$fields = Get-HuduContactCommunicationFields -Attributes $attributes
Assert-Contact ($fields.emails -ceq 'work@example.com') 'Primary email did not win, or source-order tie breaking changed.'
Assert-Contact ($fields.phones -ceq '+15550004') 'Direct or primary-within-Direct preference failed.'
Assert-Contact ($fields.notes.StartsWith($attributes.notes + "`n")) 'Source rich text was not preserved before overflow.'
Assert-Contact ($fields.notes.Contains('href="mailto:personal@example.com"') -and $fields.notes.Contains('Personal: personal@example.com')) 'Overflow email lost its link, value, or label.'
Assert-Contact (-not $fields.notes.Contains('work@example.com')) 'The selected email was unnecessarily duplicated in Notes.'
Assert-Contact ($fields.notes.Contains('href="tel:+15550004;ext=042"') -and $fields.notes.Contains('direct: +1 (555) 0004 ext. 042')) 'Selected phone extension or formatted display was lost.'
foreach ($number in @('+15550001', '+15550002', '+15550003')) {
    Assert-Contact ($fields.notes.Contains('href="tel:' + $number + '"')) "Overflow phone $number was omitted."
}
Assert-Contact (($attributes | ConvertTo-Json -Depth 10 -Compress) -ceq $before) 'Preparing contact fields mutated the source data.'

$fields = Get-HuduContactCommunicationFields -Attributes @{
    'contact-emails'=@(@{value='first@example.com';primary='false'}, @{value='second@example.com';primary=$false})
    'contact-phones'=@(@{value='100';'label-name'='Home';primary=$true}, @{value='200';'label-name'=' Work Phone '})
}
Assert-Contact ($fields.emails -ceq 'first@example.com') 'Email fallback was not the first available value.'
Assert-Contact ($fields.phones -ceq '200') 'Work did not beat a primary phone with another label.'
$fields = Get-HuduContactCommunicationFields -Attributes @{
    'contact-emails'=@(@{value='first@example.com';primary='false'}, @{value='second@example.com';primary=$true})
    'contact-phones'=@(@{value='100';'label-name'='Home'}, @{value='200';'label-name'='Mobile';primary=$true})
}
Assert-Contact ($fields.emails -ceq 'second@example.com' -and $fields.phones -ceq '200') 'Primary fallback failed or a string false was treated as true.'
$fields = Get-HuduContactCommunicationFields -Attributes @{
    'contact-phones'=@(@{value='100'}, @{value='200'})
}
Assert-Contact ($fields.phones -ceq '100' -and $fields.notes.Contains('Phone: 200')) 'First phone fallback or default label failed.'

# Retain formatted-only values and extension-only records without empty links.
$fields = Get-HuduContactCommunicationFields -Attributes @{
    'contact-phones'=@(@{'formatted-value'='+1 (555) 0100';'label-name'='Direct'}, @{extension='9';'label-name'='Desk'})
}
Assert-Contact ($fields.phones -ceq '+1 (555) 0100') 'A formatted-only phone was dropped.'
Assert-Contact ($fields.notes.Contains('Desk:  ext. 9') -and -not $fields.notes.Contains('href=')) 'An extension-only record was lost or made into an invalid link.'

# Encode labels and URI attributes, while preserving existing rich text verbatim.
$fields = Get-HuduContactCommunicationFields -Attributes @{
    'contact-emails'=@(@{value='first@example.com'}, @{value='a+tag&b@example.com';'label-name'='<Work & Personal>'})
    'contact-phones'=@(@{value='100';'label-name'='Direct'}, @{value='200';extension='4&5';'label-name'='Home "desk" <x>'})
}
Assert-Contact ($fields.notes.Contains('&lt;Work &amp; Personal&gt;: a+tag&amp;b@example.com')) 'Email labels or visible values were not HTML encoded.'
Assert-Contact ($fields.notes.Contains('href="mailto:a%2Btag%26b@example.com"')) 'Email URI characters were not escaped.'
Assert-Contact ($fields.notes.Contains('Home &quot;desk&quot; &lt;x&gt;: 200 ext. 4&amp;5') -and $fields.notes.Contains('tel:200;ext=4%265')) 'Phone markup or extension URI was not escaped.'
Assert-Contact (-not $fields.notes.Contains('mailto://') -and -not $fields.notes.Contains('tel://')) 'Nonstandard contact URI prefixes were emitted.'

$fields = Get-HuduContactCommunicationFields -Attributes @{
    'contact-emails'=@(@{value='shared@example.com';primary=$true}, @{value='shared@example.com';'label-name'='Alternate label'})
}
Assert-Contact ($fields.notes.Contains('Alternate label: shared@example.com')) 'An alternate label was dropped when values were duplicated.'

# Execute the real initialization import and mapping callback, without setup/API work.
$tokens = $null; $parseErrors = $null
$initAst = [Management.Automation.Language.Parser]::ParseFile("$repoRoot/Initialize-Module.ps1", [ref]$tokens, [ref]$parseErrors)
Assert-Contact ($parseErrors.Count -eq 0) 'Initialization has parse errors.'
$helperImport = @($initAst.EndBlock.Statements | Where-Object { $_.Extent.Text -eq '. $PSScriptRoot\Public\Get-HuduContactCommunicationFields.ps1' })
Assert-Contact ($helperImport.Count -eq 1) 'The contact helper is not loaded by initialization.'
. ([scriptblock]::Create($helperImport[0].Extent.Text.Replace('$PSScriptRoot', '$repoRoot')))
$mainAst = [Management.Automation.Language.Parser]::ParseFile("$repoRoot/ITGlue-Hudu-Migration.ps1", [ref]$tokens, [ref]$parseErrors)
Assert-Contact ($parseErrors.Count -eq 0) 'The main migration has parse errors.'
$mapping = @($mainAst.FindAll({param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$ConAssetFieldsMap'}, $true))
Assert-Contact ($mapping.Count -eq 1) 'Contacts no longer use one shared mapping callback.'
. ([scriptblock]::Create($mapping[0].Extent.Text))
$locationCalls = [System.Collections.Generic.List[object]]::new()
function Get-HuduLocationAssetTagValue {
    param($ITGLocationId)
    $locationCalls.Add($ITGLocationId)
    return '[{"id":7,"name":"Office"}]'
}
$contact.attributes.notes = $attributes.notes
$contact.attributes.'contact-emails' = $attributes.'contact-emails'
$contact.attributes.'contact-phones' = $attributes.'contact-phones'
$unmatchedImport = [pscustomobject]@{ITGObject=$contact}
foreach ($includeId in @($false, $true)) {
    $settings = @{IncludeITGlueID=$includeId}
    $fields = & $ConAssetFieldsMap
    Assert-Contact ($fields.emails -ceq 'work@example.com' -and $fields.phones -ceq '+15550004' -and $fields.notes.Contains('mailto:personal@example.com')) 'The real callback lost contact selection or overflow.'
    Assert-Contact ($fields.ContainsKey('ITGlue ID') -eq $includeId) 'Optional ITGlue ID behavior changed.'
    Assert-Contact ($fields.'first name' -ceq 'Daniel' -and $fields.'last name' -ceq 'Crews' -and $fields.'contact type' -ceq 'GONE/no longer there') 'The real callback changed other contact fields.'
    Assert-Contact ($fields.location -ceq '[{"id":7,"name":"Office"}]' -and $fields.'ITG Date Created' -eq $contact.attributes.'created-at') 'The real callback lost location or date fields.'
    $payload = @{asset=@{fields=@($fields)}} | ConvertTo-Json -Depth 10 | ConvertFrom-Json
    Assert-Contact ($payload.asset.fields[0].emails -is [string] -and $payload.asset.fields[0].phones -is [string]) 'Serialized native field values are not strings.'
}
Assert-Contact ($locationCalls.Count -eq 2) 'The callback skipped location lookup in one ID mode.'
Write-Output "Passed $checks contact field checks (offline)."
