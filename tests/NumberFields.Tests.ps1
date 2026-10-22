#requires -Version 7.2
# Offline regression checks against the saved 2.48.0 observations and both preparation paths.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../Public/ConvertTo-HuduNumber.ps1"
. "$PSScriptRoot/../Public/Get-CastIfNumeric.ps1"
. "$PSScriptRoot/../Public/Invoke-FastFlexibleAssetFieldPreparation.ps1"
. "$PSScriptRoot/../Public/Start-FlexAssets.ps1"
$checks = 0
function Assert-Number { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message }; $script:checks++ }
$plain = @{ field_type = 'Number'; number_type = 'number' }
$percent = @{ field_type = 'Number'; number_type = 'percentage' }
$usd = @{ field_type = 'Number'; number_type = 'currency'; currency_code = 'USD' }
$longFraction = '0.1234567890123456789012345678901234567890123456789'
foreach ($text in @('0','0.01','-0.01','12.34','2147483648','9007199254740993','9223372036854775807','-9223372036854775807', $longFraction)) {
    $actual = ConvertTo-HuduNumber $text $plain
    Assert-Number ($actual.IsValid -and $actual.Value -ceq $text -and $actual.Value -is [string]) "Plain number lost precision: $text"
}
foreach ($text in @('9223372036854775808','-9223372036854775808','9223372036854775807.01','-9223372036854775807.01','1e-325','1e3','$12.34','12.5%','π','NaN','Infinity','1+2i','12,34','1,234.56','null')) {
    Assert-Number (-not (ConvertTo-HuduNumber $text $plain).IsValid) "Invalid text accepted: $text"
}
foreach ($value in @($false, $true, @(), @{}, [double]::NaN, [double]::PositiveInfinity)) {
    Assert-Number (-not (ConvertTo-HuduNumber -Value $value -FieldDefinition $plain).IsValid) 'Nondecimal value was coerced.'
}
foreach ($value in @($null, '', '  ')) {
    $actual = ConvertTo-HuduNumber $value $plain
    Assert-Number ($actual.IsValid -and $actual.IsEmpty -and $null -eq $actual.Value) 'Empty source must remain an omitted value.'
}
Assert-Number ((ConvertTo-HuduNumber ' +00012.3400 ' $plain).Value -ceq '12.34') 'Canonicalization changed magnitude.'
Assert-Number ((ConvertTo-HuduNumber '-0.000' $plain).Value -ceq '0') 'Negative zero was not preserved numerically.'
Assert-Number ((ConvertTo-HuduNumber '12.34' $usd).IsValid) 'USD cents rejected.'
Assert-Number (-not (ConvertTo-HuduNumber '12.345' $usd).IsValid) 'USD extra decimal was rounded or accepted.'
Assert-Number ((ConvertTo-HuduNumber '-1' $usd).IsValid) 'USD negative rejected.'
Assert-Number ((ConvertTo-HuduNumber '-2147483649' $percent).IsValid) 'Negative percentage rejected.'
Assert-Number ((ConvertTo-HuduNumber '100' $percent).IsValid) '100 percent rejected.'
Assert-Number (-not (ConvertTo-HuduNumber '100.01' $percent).IsValid) 'Percentage above 100 accepted.'
Assert-Number ((ConvertTo-HuduNumber '12.5' $percent).Value -ceq '12.5') 'Percentage was rescaled.'
Assert-Number (-not (ConvertTo-HuduNumber '1' @{number_type='currency';currency_code='JPY'}).IsValid) 'Untested currency precision was assumed.'
Assert-Number ((ConvertTo-HuduNumber '1' @{number_type='currency';currency_code='JPY'} -CurrencyDecimalPlaces 0).IsValid) 'Explicit currency precision ignored.'
Assert-Number (-not (ConvertTo-HuduNumber '1.1' @{number_type='currency';currency_code='JPY'} -CurrencyDecimalPlaces 0).IsValid) 'Explicit zero-decimal policy ignored.'
Assert-Number (-not (ConvertTo-HuduNumber '0.01' $plain -CurrentVersion '2.47.0').IsValid) 'Legacy decimal was rounded.'
Assert-Number ((ConvertTo-HuduNumber '2147483647' $plain -CurrentVersion '2.47.0').IsValid) 'Legacy integer rejected.'
Assert-Number (-not (ConvertTo-HuduNumber '2147483648' $plain -CurrentVersion '2.47.0').IsValid) 'Legacy overflow was coerced.'
Assert-Number ((ConvertTo-HuduNumber '0' @{min=0;max=0}).IsValid) 'Zero bounds treated as absent.'
Assert-Number (-not (ConvertTo-HuduNumber '-0.01' @{min=0}).IsValid) 'Minimum ignored.'
Assert-Number (-not (ConvertTo-HuduNumber '1.00000000000000000001' @{max='1.00000000000000000000'}).IsValid) 'High precision bound comparison lost precision.'
Assert-Number ((ConvertTo-HuduNumber '-2' @{min=-3;max=-1}).IsValid) 'Negative bound comparison inverted.'
$previousCulture = [cultureinfo]::CurrentCulture
try {
    [cultureinfo]::CurrentCulture = [cultureinfo]'fr-FR'
    Assert-Number ((ConvertTo-HuduNumber ([decimal]12.34) $plain).Value -ceq '12.34') 'Numeric formatting depends on locale.'
    $float = ConvertTo-HuduNumber ([double]12.34) $plain
    Assert-Number ($float.Value -ceq '12.34' -and [bool]$float.Warning) 'Source float precision warning is missing.'
} finally { [cultureinfo]::CurrentCulture = $previousCulture }
Assert-Number ((Get-CastIfNumeric '0.01') -ceq '0.01') 'Compatibility helper still rounds.'
Assert-Number ((Get-CastIfNumeric '000123ABC') -ceq '000123ABC') 'Compatibility helper changes identifiers.'

