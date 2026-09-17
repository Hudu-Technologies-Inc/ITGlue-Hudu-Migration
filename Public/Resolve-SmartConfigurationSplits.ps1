function ConvertTo-ConfigurationSplitBoolean {
    param(
        [AllowNull()]
        $Value
    )

    if ($null -eq $Value) { return $false }
    if ($Value -is [bool]) { return [bool]$Value }
    if ($Value -is [int]) { return ([int]$Value -ne 0) }

    $stringValue = "$Value".Trim()
    if ([string]::IsNullOrWhiteSpace($stringValue)) { return $false }

    switch -Regex ($stringValue) {
        '^(1|true|t|yes|y)$' { return $true }
        '^(0|false|f|no|n)$' { return $false }
        default { return $true }
    }
}

function Get-ConfigurationSplitSettingValue {
    param(
        [AllowNull()]
        $Source,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if ($null -eq $Source) { return $null }

    if ($Source -is [hashtable]) {
        if ($Source.ContainsKey($Name)) {
            return $Source[$Name]
        }
        return $null
    }

    $property = $Source.PSObject.Properties[$Name]
    if ($property) {
        return $property.Value
    }

    return $null
}

function Get-ConfigurationSplitMode {
    param(
        [AllowNull()]
        $Settings = $settings,

        [AllowNull()]
        $EnvironmentSettings = $environmentSettings
    )

    $configuredMode = $null
    foreach ($source in @($Settings, $EnvironmentSettings)) {
        if ($null -eq $source) { continue }
        $value = Get-ConfigurationSplitSettingValue -Source $source -Name 'ConfigurationSplitMode'
        if (-not [string]::IsNullOrWhiteSpace([string]$value)) {
            $configuredMode = [string]$value
            break
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($configuredMode)) {
        switch -Regex ($configuredMode.Trim()) {
            '^(none|one|single|combined|all)$' { return 'Single' }
            '^(exact|split|per[- ]?type)$' { return 'Exact' }
            '^(smart|smart[- ]?split|fuzzy)$' { return 'Smart' }
        }
    }

    foreach ($source in @($Settings, $EnvironmentSettings)) {
        if ($null -eq $source) { continue }
        $value = Get-ConfigurationSplitSettingValue -Source $source -Name 'SmartSplitConfigurations'
        if ((ConvertTo-ConfigurationSplitBoolean -Value $value)) {
            return 'Smart'
        }
    }

    foreach ($source in @($Settings, $EnvironmentSettings)) {
        if ($null -eq $source) { continue }
        $splitValue = Get-ConfigurationSplitSettingValue -Source $source -Name 'SplitConfigurations'
        if ($null -ne $splitValue) {
            if ($splitValue -is [string] -and $splitValue.Trim() -match '^(smart|smart[- ]?split|fuzzy)$') {
                return 'Smart'
            }
            if (ConvertTo-ConfigurationSplitBoolean -Value $splitValue) {
                return 'Exact'
            }
        }
    }

    return 'Single'
}

function Get-SmartConfigurationCategoryMax {
    param(
        [AllowNull()]
        $Settings = $settings,

        [AllowNull()]
        $EnvironmentSettings = $environmentSettings,

        [int]$Default = 20
    )

    foreach ($source in @($Settings, $EnvironmentSettings)) {
        if ($null -eq $source) { continue }
        foreach ($name in @('SmartSplitConfigurationMaxCategories', 'SmartConfigurationMaxCategories', 'ConfigurationSplitMaxCategories')) {
            $value = Get-ConfigurationSplitSettingValue -Source $source -Name $name
            if ($null -eq $value) { continue }
            try {
                $candidate = [int]$value
                if ($candidate -ge 1) {
                    return $candidate
                }
            } catch {}
        }
    }

    return $Default
}

function Normalize-SmartConfigurationToken {
    param(
        [AllowNull()]
        [string]$Token
    )

    if ([string]::IsNullOrWhiteSpace($Token)) { return $null }

    $normalized = (Normalize-Text $Token)
    if ([string]::IsNullOrWhiteSpace($normalized)) { return $null }

    $normalized = $normalized -replace '[^a-z0-9]', ''
    if ([string]::IsNullOrWhiteSpace($normalized)) { return $null }

    if ($normalized.Length -gt 3 -and $normalized.EndsWith('ies')) {
        $normalized = "$($normalized.Substring(0, $normalized.Length - 3))y"
    } elseif ($normalized.Length -gt 3 -and $normalized.EndsWith('ses')) {
        $normalized = $normalized.Substring(0, $normalized.Length - 2)
    } elseif ($normalized.Length -gt 3 -and $normalized.EndsWith('s')) {
        $normalized = $normalized.Substring(0, $normalized.Length - 1)
    }

    $stopTokens = @{
        'asset' = $true
        'configuration' = $true
        'config' = $true
        'device' = $true
        'equipment' = $true
        'hardware' = $true
        'it' = $true
        'misc' = $true
        'miscellaneous' = $true
        'other' = $true
        'type' = $true
        'unknown' = $true
    }

    if ($stopTokens.ContainsKey($normalized)) { return $null }
    if ($normalized.Length -lt 2) { return $null }

    return $normalized
}

function Get-SmartConfigurationTokens {
    param(
        [AllowNull()]
        [string]$TypeName,

        [AllowNull()]
        [string]$TypeKind
    )

    $tokens = [System.Collections.Generic.List[string]]::new()
    foreach ($value in @($TypeName, $TypeKind)) {
        if ([string]::IsNullOrWhiteSpace($value)) { continue }
        foreach ($token in ([regex]::Split([string]$value, '[\s_\-/\\]+') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
            $normalized = Normalize-SmartConfigurationToken -Token $token
            if ($normalized -and -not $tokens.Contains($normalized)) {
                $tokens.Add($normalized)
            }
        }
    }

    return @($tokens)
}

function Get-SmartConfigurationKnownFamily {
    param(
        [AllowNull()]
        [string[]]$Tokens
    )

    $families = @(
        @{ Name = 'Workstations'; Tokens = @('workstation', 'desktop', 'laptop', 'notebook', 'computer', 'pc', 'endpoint', 'thinclient') }
        @{ Name = 'Servers'; Tokens = @('server', 'esxi', 'hypervisor', 'host', 'vmware', 'vcenter', 'virtual', 'vm') }
        @{ Name = 'Network'; Tokens = @('network', 'switch', 'router', 'firewall', 'ap', 'wap', 'wireless', 'wifi', 'controller', 'gateway', 'sonicwall', 'fortigate', 'meraki', 'ubiquiti') }
        @{ Name = 'Printers'; Tokens = @('printer', 'print', 'copier', 'mfp', 'scanner') }
        @{ Name = 'Phones'; Tokens = @('phone', 'voip', 'pbx', 'handset', 'sip') }
        @{ Name = 'Mobile Devices'; Tokens = @('mobile', 'tablet', 'ipad', 'iphone', 'android', 'cell') }
        @{ Name = 'Storage'; Tokens = @('storage', 'nas', 'san', 'synology', 'qnap') }
        @{ Name = 'Power'; Tokens = @('ups', 'battery', 'pdu', 'power') }
        @{ Name = 'Cameras'; Tokens = @('camera', 'nvr', 'dvr', 'surveillance') }
    )

    foreach ($family in $families) {
        foreach ($token in @($Tokens)) {
            if ($family.Tokens -contains $token) {
                return $family.Name
            }
        }
    }

    return $null
}

function Get-SmartConfigurationLevenshteinSimilarity {
    param(
        [AllowNull()]
        [string]$A,

        [AllowNull()]
        [string]$B
    )

    if ([string]::IsNullOrWhiteSpace($A) -and [string]::IsNullOrWhiteSpace($B)) { return 1.0 }
    if ([string]::IsNullOrWhiteSpace($A) -or [string]::IsNullOrWhiteSpace($B)) { return 0.0 }

    $left = [string]$A
    $right = [string]$B
    if ($left -eq $right) { return 1.0 }

    $leftLength = $left.Length
    $rightLength = $right.Length
    $distance = New-Object 'int[,]' ($leftLength + 1), ($rightLength + 1)

    for ($i = 0; $i -le $leftLength; $i++) { $distance[$i, 0] = $i }
    for ($j = 0; $j -le $rightLength; $j++) { $distance[0, $j] = $j }

    for ($i = 1; $i -le $leftLength; $i++) {
        for ($j = 1; $j -le $rightLength; $j++) {
            $leftIndex = $i - 1
            $rightIndex = $j - 1
            $cost = if ($left[$leftIndex] -eq $right[$rightIndex]) { 0 } else { 1 }
            $delete = $distance[$leftIndex, $j] + 1
            $insert = $distance[$i, $rightIndex] + 1
            $substitute = $distance[$leftIndex, $rightIndex] + $cost
            $distance[$i, $j] = [Math]::Min($delete, [Math]::Min($insert, $substitute))
        }
    }

    $maxLength = [Math]::Max($leftLength, $rightLength)
    if ($maxLength -eq 0) { return 1.0 }

    return 1.0 - ([double]$distance[$leftLength, $rightLength] / [double]$maxLength)
}

function Get-SmartConfigurationTokenSimilarity {
    param(
        [AllowNull()]
        [string]$A,

        [AllowNull()]
        [string]$B
    )

    if ([string]::IsNullOrWhiteSpace($A) -or [string]::IsNullOrWhiteSpace($B)) { return 0.0 }
    if ($A -eq $B) { return 1.0 }
    if ($A.Length -ge 5 -and $B.Length -ge 5 -and ($A.StartsWith($B) -or $B.StartsWith($A))) { return 0.92 }

    return [double](Get-SmartConfigurationLevenshteinSimilarity -A $A -B $B)
}

function Get-SmartConfigurationRecordScore {
    param(
        [Parameter(Mandatory)]
        $Left,

        [Parameter(Mandatory)]
        $Right
    )

    if ($Left.Family -and $Right.Family -and $Left.Family -eq $Right.Family) { return 1.0 }
    if ($Left.NormalizedKind -and $Right.NormalizedKind -and $Left.NormalizedKind -eq $Right.NormalizedKind) { return 0.96 }

    $bestScore = 0.0
    foreach ($leftToken in @($Left.Tokens)) {
        foreach ($rightToken in @($Right.Tokens)) {
            $score = Get-SmartConfigurationTokenSimilarity -A $leftToken -B $rightToken
            if ($score -gt $bestScore) {
                $bestScore = $score
            }
        }
    }

    return $bestScore
}

function ConvertTo-SmartConfigurationCategoryName {
    param(
        [Parameter(Mandatory)]
        [object[]]$Records
    )

    $families = @($Records.Family | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    if ($families.Count -eq 1) {
        return $families[0]
    }

    $kindGroups = @($Records |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_.TypeKind) } |
        Group-Object TypeKind |
        Sort-Object -Property @{ Expression = 'Count'; Descending = $true }, @{ Expression = 'Name'; Descending = $false })
    if ($kindGroups.Count -gt 0 -and $kindGroups[0].Count -eq @($Records).Count) {
        return [System.Globalization.CultureInfo]::CurrentCulture.TextInfo.ToTitleCase($kindGroups[0].Name.ToLowerInvariant())
    }

    $typeGroups = @($Records |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_.TypeName) } |
        Group-Object TypeName |
        Sort-Object -Property @{ Expression = 'Count'; Descending = $true }, @{ Expression = 'Name'; Descending = $false })
    if ($typeGroups.Count -gt 0) {
        return $typeGroups[0].Name
    }

    return 'Other Configurations'
}

