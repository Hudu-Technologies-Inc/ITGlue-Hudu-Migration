# Numeric policy based on numresults.csv (Hudu 2.48.0). Never parse decimal text
# through double/decimal: ITGlue can supply more precision than either preserves.
function Get-HuduNumberProperty {
    param([AllowNull()]$Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) { return $Object[$Name] }
    $properties = $Object.PSObject.Properties
    if ($null -eq $properties) { throw "Cannot read numeric metadata property '$Name'." }
    $property = $properties[$Name]
    # Calling the getter explicitly lets read errors reach the validator;
    # PowerShell's ordinary property access can turn a failed getter into null.
    if ($null -ne $property) { return $property.get_Value() }
    return $null
}

function Copy-HuduNumberProperties {
    param([AllowNull()]$Object)
    if ($null -eq $Object) { return $null }
    $copy = @{}
    if ($Object -is [System.Collections.IDictionary]) {
        foreach ($key in $Object.Keys) { $copy[$key] = $Object[$key] }
    } else {
        $properties = $Object.PSObject.Properties
        if ($null -eq $properties) { throw 'Cannot snapshot numeric field metadata.' }
        foreach ($property in $properties) { $copy[$property.Name] = $property.get_Value() }
    }
    return $copy
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
    $match = [regex]::Match($text, '^(?<sign>[+-]?)(?:(?<whole>[0-9]+)(?:\.(?<fraction>[0-9]*))?|\.(?<fraction>[0-9]+))(?:[eE](?<exponent>[+-]?[0-9]+))?$')
    if (-not $match.Success) { return $null }
    $whole = $match.Groups['whole'].Value
    $fraction = $match.Groups['fraction'].Value
    $digits = $whole + $fraction
    if (-not $digits.Trim('0')) { return '0' }
    $exponent = 0
    if ($match.Groups['exponent'].Success -and -not [int]::TryParse($match.Groups['exponent'].Value, [ref]$exponent)) { return $null }
    $point = [long]$whole.Length + $exponent
    # Bound exponent expansion so malformed input cannot allocate enormous strings.
    $expandedLength = if ($point -le 0) { 2 - $point + $digits.Length } else { [math]::Max($point, $digits.Length) + 1 }
    if ($expandedLength -gt 10000) { return $null }
    if ($point -le 0) {
        $whole = '0'; $fraction = ('0' * [int](-$point)) + $digits
    } elseif ($point -ge $digits.Length) {
        $whole = $digits + ('0' * [int]($point - $digits.Length)); $fraction = ''
    } else {
        $whole = $digits.Substring(0, [int]$point); $fraction = $digits.Substring([int]$point)
    }
    $whole = $whole.TrimStart('0')
    if (-not $whole) { $whole = '0' }
    $fraction = $fraction.TrimEnd('0')
    $negative = $match.Groups['sign'].Value -eq '-' -and ($whole -ne '0' -or $fraction)
    $sign = if ($negative) { '-' } else { '' }
    $suffix = if ($fraction) { ".$fraction" } else { '' }
    return "$sign$whole$suffix"
}

