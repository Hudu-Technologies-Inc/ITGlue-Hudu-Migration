# Numeric policy based on numresults.csv (Hudu 2.48.0). Never parse decimal text
# through double/decimal: ITGlue can supply more precision than either preserves.
function Get-HuduNumberProperty {
    param([AllowNull()]$Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) { return $Object[$Name] }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    return $null
}

function ConvertTo-HuduDecimalText {
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [string]) { $text = $Value.Trim() }
    elseif ($Value.GetType().Name -in @('Byte','SByte','Int16','UInt16','Int32','UInt32','Int64','UInt64','BigInteger','Decimal')) {
        $text = $Value.ToString([cultureinfo]::InvariantCulture)
    } elseif ($Value -is [double] -or $Value -is [single]) {
        $text = $Value.ToString('R', [cultureinfo]::InvariantCulture)
    } else { return $null }
    if ($text -cnotmatch '^(?<sign>[+-]?)(?<whole>[0-9]+)(?:\.(?<fraction>[0-9]+))?$') { return $null }
    $whole = $Matches['whole'].TrimStart('0')
    if (-not $whole) { $whole = '0' }
    $fraction = ([string]$Matches['fraction']).TrimEnd('0')
    $negative = $Matches['sign'] -eq '-' -and ($whole -ne '0' -or $fraction)
    $sign = if ($negative) { '-' } else { '' }
    $suffix = if ($fraction) { ".$fraction" } else { '' }
    return "$sign$whole$suffix"
}

function Compare-HuduNumberText {
    param([string]$Left, [string]$Right)
    $leftNegative = $Left.StartsWith('-'); $rightNegative = $Right.StartsWith('-')
    if ($leftNegative -ne $rightNegative) { if ($leftNegative) { return -1 } else { return 1 } }
    $leftParts = $Left.TrimStart('-').Split('.'); $rightParts = $Right.TrimStart('-').Split('.')
    $comparison = $leftParts[0].Length.CompareTo($rightParts[0].Length)
    if ($comparison -eq 0) { $comparison = [string]::CompareOrdinal($leftParts[0], $rightParts[0]) }
    if ($comparison -eq 0) {
        $leftFraction = if ($leftParts.Length -gt 1) { $leftParts[1] } else { '' }
        $rightFraction = if ($rightParts.Length -gt 1) { $rightParts[1] } else { '' }
        $width = [math]::Max($leftFraction.Length, $rightFraction.Length)
        $comparison = [string]::CompareOrdinal($leftFraction.PadRight($width, '0'), $rightFraction.PadRight($width, '0'))
    }
    if ($leftNegative) { return -$comparison }
    return $comparison
}

function Get-HuduCurrencyLabelHint {
    param([string]$Label)
    $labelText = $Label.Replace('_', ' ')
    $codes = @([regex]::Matches($labelText, '(?i)(?<![a-z0-9])(USD|EUR|GBP|CAD|AUD|NZD|JPY|CNY|CHF|INR|SEK|NOK|DKK|ZAR)(?![a-z0-9])') | ForEach-Object { $_.Value.ToUpperInvariant() })
    if ($labelText.Contains('€')) { $codes += 'EUR' }
    if ($labelText.Contains('£')) { $codes += 'GBP' }
    $codes = @($codes | Select-Object -Unique)
    $keyword = [regex]::Match($labelText, '(?i)\b(costs?|spend|spending|debts?|prices?|budgets?|revenues?|expenses?|fees?|payments?)\b')
    $symbol = [regex]::Match($labelText, '[$€£¥₹₩₽]')
    $candidate = $keyword.Success -or $symbol.Success -or $codes.Count -gt 0
    $excluded = $labelText -match '(?i)%|\b(percent(?:age)?|ratio|count|identifier|id|code)\b|\bcost\s+cent(?:er|re)\b'
    $reason = if ($excluded) { 'Label includes a percentage, ratio, count, identifier, or cost-center term.' }
        elseif ($codes.Count -gt 1) { 'Label contains conflicting currency codes/symbols.' }
        elseif ($candidate) { "Label match: keyword '$($keyword.Value)', symbol '$($symbol.Value)', codes '$($codes -join ',')'." }
        else { 'No monetary label match.' }
    [pscustomobject]@{ IsCandidate = $candidate; CanInfer = $candidate -and -not $excluded -and $codes.Count -le 1; Codes = $codes; Reason = $reason }
}