$source = [pscustomobject]@{id='42'; attributes=[pscustomobject]@{kind='Percent';decimals=6}}
$mapping = Get-HuduNumberFieldMapping $source
Assert-Number ($mapping.LayoutAttributes.number_type -eq 'percentage' -and $mapping.SourceDecimals -eq 6) 'Explicit Percent metadata was not mapped.'
Assert-Number ($mapping.SourceFieldId -eq '42' -and $mapping.SourceKind -eq 'Percent') 'Source numeric mapping provenance was lost.'
$oldMapping = Get-HuduNumberFieldMapping $source -CurrentVersion '2.47.0'
Assert-Number (-not $oldMapping.LayoutAttributes.ContainsKey('number_type')) 'Subtype attributes leaked to older Hudu.'
$source.attributes.kind = 'Number'
$source.attributes | Add-Member -NotePropertyName name -NotePropertyValue 'Price in USD'
Assert-Number ((Get-HuduNumberFieldMapping $source -CurrencyInference @{Enabled=$false}).LayoutAttributes.number_type -eq 'number') 'Disabled label inference changed the API kind.'
$currencyMapping = Get-HuduNumberFieldMapping $source -Overrides @{'42'=@{NumberType='currency';CurrencyCode='USD'}}
Assert-Number ($currencyMapping.LayoutAttributes.currency_code -eq 'USD' -and $currencyMapping.CurrencyDecimalPlaces -eq 2) 'Explicit currency override not applied.'
Assert-Number ((Get-HuduNumberFieldMapping $source).LayoutAttributes.number_type -eq 'currency') 'Explicit USD label was not inferred.'
$inference = @{ Enabled=$true; DefaultCurrencyCode='USD' }
foreach ($label in @('Monthly cost','Annual Spend','Outstanding debt','Unit price','Budget','Expenses','Service fee','Total ($)','cost_per_month')) {
    $source.attributes.name = $label
    $inferred = Get-HuduNumberFieldMapping $source -CurrencyInference $inference
    Assert-Number ($inferred.LayoutAttributes.number_type -eq 'currency' -and $inferred.LayoutAttributes.currency_code -eq 'USD' -and $inferred.MappingSource -eq 'LabelHeuristic') "Monetary label not inferred: $label"
}
foreach ($label in @('Costume count','Number of users','Cost center','Debt ratio','Cost (%)','Spending ID','Total USD / EUR')) {
    $source.attributes.name = $label
    Assert-Number ((Get-HuduNumberFieldMapping $source -CurrencyInference $inference).LayoutAttributes.number_type -eq 'number') "Nonnumeric/ambiguous currency label inferred: $label"
}
$source.attributes.name = 'Cost ($)'
$unresolved = Get-HuduNumberFieldMapping $source
Assert-Number ($unresolved.LayoutAttributes.number_type -eq 'number' -and $unresolved.CurrencyCandidate -and $unresolved.MappingReason.Contains('unresolved')) 'Dollar symbol assumed USD without configuration.'
$source.attributes.name = 'Cost EUR'
Assert-Number ((Get-HuduNumberFieldMapping $source -CurrencyInference $inference).LayoutAttributes.number_type -eq 'number') 'Unknown EUR precision assumed or explicit EUR replaced with default USD.'
$euro = Get-HuduNumberFieldMapping $source -CurrencyInference @{Enabled=$true;DefaultCurrencyCode='USD';DecimalPlacesByCurrency=@{EUR=2}}
Assert-Number ($euro.LayoutAttributes.currency_code -eq 'EUR') 'Explicit label currency did not take precedence over default currency.'
$source.attributes.name = 'Annual cost'
Assert-Number ((Get-HuduNumberFieldMapping $source -Overrides @{'42'=@{NumberType='number'}} -CurrencyInference $inference).LayoutAttributes.number_type -eq 'number') 'Explicit plain-number override lost to heuristic.'
$source.attributes.kind = 'Percent'
Assert-Number ((Get-HuduNumberFieldMapping $source -CurrencyInference $inference).LayoutAttributes.number_type -eq 'percentage') 'Currency heuristic overrode Percent metadata.'
$source.attributes.kind = 'Number'
$oldInferred = Get-HuduNumberFieldMapping $source -CurrentVersion '2.47.0' -CurrencyInference $inference
Assert-Number (-not $oldInferred.LayoutAttributes.ContainsKey('number_type') -and $oldInferred.SourceNumberType -eq 'number') 'Label heuristic was applied on older Hudu.'
$unknownCurrencyFailed = $false
try { Get-HuduNumberFieldMapping $source -Overrides @{'42'=@{NumberType='currency'}} | Out-Null } catch { $unknownCurrencyFailed = $true }
Assert-Number $unknownCurrencyFailed 'Currency mapping guessed a code.'
$numericField = [pscustomobject]@{FieldType='Number';FieldName='cost';HuduLayoutField=$currencyMapping.LayoutAttributes}
$saved = [pscustomobject]@{fields=@([pscustomobject]@{label='Cost';field_type='Number';number_type='currency';currency_code='USD';min=0})}
Confirm-HuduNumberLayoutMapping @($numericField) $saved '2.48.0'
Assert-Number ($numericField.HuduLayoutField.min -eq 0) 'Saved destination definition was not used.'
$numericField.HuduLayoutField = $currencyMapping.LayoutAttributes
$saved.fields[0].number_type = 'number'
$mismatchFailed = $false
try { Confirm-HuduNumberLayoutMapping @($numericField) $saved '2.48.0' } catch { $mismatchFailed = $true }
Assert-Number $mismatchFailed 'Unpersisted currency subtype was not detected.'