function ConvertTo-HuduFormattedNumberText {
    param([AllowNull()]$Value, [string]$NumberType, [string]$CurrencyCode)
    if ($Value -isnot [string]) { return ConvertTo-HuduDecimalText $Value }
    $text = $Value.Trim()
    $accountingNegative = $text.StartsWith('(') -and $text.EndsWith(')')
    if ($accountingNegative) { $text = $text.Substring(1, $text.Length - 2).Trim() }
    $sign = ''
    if ($text -match '^[+-]') { $sign = $text.Substring(0, 1); $text = $text.Substring(1).TrimStart() }
    if ($NumberType -eq 'currency') {
        $markers = @()
        if ($text -match '^(?<marker>[a-zA-Z]{3}|[$€£¥₹₩₽])\s*') {
            $markers += $Matches.marker; $text = $text.Substring($Matches[0].Length)
        }
        if ($text -match '\s*(?<marker>[a-zA-Z]{3}|[$€£¥₹₩₽])$') {
            $markers += $Matches.marker; $text = $text.Substring(0, $text.Length - $Matches[0].Length)
        }
        $symbolCurrencies = @{
            '$' = @('USD', 'AUD', 'CAD', 'NZD', 'HKD', 'SGD', 'MXN')
            '€' = @('EUR'); '£' = @('GBP'); '¥' = @('JPY', 'CNY')
            '₹' = @('INR'); '₩' = @('KRW'); '₽' = @('RUB')
        }
        foreach ($marker in $markers) {
            if ($marker -ine $CurrencyCode -and $CurrencyCode -notin $symbolCurrencies[$marker]) { return $null }
        }
        # Both -$12 and $-12 occur in exports; two signs remain invalid.
        if ($text -match '^[+-]') {
            if ($sign) { return $null }
            $sign = $text.Substring(0, 1); $text = $text.Substring(1).TrimStart()
        }
    } elseif ($NumberType -eq 'percentage' -and $text.EndsWith('%')) {
        $text = $text.Substring(0, $text.Length - 1).TrimEnd()
    }
    if ($accountingNegative) {
        if ($sign) { return $null }
        $sign = '-'
    }
    $exponent = ''
    if ($text -match '^(?<mantissa>.*?)(?<exponent>[eE][+-]?[0-9]+)$') {
        $exponent = $Matches.exponent; $text = $Matches.mantissa
    }
    if ($text -match '^[0-9]{1,3}(?<separator>[ \u00a0\u202f''\u2019])[0-9]{3}(?:\k<separator>[0-9]{3})*(?:[.,][0-9]+)?$') {
        $text = ($text -replace '[ \u00a0\u202f''\u2019]', '') -replace ',', '.'
    } elseif ($text.Contains(',') -and $text.Contains('.')) {
        if ($text -match '^[0-9]{1,3}(?:,[0-9]{3})+\.[0-9]+$') { $text = $text.Replace(',', '') }
        elseif ($text -match '^[0-9]{1,3}(?:\.[0-9]{3})+,[0-9]+$') { $text = $text.Replace('.', '').Replace(',', '.') }
        else { return $null }
    } elseif ($text.Contains(',')) {
        if ($text -match '^[0-9]{1,3}(?:,[0-9]{3}){2,}$') { $text = $text.Replace(',', '') }
        elseif ($text -match '^[0-9]*,(?<fraction>[0-9]+)$' -and $Matches.fraction.Length -ne 3) { $text = $text.Replace(',', '.') }
        else { return $null } # 1,234 can mean either 1234 or 1.234.
    } elseif ($text -match '^[0-9]{1,3}(?:\.[0-9]{3}){2,}$') {
        $text = $text.Replace('.', '')
    }
    return ConvertTo-HuduDecimalText "$sign$text$exponent"
}