function Get-HuduNumberFieldMapping {
    param([Parameter(Mandatory)]$SourceField, [version]$CurrentVersion = '2.48.0', [System.Collections.IDictionary]$Overrides = @{}, [System.Collections.IDictionary]$CurrencyInference = @{ Enabled = $true })
    $attributes = Get-HuduNumberProperty $SourceField 'attributes'
    $kind = [string](Get-HuduNumberProperty $attributes 'kind')
    if ($kind -notin @('Number', 'Percent', 'Currency')) { throw "Cannot map nonnumeric ITGlue kind '$kind' as a number." }
    $sourceId = [string](Get-HuduNumberProperty $SourceField 'id')
    $override = Get-HuduNumberProperty $Overrides $sourceId
    $numberType = if ($kind -eq 'Percent') { 'percentage' } elseif ($kind -eq 'Currency') { 'currency' } else { 'number' }
    $mappingSource = 'ITGlueKind'; $mappingReason = "ITGlue kind '$kind'."; $candidate = $false
    $configuredType = Get-HuduNumberProperty $override 'NumberType'
    $hint = $null; $inferredCode = $null
    if ($configuredType) {
        $numberType = ([string]$configuredType).ToLowerInvariant()
        $mappingSource = 'Override'; $mappingReason = "Explicit override for ITGlue field $sourceId."
    } elseif ($kind -eq 'Number' -and $CurrentVersion -ge [version]'2.48.0' -and (Get-HuduNumberProperty $CurrencyInference 'Enabled') -eq $true) {
        $hint = Get-HuduCurrencyLabelHint ([string](Get-HuduNumberProperty $attributes 'name'))
        $candidate = $hint.IsCandidate
        if ($candidate) { $mappingReason = $hint.Reason }
        if ($hint.CanInfer) {
            $inferredCode = Get-HuduNumberProperty $override 'CurrencyCode'
            if (-not $inferredCode -and $hint.Codes.Count -eq 1) { $inferredCode = $hint.Codes[0] }
            if (-not $inferredCode) { $inferredCode = Get-HuduNumberProperty $CurrencyInference 'DefaultCurrencyCode' }
            if ($inferredCode) { $numberType = 'currency'; $mappingSource = 'LabelHeuristic' }
            else { $mappingReason += ' Currency code unresolved; kept as plain number. Configure DefaultCurrencyCode or a field override.' }
        }
    }
    if ($numberType -notin @('number', 'currency', 'percentage')) { throw "Unknown NumberType '$numberType' for ITGlue field $sourceId." }
    $currencyCode = $null; $places = $null
    if ($numberType -eq 'currency') {
        $currencyCode = ([string](Get-HuduNumberProperty $override 'CurrencyCode')).ToUpperInvariant()
        if (-not $currencyCode -and $mappingSource -eq 'LabelHeuristic') { $currencyCode = ([string]$inferredCode).ToUpperInvariant() }
        if ($currencyCode -cnotmatch '^[A-Z]{3}$') { throw "ITGlue field $sourceId needs an explicit three-letter CurrencyCode override." }
        $places = Get-HuduNumberProperty $override 'DecimalPlaces'
        if ($null -eq $places) { $places = Get-HuduNumberProperty (Get-HuduNumberProperty $CurrencyInference 'DecimalPlacesByCurrency') $currencyCode }
        if ($null -eq $places -and $currencyCode -eq 'USD') { $places = 2 }
        if ($null -eq $places -or [string]$places -notmatch '^(0|[1-9][0-9]?)$') {
            if ($mappingSource -eq 'LabelHeuristic' -and $null -eq $places) {
                $numberType = 'number'; $mappingSource = 'ITGlueKind'
                $mappingReason += " Currency $currencyCode precision unresolved; kept as plain number. Configure DecimalPlacesByCurrency or a field override."
                $currencyCode = $null
            } else { throw "ITGlue field $sourceId needs explicit DecimalPlaces for currency $currencyCode; only USD precision has been tested." }
        }
        if ($numberType -eq 'currency') { $mappingReason += " Currency $currencyCode, $places fractional places." }
    }
    $layoutAttributes = @{ field_type = 'Number' }
    if ($CurrentVersion -ge [version]'2.48.0') {
        $layoutAttributes.number_type = $numberType
        if ($numberType -eq 'currency') { $layoutAttributes.currency_code = $currencyCode }
    }
    [pscustomobject]@{
        LayoutAttributes = $layoutAttributes
        SourceFieldId = $sourceId
        SourceKind = $kind
        MappingSource = $mappingSource
        MappingReason = $mappingReason
        CurrencyCandidate = $candidate
        SourceNumberType = $numberType
        SourceDecimals = Get-HuduNumberProperty $attributes 'decimals'
        CurrencyDecimalPlaces = $places
    }
}