$CurrentVersion = [version]'2.48.0'
$AllFields = @(
    [pscustomobject]@{IGLayoutID=1;ITGParsedName='amount';HuduParsedName='amount';FieldName='Amount';FieldType='Number';HuduLayoutField=$plain},
    [pscustomobject]@{IGLayoutID=1;ITGParsedName='rate';HuduParsedName='rate';FieldName='Rate';FieldType='Percent';HuduLayoutField=$percent},
    [pscustomobject]@{IGLayoutID=1;ITGParsedName='cost';HuduParsedName='cost';FieldName='Cost';FieldType='Number';HuduLayoutField=$usd},
    [pscustomobject]@{IGLayoutID=1;ITGParsedName='identifier';HuduParsedName='identifier';FieldName='Identifier';FieldType='Text';HuduLayoutField=@{field_type='Text'}}
)
$asset = [pscustomobject]@{Name='Numeric test';HuduID=1;PreparationIndex=0;HuduObject=[pscustomobject]@{company_id=1;asset_layout_id=1;company_name='Lab';url='https://example.invalid/asset'};ITGObject=[pscustomobject]@{attributes=[pscustomobject]@{'flexible-asset-type-id'=1;'resource-url'='https://example.invalid/source';traits=[pscustomobject]@{amount=$longFraction;rate='100.01';cost='12.345';identifier='000123'}}}}
$prepared = @(Invoke-FastFlexibleAssetFieldPreparation -Assets @($asset) -AllFields $AllFields -CurrentVersion $CurrentVersion -ThrottleLimit 1)
Assert-Number ($prepared.Count -eq 1 -and $prepared[0].Status -eq 'prepared') 'Parallel preparation failed.'
$wire = @{}
foreach ($entry in $prepared[0].AssetUpdateRequest.Fields) { foreach ($key in $entry.Keys) { $wire[$key] = $entry[$key] } }
Assert-Number ($wire.amount -ceq $longFraction -and $wire.amount -is [string]) 'Parallel numeric precision lost.'
Assert-Number (-not $wire.ContainsKey('rate') -and -not $wire.ContainsKey('cost')) 'Rejected numeric fields were sent.'
Assert-Number ($wire.identifier -ceq '000123') 'Numeric-looking text identifier changed.'
Assert-Number ($prepared[0].ManualActions.Count -eq 2 -and '12.345' -in $prepared[0].ManualActions.Data) 'Invalid originals missing from manual actions.'
$ManualActions = [System.Collections.ArrayList]@()
$serial = Start-FlexibleAssetContentsExample $asset -WarningAction SilentlyContinue
Assert-Number ($serial.amount -ceq $wire.amount -and $serial.identifier -ceq '000123') 'Serial/parallel output differs.'
Assert-Number (-not $serial.ContainsKey('rate') -and -not $serial.ContainsKey('cost') -and $ManualActions.Count -eq 2) 'Serial path does not report invalid numbers.'

