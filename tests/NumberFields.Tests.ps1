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
$metadata = [pscustomobject]@{min=0;required=$false;max='1.00000000000000000001';currency_code=$null}
$snapshot = Copy-HuduNumberProperties $metadata
Assert-Number ($snapshot -is [System.Collections.IDictionary] -and $snapshot.min -ceq 0 -and $snapshot.required -eq $false -and $snapshot.max -ceq $metadata.max) 'Field snapshot changed zero, false or exact bounds.'
Assert-Number ($snapshot.ContainsKey('currency_code') -and $null -eq $snapshot.currency_code) 'Field snapshot lost an explicit null.'
$dictionaryCopy = Copy-HuduNumberProperties $snapshot
$dictionaryCopy.min = 1
Assert-Number ($snapshot.min -eq 0 -and $metadata.min -eq 0) 'Field snapshot still aliases the source dictionary.'
Assert-Number ($null -eq (Get-HuduNumberProperty $metadata 'absent') -and $null -eq (Get-HuduNumberProperty $snapshot 'absent')) 'Missing optional metadata no longer returns null.'
Assert-Number ($null -eq (Copy-HuduNumberProperties $null)) 'Missing definition was replaced with an empty definition.'
$plain = @{ field_type = 'Number'; number_type = 'number' }
$percent = @{ field_type = 'Number'; number_type = 'percentage' }
$usd = @{ field_type = 'Number'; number_type = 'currency'; currency_code = 'USD' }
$longFraction = '0.1234567890123456789012345678901234567890123456789'
foreach ($text in @('0','0.01','-0.01','12.34','2147483648','9007199254740993','9223372036854775807','-9223372036854775807', $longFraction)) {
    $actual = ConvertTo-HuduNumber $text $plain
    Assert-Number ($actual.IsValid -and $actual.Value -ceq $text -and $actual.Value -is [string]) "Plain number lost precision: $text"
}
foreach ($text in @('9223372036854775808','-9223372036854775808','9223372036854775807.01','-9223372036854775807.01','1e1000000000','1e-1000000000','$12.34','12.5%','π','NaN','Infinity','1+2i','1,234','12,34,567','null')) {
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
Assert-Number ((ConvertTo-HuduNumber '12.345' $usd).Value -ceq '12.35') 'USD extra precision was not rounded.'
Assert-Number ((ConvertTo-HuduNumber '-1' $usd).IsValid) 'USD negative rejected.'
foreach ($code in @('USD', 'EUR', 'AUD')) {
    $regionalCurrency = @{number_type='currency'; currency_code=$code}
    Assert-Number ((ConvertTo-HuduNumber '12.34' $regionalCurrency).IsValid) "$code cents rejected without a user precision option."
    $roundedCurrency = ConvertTo-HuduNumber '12.345' $regionalCurrency
    Assert-Number ($roundedCurrency.IsValid -and $roundedCurrency.Value -ceq '12.35' -and $roundedCurrency.Warning.Contains('12.345')) "$code rounding lost the amount or the audit warning."
}
Assert-Number ((ConvertTo-HuduNumber '-2147483649' $percent).IsValid) 'Negative percentage rejected.'
Assert-Number ((ConvertTo-HuduNumber '100' $percent).IsValid) '100 percent rejected.'
Assert-Number (-not (ConvertTo-HuduNumber '100.01' $percent).IsValid) 'Percentage above 100 accepted.'
Assert-Number ((ConvertTo-HuduNumber '12.5' $percent).Value -ceq '12.5') 'Percentage was rescaled.'
Assert-Number (-not (ConvertTo-HuduNumber '1' @{number_type='currency';currency_code='JPY'}).IsValid) 'Untested currency precision was assumed.'
Assert-Number ((ConvertTo-HuduNumber '1' @{number_type='currency';currency_code='JPY'} -CurrencyDecimalPlaces 0).IsValid) 'Explicit currency precision ignored.'
Assert-Number ((ConvertTo-HuduNumber '1.5' @{number_type='currency';currency_code='JPY'} -CurrencyDecimalPlaces 0).Value -ceq '2') 'Destination zero-decimal policy ignored.'
Assert-Number (-not (ConvertTo-HuduNumber '0.01' $plain -CurrentVersion '2.47.0').IsValid) 'Legacy decimal was rounded.'
Assert-Number ((ConvertTo-HuduNumber '2147483647' $plain -CurrentVersion '2.47.0').IsValid) 'Legacy integer rejected.'
Assert-Number (-not (ConvertTo-HuduNumber '2147483648' $plain -CurrentVersion '2.47.0').IsValid) 'Legacy overflow was coerced.'
Assert-Number ((ConvertTo-HuduNumber '0' @{min=0;max=0}).IsValid) 'Zero bounds treated as absent.'
Assert-Number (-not (ConvertTo-HuduNumber '-0.01' @{min=0}).IsValid) 'Minimum ignored.'
Assert-Number (-not (ConvertTo-HuduNumber '1.00000000000000000001' @{max='1.00000000000000000000'}).IsValid) 'High precision bound comparison lost precision.'
Assert-Number ((ConvertTo-HuduNumber '-2' @{min=-3;max=-1}).IsValid) 'Negative bound comparison inverted.'
Assert-Number (-not (ConvertTo-HuduNumber '4.0' $null).IsValid) 'Missing numeric definition bypassed validation.'
foreach ($invalidDefinition in @('', @(), 42, $false)) {
    Assert-Number (-not (ConvertTo-HuduNumber '4.0' $invalidDefinition).IsValid) 'Malformed numeric definition bypassed validation.'
}
$unreadable = [pscustomobject]@{}
$unreadable | Add-Member -MemberType ScriptProperty -Name number_type -Value { throw 'Metadata read failed' }
$unreadableResult = ConvertTo-HuduNumber '4.0' $unreadable
Assert-Number (-not $unreadableResult.IsValid -and $null -eq $unreadableResult.Value) 'Unreadable numeric metadata bypassed validation.'
$previousCulture = [cultureinfo]::CurrentCulture
try {
    [cultureinfo]::CurrentCulture = [cultureinfo]'fr-FR'
    Assert-Number ((ConvertTo-HuduNumber ([decimal]12.34) $plain).Value -ceq '12.34') 'Numeric formatting depends on locale.'
    $float = ConvertTo-HuduNumber ([double]12.34) $plain
    Assert-Number ($float.Value -ceq '12.34' -and [bool]$float.Warning) 'Source float precision warning is missing.'
} finally { [cultureinfo]::CurrentCulture = $previousCulture }
Assert-Number ((Get-CastIfNumeric '0.01') -ceq '0.01') 'Compatibility helper still rounds.'
Assert-Number ((Get-CastIfNumeric '000123ABC') -ceq '000123ABC') 'Compatibility helper changes identifiers.'

foreach ($example in @(
    @{Input='.5';Expected='0.5';Definition=$plain},
    @{Input='12.';Expected='12';Definition=$plain},
    @{Input='1e3';Expected='1000';Definition=$plain},
    @{Input='1.234e-2';Expected='0.01234';Definition=$plain},
    @{Input='9.223372036854775807e18';Expected='9223372036854775807';Definition=$plain},
    @{Input='1e-325';Expected=('0.' + ('0' * 324) + '1');Definition=$plain},
    @{Input='1,234.56';Expected='1234.56';Definition=$plain},
    @{Input='1.234,56';Expected='1234.56';Definition=$plain},
    @{Input='12,34';Expected='12.34';Definition=$plain},
    @{Input='1,234,567';Expected='1234567';Definition=$plain},
    @{Input='1.234.567';Expected='1234567';Definition=$plain},
    @{Input='1 234.56';Expected='1234.56';Definition=$plain},
    @{Input="1$([char]0x202f)234,56";Expected='1234.56';Definition=$plain},
    @{Input="1'234.56";Expected='1234.56';Definition=$plain},
    @{Input='(12.34)';Expected='-12.34';Definition=$plain},
    @{Input='12.5%';Expected='12.5';Definition=$percent},
    @{Input='12,5 %';Expected='12.5';Definition=$percent},
    @{Input='$1,234.56';Expected='1234.56';Definition=$usd},
    @{Input='USD 12.345';Expected='12.35';Definition=$usd},
    @{Input='12.345 USD';Expected='12.35';Definition=$usd},
    @{Input='-$12.345';Expected='-12.35';Definition=$usd},
    @{Input='$-12.345';Expected='-12.35';Definition=$usd},
    @{Input='($1,234.565)';Expected='-1234.57';Definition=$usd},
    @{Input='€1.234,565';Expected='1234.57';Definition=@{number_type='currency';currency_code='EUR'}},
    @{Input='$1,234.565';Expected='1234.57';Definition=@{number_type='currency';currency_code='AUD'}},
    @{Input='1.005';Expected='1.01';Definition=$usd},
    @{Input='-1.005';Expected='-1.01';Definition=$usd},
    @{Input='9.995';Expected='10';Definition=$usd},
    @{Input='-0.004';Expected='0';Definition=$usd},
    @{Input='1e-325';Expected='0';Definition=$usd},
    @{Input='12.344999999999999999999999999999999999';Expected='12.34';Definition=$usd},
    @{Input='12.345000000000000000000000000000000001';Expected='12.35';Definition=$usd}
)) {
    $actual = ConvertTo-HuduNumber $example.Input $example.Definition
    Assert-Number ($actual.IsValid -and $actual.Value -is [string] -and $actual.Value -ceq $example.Expected) "Numeric format conversion failed: $($example.Input) -> $($example.Expected) ($($actual.Reason))"
}
foreach ($invalidCurrency in @('€12.34','EUR 12.34','USD -$12.34','(-$12.34)','$1,234','$1,23,45','12 dollars','$12.34%')) {
    Assert-Number (-not (ConvertTo-HuduNumber $invalidCurrency $usd).IsValid) "Ambiguous, mismatched or malformed currency accepted: $invalidCurrency"
}
Assert-Number (-not (ConvertTo-HuduNumber '$12.34' $plain).IsValid) 'Currency markers were stripped from a plain number field.'
Assert-Number (-not (ConvertTo-HuduNumber '100.01%' $percent).IsValid) 'Formatting bypassed percentage bounds.'
Assert-Number (-not (ConvertTo-HuduNumber '12.345' @{number_type='currency';currency_code='USD';max='12.34'}).IsValid) 'Rounding bypassed a destination maximum.'
Assert-Number (-not (ConvertTo-HuduNumber '0.004' @{number_type='currency';currency_code='USD';min='0.001'}).IsValid) 'Rounding bypassed a destination minimum.'
Assert-Number (-not (ConvertTo-HuduNumber '9223372036854775807.995' $usd).IsValid) 'Rounding overflow bypassed the destination range.'
Assert-Number (-not (ConvertTo-HuduNumber '12.3400' $usd).Warning) 'Exact conversion incorrectly warned about rounding.'
Assert-Number ((ConvertTo-HuduNumber '4.0e0' $plain -CurrentVersion '2.47.0').Value -ceq '4') 'Exactly integral numeric text was rejected for a legacy integer field.'
Assert-Number (-not (ConvertTo-HuduNumber '4.1' $plain -CurrentVersion '2.47.0').IsValid) 'Fractional source was silently truncated for a legacy integer field.'

$source = [pscustomobject]@{id='42'; attributes=[pscustomobject]@{kind='Percent';decimals=6}}
$mapping = Get-HuduNumberFieldMapping $source
Assert-Number ($mapping.LayoutAttributes.number_type -eq 'percentage' -and $mapping.SourceDecimals -eq 6) 'Explicit Percent metadata was not mapped.'
Assert-Number ($mapping.SourceFieldId -eq '42' -and $mapping.SourceKind -eq 'Percent') 'Source numeric mapping provenance was lost.'
$oldMapping = Get-HuduNumberFieldMapping $source -CurrentVersion '2.47.0'
Assert-Number (-not $oldMapping.LayoutAttributes.ContainsKey('number_type')) 'Subtype attributes leaked to older Hudu.'
$source.attributes.kind = 'Number'
$source.attributes | Add-Member -NotePropertyName name -NotePropertyValue 'Price in USD'
$currencyMapping = Get-HuduNumberFieldMapping $source
Assert-Number ($currencyMapping.LayoutAttributes.currency_code -eq 'USD' -and $currencyMapping.CurrencyDecimalPlaces -eq 2) 'Explicit USD label was not inferred.'
foreach ($label in @('Monthly cost','Annual Spend','Outstanding debt','Unit price','Budget','Expenses','Service fee','Total ($)','cost_per_month')) {
    $source.attributes.name = $label
    foreach ($region in @(
        @{Endpoint='https://api.itglue.com';Code='USD'},
        @{Endpoint=' https://API.EU.itglue.com/ ';Code='EUR'},
        @{Endpoint='https://api.au.itglue.com';Code='AUD'}
    )) {
        $inferred = Get-HuduNumberFieldMapping $source -ITGAPIEndpoint $region.Endpoint
        Assert-Number ($inferred.LayoutAttributes.number_type -eq 'currency' -and $inferred.LayoutAttributes.currency_code -eq $region.Code -and $inferred.CurrencyDecimalPlaces -eq 2 -and $inferred.MappingSource -eq 'LabelHeuristic') "Monetary label not inferred for $($region.Code): $label"
    }
}
foreach ($label in @('Costume count','Number of users','Cost center','Debt ratio','Cost (%)','Spending ID','Total USD / EUR')) {
    $source.attributes.name = $label
    Assert-Number ((Get-HuduNumberFieldMapping $source).LayoutAttributes.number_type -eq 'number') "Nonnumeric/ambiguous currency label inferred: $label"
}
$source.attributes.name = 'Cost ($)'
Assert-Number ((Get-HuduNumberFieldMapping $source -ITGAPIEndpoint 'https://api.au.itglue.com').LayoutAttributes.currency_code -eq 'AUD') 'Ambiguous dollar symbol did not use the datacenter default.'
$source.attributes.name = 'Cost EUR'
$euro = Get-HuduNumberFieldMapping $source -ITGAPIEndpoint 'https://api.au.itglue.com'
Assert-Number ($euro.LayoutAttributes.currency_code -eq 'EUR' -and $euro.CurrencyDecimalPlaces -eq 2) 'Explicit label currency did not take precedence over default currency.'
$source.attributes.name = 'Cost JPY'
$unknownPrecision = Get-HuduNumberFieldMapping $source
Assert-Number ($unknownPrecision.LayoutAttributes.number_type -eq 'number' -and $null -eq $unknownPrecision.CurrencyDecimalPlaces) 'Unknown currency precision was guessed.'
$source.attributes.name = 'Annual cost'
# Stale options in existing sessions cannot override the automatic mapping.
$ITGlueNumberFieldOverrides = @{'42'=@{NumberType='number'}}
$ITGlueCurrencyInference = @{Enabled=$false;DefaultCurrencyCode='JPY'}
Assert-Number ((Get-HuduNumberFieldMapping $source).LayoutAttributes.number_type -eq 'currency') 'Retired user options still alter numeric mapping.'
$source.attributes.kind = 'Percent'
Assert-Number ((Get-HuduNumberFieldMapping $source).LayoutAttributes.number_type -eq 'percentage') 'Currency heuristic overrode Percent metadata.'
$source.attributes.kind = 'Number'
$oldInferred = Get-HuduNumberFieldMapping $source -CurrentVersion '2.47.0'
Assert-Number (-not $oldInferred.LayoutAttributes.ContainsKey('number_type') -and $oldInferred.SourceNumberType -eq 'number') 'Label heuristic was applied on older Hudu.'
$source.attributes.kind = 'Currency'
$nativeCurrency = Get-HuduNumberFieldMapping $source -ITGAPIEndpoint 'https://api.eu.itglue.com'
Assert-Number ($nativeCurrency.LayoutAttributes.currency_code -eq 'EUR' -and $nativeCurrency.CurrencyDecimalPlaces -eq 2 -and $nativeCurrency.MappingSource -eq 'ITGlueKind') 'Native currency metadata required a user override.'
$source.attributes | Add-Member -NotePropertyName 'currency-code' -NotePropertyValue 'AUD'
Assert-Number ((Get-HuduNumberFieldMapping $source).LayoutAttributes.currency_code -eq 'AUD') 'Explicit currency metadata was replaced with the datacenter default.'
$source.attributes.kind = 'Number'
$source.attributes.name = 'Amount'
Assert-Number ((Get-HuduNumberFieldMapping $source).MappingSource -eq 'ITGlueCurrencyMetadata') 'Currency metadata on a Number field was ignored.'
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
Assert-Number (-not $wire.ContainsKey('rate') -and $wire.cost -ceq '12.35') 'Invalid percentage was sent or rounded currency was omitted.'
Assert-Number ($wire.identifier -ceq '000123') 'Numeric-looking text identifier changed.'
Assert-Number ($prepared[0].ManualActions.Count -eq 1 -and $prepared[0].ManualActions[0].Data -ceq '100.01') 'Invalid original percentage missing from manual actions.'
$ManualActions = [System.Collections.ArrayList]@()
$serial = Start-FlexibleAssetContentsExample $asset -WarningAction SilentlyContinue
Assert-Number ($serial.amount -ceq $wire.amount -and $serial.identifier -ceq '000123') 'Serial/parallel output differs.'
Assert-Number (-not $serial.ContainsKey('rate') -and $serial.cost -ceq $wire.cost -and $ManualActions.Count -eq 1) 'Serial and parallel rounding or rejection differs.'

# Missing numeric metadata omits only that value and preserves the rest of the asset.
$missingField = [pscustomobject]@{IGLayoutID=1;ITGParsedName='amount';HuduParsedName='amount';FieldName='Amount';FieldType='Number';HuduLayoutField=$null}
$missingResult = @(Invoke-FastFlexibleAssetFieldPreparation -Assets @($asset) -AllFields @($missingField, $AllFields[3]) -CurrentVersion $CurrentVersion -ThrottleLimit 1)[0]
$missingWire = @{}
foreach ($entry in $missingResult.AssetUpdateRequest.Fields) { foreach ($key in $entry.Keys) { $missingWire[$key] = $entry[$key] } }
Assert-Number ($missingResult.Status -eq 'prepared' -and $missingWire.identifier -ceq '000123' -and -not $missingWire.ContainsKey('amount')) 'Missing numeric metadata failed the asset or sent an unchecked value.'
Assert-Number ($missingResult.ManualActions.Count -eq 1 -and $missingResult.ManualActions[0].Data -ceq $longFraction) 'Missing numeric metadata lost the source value for manual review.'

# Unexpected preparation failures retain enough context to diagnose the source.
$badAsset = $asset.PSObject.Copy()
$badAsset.HuduID = 'invalid-id'
$badResult = @(Invoke-FastFlexibleAssetFieldPreparation -Assets @($badAsset) -AllFields $AllFields -CurrentVersion $CurrentVersion -ThrottleLimit 1)[0]
Assert-Number ($badResult.Status -eq 'failed' -and $null -eq $badResult.AssetUpdateRequest -and $null -eq $badResult.ErrorField -and $badResult.ErrorId -and $badResult.ErrorPosition -and $badResult.ErrorScriptStackTrace) 'Preparation failure lost diagnostic context or produced an update request.'

# Confirm policy against representative rows from the actual saved API run.
$observations = @(Import-Csv "$PSScriptRoot/fixtures/number-fields-2.48.0.csv")
Assert-Number ($observations.Count -eq 12) 'Expected anonymized 2.48.0 regression observations.'
foreach ($sample in @(
    @{Subtype='Number';Case='decimal-50-string';Accepted=$true},
    @{Subtype='Percentage';Case='percent-over-string';Accepted=$false},
    @{Subtype='Number';Case='int64-over-string';Accepted=$false}
)) {
    $row = $observations | Where-Object { $_.Operation -eq 'Create' -and $_.Subtype -eq $sample.Subtype -and $_.CaseId -eq $sample.Case }
    $definition = switch ($sample.Subtype) { Number {$plain} Currency {$usd} Percentage {$percent} }
    $inputText = ConvertFrom-Json -InputObject $row.SubmittedJson
    $actual = ConvertTo-HuduNumber $inputText $definition
    Assert-Number ($actual.IsValid -eq $sample.Accepted -and (($row.HttpStatus -eq '200') -eq $sample.Accepted)) "Policy disagrees with live sample $($sample.Case)."
}
# The saved API observation rejects 12.345; the migration now sends rounded 12.35.
$currencyObservation = $observations | Where-Object { $_.Operation -eq 'Create' -and $_.Subtype -eq 'Currency' -and $_.CaseId -eq 'decimal-three-string' }
$roundedObservation = ConvertTo-HuduNumber (ConvertFrom-Json $currencyObservation.SubmittedJson) $usd
Assert-Number ($currencyObservation.HttpStatus -eq '422' -and $roundedObservation.IsValid -and $roundedObservation.Value -ceq '12.35' -and $roundedObservation.Warning) 'Raw rejected currency sample was not converted to a supported two-decimal value.'
# Exercise the companion transfer helper without starting its UI or calling Hudu.
$tokens = $null; $parseErrors = $null
$transferAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '../Start-HuduAssetLayoutTransfer.ps1'), [ref]$tokens, [ref]$parseErrors)
$transferFunction = $transferAst.FindAll({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-CastIfNumeric'}, $true) | Select-Object -First 1
Invoke-Expression $transferFunction.Extent.Text
Assert-Number ((Get-CastIfNumeric '0.01' -FieldDefinition $plain -CurrentVersion '2.48.0') -ceq '0.01') 'Transfer still rounds decimals.'
Assert-Number ((Get-CastIfNumeric '$12.34' -FieldDefinition $usd -CurrentVersion '2.48.0') -ceq '12.34') 'Transfer did not convert a matching currency symbol.'
Assert-Number ($null -eq (Get-CastIfNumeric '9223372036854775808' -FieldDefinition $plain -CurrentVersion '2.48.0' -WarningAction SilentlyContinue)) 'Transfer allows overflow that clears the field.'
Write-Output "Passed $checks numeric migration checks (offline)."