function ConvertTo-HuduNumber {
    param(
        [AllowNull()]$Value,
        [AllowNull()]$FieldDefinition,
        [version]$CurrentVersion = '2.48.0',
        [AllowNull()]$CurrencyDecimalPlaces
    )
    $result = [pscustomobject]@{ IsValid = $false; IsEmpty = $false; Value = $null; Reason = $null; Warning = $null }
    if ($null -eq $Value -or ($Value -is [string] -and [string]::IsNullOrWhiteSpace($Value))) {
        $result.IsValid = $true; $result.IsEmpty = $true; return $result
    }
    $text = ConvertTo-HuduDecimalText $Value
    if ($null -eq $text) {
        $result.Reason = 'Expected a finite plain decimal value. Symbols, grouping, exponents, booleans, arrays, and objects are not converted.'
        return $result
    }
    if ($Value -is [double] -or $Value -is [single]) {
        $result.Warning = 'Source was already a floating-point value; any precision lost while reading ITGlue cannot be recovered.'
    }
    $numberType = [string](Get-HuduNumberProperty $FieldDefinition 'number_type')
    if (-not $numberType) { $numberType = 'number' }
    if ($numberType -notin @('number', 'currency', 'percentage')) {
        $result.Reason = "Unknown destination number_type '$numberType'."; return $result
    }
    if ($CurrentVersion -lt [version]'2.48.0') {
        # Keep the historical integer envelope, without rounding or overflowing.
        if ($text.Contains('.') -or (Compare-HuduNumberText $text '-2147483648') -lt 0 -or (Compare-HuduNumberText $text '2147483647') -gt 0) {
            $result.Reason = 'Before Hudu 2.48.0 this migration only sends integers in its historical Int32 range; value requires review.'; return $result
        }
    } else {
        if ((Compare-HuduNumberText $text '-9223372036854775807') -lt 0 -or (Compare-HuduNumberText $text '9223372036854775807') -gt 0) {
            $result.Reason = 'Outside the range reported by Hudu 2.48.0: -9223372036854775807 through 9223372036854775807.'; return $result
        }
        if ($numberType -eq 'percentage' -and (Compare-HuduNumberText $text '100') -gt 0) {
            $result.Reason = 'Percentage exceeds Hudu 2.48.0 maximum 100. Values are not rescaled.'; return $result
        }
        if ($numberType -eq 'currency') {
            $code = ([string](Get-HuduNumberProperty $FieldDefinition 'currency_code')).ToUpperInvariant()
            if ($null -eq $CurrencyDecimalPlaces -and $code -eq 'USD') { $CurrencyDecimalPlaces = 2 }
            if (-not $code -or $null -eq $CurrencyDecimalPlaces -or [string]$CurrencyDecimalPlaces -notmatch '^(0|[1-9][0-9]?)$') {
                $result.Reason = "Currency '$code' needs a known decimal-place policy; only USD (2) has been tested."; return $result
            }
            $parts = $text.Split('.')
            if ($parts.Length -gt 1 -and $parts[1].Length -gt [int]$CurrencyDecimalPlaces) {
                $result.Reason = "Currency $code exceeds $CurrencyDecimalPlaces decimal places. Value was not rounded."; return $result
            }
        }
    }
    foreach ($boundName in @('min', 'max')) {
        $bound = Get-HuduNumberProperty $FieldDefinition $boundName
        if ($null -eq $bound -or [string]::IsNullOrWhiteSpace([string]$bound)) { continue }
        $boundText = ConvertTo-HuduDecimalText $bound
        if ($null -eq $boundText) { $result.Reason = "Cannot validate destination $boundName setting."; return $result }
        $comparison = Compare-HuduNumberText $text $boundText
        if (($boundName -eq 'min' -and $comparison -lt 0) -or ($boundName -eq 'max' -and $comparison -gt 0)) {
            $result.Reason = "Outside destination $boundName setting $boundText."; return $result
        }
    }
    $result.IsValid = $true; $result.Value = $text
    return $result
}

function Confirm-HuduNumberLayoutMapping {
    param([object[]]$Fields, $SavedLayout, [version]$CurrentVersion)
    foreach ($field in $Fields) {
        if ($field.FieldType -notin @('Number', 'Percent', 'Currency')) { continue }
        $savedFields = Get-HuduNumberProperty $SavedLayout 'fields'
        $matches = @($savedFields | Where-Object { $_.label -ieq $field.FieldName })
        if ($matches.Count -ne 1 -or $matches[0].field_type -ne 'Number') {
            throw "Cannot identify saved numeric field '$($field.FieldName)'. Numeric asset migration has not started."
        }
        if ($CurrentVersion -ge [version]'2.48.0') {
            foreach ($attribute in @('number_type', 'currency_code')) {
                $expected = Get-HuduNumberProperty $field.HuduLayoutField $attribute
                if ($null -ne $expected -and $expected -ine (Get-HuduNumberProperty $matches[0] $attribute)) {
                    throw "Hudu did not persist $attribute '$expected' for '$($field.FieldName)'. Numeric asset migration has not started."
                }
            }
        }
        # Validate values against the saved destination bounds and subtype.
        $field.HuduLayoutField = $matches[0]
    }
}

function New-HuduNumberManualAction {
    param($Asset, $Field, [AllowNull()]$Value, [string]$Reason)
    $hudu = Get-HuduNumberProperty $Asset 'HuduObject'
    $itg = Get-HuduNumberProperty (Get-HuduNumberProperty $Asset 'ITGObject') 'attributes'
    [pscustomobject]@{
        Document_Name = Get-HuduNumberProperty $Asset 'Name'
        Type = 'Asset Field - Number'
        Company_Name = Get-HuduNumberProperty $hudu 'company_name'
        HuduID = Get-HuduNumberProperty $Asset 'HuduID'
        Field_Name = Get-HuduNumberProperty $Field 'FieldName'
        Notes = $Reason
        Action = 'Review the original numeric value and destination settings. This field was omitted from the update.'
        Data = $Value
        Hudu_URL = Get-HuduNumberProperty $hudu 'url'
        ITG_URL = Get-HuduNumberProperty $itg 'resource-url'
    }
}