# Confirm policy against representative rows from the actual saved API run.
$observations = @(Import-Csv "$PSScriptRoot/fixtures/number-fields-2.48.0.csv")
Assert-Number ($observations.Count -eq 12) 'Expected anonymized 2.48.0 regression observations.'
foreach ($sample in @(
    @{Subtype='Number';Case='decimal-50-string';Accepted=$true},
    @{Subtype='Currency';Case='decimal-three-string';Accepted=$false},
    @{Subtype='Percentage';Case='percent-over-string';Accepted=$false},
    @{Subtype='Number';Case='int64-over-string';Accepted=$false}
)) {
    $row = $observations | Where-Object { $_.Operation -eq 'Create' -and $_.Subtype -eq $sample.Subtype -and $_.CaseId -eq $sample.Case }
    $definition = switch ($sample.Subtype) { Number {$plain} Currency {$usd} Percentage {$percent} }
    $inputText = ConvertFrom-Json -InputObject $row.SubmittedJson
    $actual = ConvertTo-HuduNumber $inputText $definition
    Assert-Number ($actual.IsValid -eq $sample.Accepted -and (($row.HttpStatus -eq '200') -eq $sample.Accepted)) "Policy disagrees with live sample $($sample.Case)."
}
# Exercise the companion transfer helper without starting its UI or calling Hudu.
$tokens = $null; $parseErrors = $null
$transferAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '../Start-HuduAssetLayoutTransfer.ps1'), [ref]$tokens, [ref]$parseErrors)
$transferFunction = $transferAst.FindAll({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-CastIfNumeric'}, $true) | Select-Object -First 1
Invoke-Expression $transferFunction.Extent.Text
Assert-Number ((Get-CastIfNumeric '0.01' -FieldDefinition $plain -CurrentVersion '2.48.0') -ceq '0.01') 'Transfer still rounds decimals.'
Assert-Number ($null -eq (Get-CastIfNumeric '$12.34' -FieldDefinition $usd -CurrentVersion '2.48.0' -WarningAction SilentlyContinue)) 'Transfer stripped currency symbols into digits.'
Assert-Number ($null -eq (Get-CastIfNumeric '9223372036854775808' -FieldDefinition $plain -CurrentVersion '2.48.0' -WarningAction SilentlyContinue)) 'Transfer allows overflow that clears the field.'
Write-Output "Passed $checks numeric migration checks (offline)."