function Resolve-SmartConfigurationSplits {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Configurations,

        [int]$MaxCategories = 20,

        [double]$TokenSimilarityThreshold = 0.84,

        [string]$OtherCategoryName = 'Other Configurations'
    )

    if ($MaxCategories -lt 1) { $MaxCategories = 1 }

    $records = @(
        $Configurations |
            Where-Object { $null -ne $_ } |
            Group-Object {
                $typeName = [string]$_.attributes.'configuration-type-name'
                $typeKind = [string]$_.attributes.'configuration-type-kind'
                "$typeName`u{1f}$typeKind"
            } |
            ForEach-Object {
                $sample = $_.Group | Select-Object -First 1
                $typeName = [string]$sample.attributes.'configuration-type-name'
                $typeKind = [string]$sample.attributes.'configuration-type-kind'
                $tokens = @(Get-SmartConfigurationTokens -TypeName $typeName -TypeKind $typeKind)
                $normalizedKindTokens = @(Get-SmartConfigurationTokens -TypeName $null -TypeKind $typeKind)

                [pscustomobject]@{
                    Id             = $_.Name
                    TypeName       = $typeName
                    TypeKind       = $typeKind
                    NormalizedKind = @($normalizedKindTokens | Select-Object -First 1)[0]
                    Tokens         = $tokens
                    Family         = Get-SmartConfigurationKnownFamily -Tokens $tokens
                    Count          = @($_.Group).Count
                    Configurations = @($_.Group)
                }
            }
    )

    if ($records.Count -eq 0) { return @() }

    $parent = @{}
    foreach ($record in $records) {
        $parent[$record.Id] = $record.Id
    }

    function Find-SmartConfigurationParent {
        param(
            [Parameter(Mandatory)]
            [hashtable]$Parent,

            [Parameter(Mandatory)]
            [string]$Id
        )

        while ($Parent[$Id] -ne $Id) {
            $Parent[$Id] = $Parent[$Parent[$Id]]
            $Id = $Parent[$Id]
        }

        return $Id
    }

    function Join-SmartConfigurationParents {
        param(
            [Parameter(Mandatory)]
            [hashtable]$Parent,

            [Parameter(Mandatory)]
            [string]$Left,

            [Parameter(Mandatory)]
            [string]$Right
        )

        $leftParent = Find-SmartConfigurationParent -Parent $Parent -Id $Left
        $rightParent = Find-SmartConfigurationParent -Parent $Parent -Id $Right
        if ($leftParent -ne $rightParent) {
            $Parent[$rightParent] = $leftParent
        }
    }

    for ($i = 0; $i -lt $records.Count; $i++) {
        for ($j = $i + 1; $j -lt $records.Count; $j++) {
            $score = Get-SmartConfigurationRecordScore -Left $records[$i] -Right $records[$j]
            if ($score -ge $TokenSimilarityThreshold) {
                Join-SmartConfigurationParents -Parent $parent -Left $records[$i].Id -Right $records[$j].Id
            }
        }
    }

    $groups = @(
        $records |
            Group-Object { Find-SmartConfigurationParent -Parent $parent -Id $_.Id } |
            ForEach-Object {
                $groupRecords = @($_.Group)
                $categoryName = ConvertTo-SmartConfigurationCategoryName -Records $groupRecords
                [pscustomobject]@{
                    CategoryName = $categoryName
                    Count        = [int]($groupRecords | Measure-Object Count -Sum).Sum
                    SourceTypes  = @($groupRecords.TypeName | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
                    SourceKinds  = @($groupRecords.TypeKind | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
                    Tokens       = @($groupRecords.Tokens | Sort-Object -Unique)
                    Records      = $groupRecords
                    Configurations = @($groupRecords | ForEach-Object { $_.Configurations })
                }
            }
            Sort-Object -Property @{ Expression = 'Count'; Descending = $true }, @{ Expression = 'CategoryName'; Descending = $false }
    )

    if ($groups.Count -gt $MaxCategories) {
        $keptGroups = @($groups | Select-Object -First ([math]::Max(0, $MaxCategories - 1)))
        $otherGroups = @($groups | Select-Object -Skip ([math]::Max(0, $MaxCategories - 1)))
        $otherRecords = @($otherGroups | ForEach-Object { $_.Records })
        $otherConfigurations = @($otherGroups | ForEach-Object { $_.Configurations })

        $groups = @($keptGroups) + [pscustomobject]@{
            CategoryName   = $OtherCategoryName
            Count          = @($otherConfigurations).Count
            SourceTypes    = @($otherRecords.TypeName | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
            SourceKinds    = @($otherRecords.TypeKind | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
            Tokens         = @($otherRecords.Tokens | Sort-Object -Unique)
            Records        = $otherRecords
            Configurations = $otherConfigurations
        }
    }

    $usedNames = @{}
    foreach ($group in $groups) {
        $baseName = if ([string]::IsNullOrWhiteSpace($group.CategoryName)) { $OtherCategoryName } else { $group.CategoryName.Trim() }
        $name = $baseName
        $suffix = 2
        while ($usedNames.ContainsKey($name.ToLowerInvariant())) {
            $name = "$baseName $suffix"
            $suffix++
        }
        $usedNames[$name.ToLowerInvariant()] = $true
        $group.CategoryName = $name
    }

    return @($groups)
}