function Round-HuduNumberText {
    param([string]$Text, [ValidateRange(0, 99)][int]$DecimalPlaces)
    $negative = $Text.StartsWith('-')
    $parts = $Text.TrimStart('-').Split('.')
    if ($parts.Length -eq 1 -or $parts[1].Length -le $DecimalPlaces) { return $Text }
    $digits = $parts[0] + $parts[1].Substring(0, $DecimalPlaces)
    if ($parts[1][$DecimalPlaces] -ge [char]'5') {
        $digits = ([System.Numerics.BigInteger]::Parse($digits, [cultureinfo]::InvariantCulture) + [System.Numerics.BigInteger]::One).ToString([cultureinfo]::InvariantCulture)
    }
    if ($DecimalPlaces -gt 0) {
        $digits = $digits.PadLeft($DecimalPlaces + 1, '0')
        $digits = $digits.Insert($digits.Length - $DecimalPlaces, '.')
    }
    if ($negative) { $digits = "-$digits" }
    return ConvertTo-HuduDecimalText $digits
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

function Get-ITGlueDefaultCurrencyCode {
    param([string]$ITGAPIEndpoint = 'https://api.itglue.com')
    switch ($ITGAPIEndpoint.Trim().TrimEnd('/')) {
        'https://api.eu.itglue.com' { 'EUR' }
        'https://api.au.itglue.com' { 'AUD' }
        default { 'USD' }
    }
}

function Get-HuduCurrencyDecimalPlaces {
    param([string]$CurrencyCode)
    # The three ITGlue datacenter defaults use two fractional places. Other
    # currencies retain plain numeric storage unless their precision is known.
    if ($CurrencyCode -in @('USD', 'EUR', 'AUD')) { return 2 }
    return $null
}

function Get-HuduNumberFieldMapping {
    param([Parameter(Mandatory)]$SourceField, [version]$CurrentVersion = '2.48.0', [string]$ITGAPIEndpoint = 'https://api.itglue.com')
    $attributes = Get-HuduNumberProperty $SourceField 'attributes'
    $kind = [string](Get-HuduNumberProperty $attributes 'kind')
    if ($kind -notin @('Number', 'Percent', 'Currency')) { throw "Cannot map nonnumeric ITGlue kind '$kind' as a number." }
    $sourceId = [string](Get-HuduNumberProperty $SourceField 'id')
    $numberType = if ($kind -eq 'Percent') { 'percentage' } elseif ($kind -eq 'Currency') { 'currency' } else { 'number' }
    $mappingSource = 'ITGlueKind'; $mappingReason = "ITGlue kind '$kind'."; $candidate = $false
    $hint = $null; $inferredCode = $null
    $metadataCode = Get-HuduNumberProperty $attributes 'currency-code'
    if (-not $metadataCode) { $metadataCode = Get-HuduNumberProperty $attributes 'currency_code' }
    if ($kind -eq 'Number' -and $CurrentVersion -ge [version]'2.48.0') {
        $hint = Get-HuduCurrencyLabelHint ([string](Get-HuduNumberProperty $attributes 'name'))
        $candidate = $hint.IsCandidate
        if ($candidate) { $mappingReason = $hint.Reason }
        if ($metadataCode) {
            $inferredCode = $metadataCode
            $numberType = 'currency'; $mappingSource = 'ITGlueCurrencyMetadata'
            $mappingReason = 'Explicit ITGlue currency metadata.'
        } elseif ($hint.CanInfer) {
            $inferredCode = if ($hint.Codes.Count -eq 1) { $hint.Codes[0] } else { Get-ITGlueDefaultCurrencyCode $ITGAPIEndpoint }
            $numberType = 'currency'; $mappingSource = 'LabelHeuristic'
        }
    }
    $currencyCode = $null; $places = $null
    if ($numberType -eq 'currency') {
        if (-not $inferredCode) { $inferredCode = $metadataCode }
        if (-not $inferredCode) {
            $hint = Get-HuduCurrencyLabelHint ([string](Get-HuduNumberProperty $attributes 'name'))
            $inferredCode = if ($hint.CanInfer -and $hint.Codes.Count -eq 1) { $hint.Codes[0] } else { Get-ITGlueDefaultCurrencyCode $ITGAPIEndpoint }
        }
        $currencyCode = ([string]$inferredCode).Trim().ToUpperInvariant()
        $places = Get-HuduCurrencyDecimalPlaces $currencyCode
        if ($null -eq $places) {
            $numberType = 'number'; $mappingSource = 'ITGlueKind'
            $mappingReason += " Currency '$currencyCode' precision is unknown; kept as plain number to preserve values."
            $currencyCode = $null
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
    if ($Value -is [double] -or $Value -is [single]) {
        $result.Warning = 'Source was already a floating-point value; any precision lost while reading ITGlue cannot be recovered.'
    }
    # Missing/unreadable settings must not silently bypass currency, percentage or bounds checks.
    if ($null -eq $FieldDefinition) {
        $result.Reason = 'Destination numeric field definition is missing.'; return $result
    }
    if ($FieldDefinition -isnot [System.Collections.IDictionary] -and $FieldDefinition -isnot [pscustomobject]) {
        $result.Reason = 'Destination numeric field definition must be a property map.'; return $result
    }
    try {
        $numberType = [string](Get-HuduNumberProperty $FieldDefinition 'number_type')
        $code = ([string](Get-HuduNumberProperty $FieldDefinition 'currency_code')).ToUpperInvariant()
        $bounds = @{
            min = Get-HuduNumberProperty $FieldDefinition 'min'
            max = Get-HuduNumberProperty $FieldDefinition 'max'
        }
    } catch {
        $result.Reason = "Cannot read destination numeric field settings: $($_.Exception.Message)"; return $result
    }
    if (-not $numberType) { $numberType = 'number' }
    if ($numberType -notin @('number', 'currency', 'percentage')) {
        $result.Reason = "Unknown destination number_type '$numberType'."; return $result
    }
    $text = ConvertTo-HuduFormattedNumberText -Value $Value -NumberType $numberType -CurrencyCode $code
    if ($null -eq $text) {
        $result.Reason = 'Cannot unambiguously convert this value for the destination numeric field. Check separators, currency/percentage markers, and finite numeric syntax.'
        return $result
    }
    if ($numberType -eq 'currency' -and $CurrentVersion -ge [version]'2.48.0') {
        if ($null -eq $CurrencyDecimalPlaces) { $CurrencyDecimalPlaces = Get-HuduCurrencyDecimalPlaces $code }
        if (-not $code -or $null -eq $CurrencyDecimalPlaces -or [string]$CurrencyDecimalPlaces -notmatch '^(0|[1-9][0-9]?)$') {
            $result.Reason = "Currency '$code' needs a known decimal-place policy; automatic precision is available for USD, EUR and AUD (2)."; return $result
        }
        $rounded = Round-HuduNumberText $text -DecimalPlaces ([int]$CurrencyDecimalPlaces)
        if ($rounded -cne $text) {
            $roundingWarning = "Rounded $code amount from $text to $rounded ($CurrencyDecimalPlaces decimal places; midpoints away from zero)."
            $result.Warning = (@($result.Warning, $roundingWarning) | Where-Object { $_ }) -join ' '
            $text = $rounded
        }
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
    }
    foreach ($boundName in @('min', 'max')) {
        $bound = $bounds[$boundName]
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
