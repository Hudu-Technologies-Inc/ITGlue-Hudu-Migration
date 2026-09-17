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
    } elseif ($normalized.Length -gt 3 -and $normalized.EndsWith('s') -and -not $normalized.EndsWith('ss')) {
        $normalized = $normalized.Substring(0, $normalized.Length - 1)
    }

    $stopTokens = @{
        'asset' = $true
        'blank' = $true
        'configuration' = $true
        'config' = $true
        'data' = $true
        'device' = $true
        'equipment' = $true
        'hardware' = $true
        'info' = $true
        'information' = $true
        'it' = $true
        'large' = $true
        'list' = $true
        'managed' = $true
        'misc' = $true
        'miscellaneous' = $true
        'network' = $true
        'note' = $true
        'notes' = $true
        'other' = $true
        'appliance' = $true
        'record' = $true
        'records' = $true
        'setup' = $true
        'software' = $true
        'special' = $true
        'system' = $true
        'test' = $true
        'testing' = $true
        'type' = $true
        'unmanaged' = $true
        'unknown' = $true
        'access' = $true
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

function Test-SmartConfigurationGenericLabel {
    param(
        [AllowNull()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) { return $true }

    $tokens = @(Get-SmartConfigurationTokens -TypeName $Value -TypeKind $null)
    return ($tokens.Count -eq 0)
}

function Test-SmartConfigurationBlankLabel {
    param(
        [AllowNull()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) { return $true }

    $normalized = (Normalize-Text $Value)
    if ([string]::IsNullOrWhiteSpace($normalized)) { return $true }
    $normalized = $normalized -replace '[^a-z0-9]', ''

    return ($normalized -in @('blank', 'none', 'null', 'na', 'n/a', 'notapplicable', 'notset', 'unset'))
}

function Get-SmartConfigurationKnownFamily {
    param(
        [AllowNull()]
        [string[]]$Tokens
    )

    $families = @(
        @{
            Name   = 'People / Users'
            Tokens = @(
                'user', 'users', 'person', 'people', 'employee', 'employees',
                'staff', 'contact', 'contacts', 'account', 'accounts',
                'login', 'logon', 'member', 'members', 'technician', 'operator', 'owner'
            )
        }

        @{
            Name   = 'Workstations'
            Tokens = @(
                'workstation', 'workstations', 'desktop', 'desktops',
                'laptop', 'laptops', 'notebook', 'notebooks',
                'computer', 'computers', 'endpoint', 'endpoints',
                'clientpc', 'windowsclient', 'macbook', 'imac',
                'surface', 'chromebook', 'thinclient', 'fatclient'
            )
        }

        @{
            Name   = 'Servers'
            Tokens = @(
                'server', 'servers', 'fileserver', 'appserver',
                'webserver', 'dbserver', 'sqlserver', 'mailserver',
                'terminalserver', 'rdserver', 'rdsserver', 'domainserver',
                'physicalserver', 'rackserver', 'towerserver', 'servercore',
                'windowsserver', 'linuxserver', 'baremetal'
            )
        }

        @{
            Name   = 'Switches'
            Tokens = @(
                'switch', 'switches', 'networkswitch', 'coreswitch',
                'accessswitch', 'distswitch', 'distributionswitch',
                'edgeswitch', 'stackswitch', 'switchstack',
                'procurve', 'catalyst', 'nexus', 'netgearprosafe',
                'managedswitch', 'poeswitch', 'l2switch', 'l3switch'
            )
        }

        @{
            Name   = 'Routers'
            Tokens = @(
                'router', 'routers', 'edgerouter', 'corerouter', 'networksecurityappliance',
                'wanrouter', 'branchrouter', 'gatewayrouter',
                'internetrouter', 'borderrouter', 'isr', 'asr',
                'mikrotik', 'routerboard', 'vyos', 'openwrt',
                'pfsenserouter', 'sdwanrouter', 'cpe'
            )
        }

        @{
            Name   = 'Internet / WAN'
            Tokens = @(
                'wan', 'internet', 'isp', 'circuit', 'circuits',
                'fiber', 'fibre', 'broadband', 'dia', 'mpls',
                'leasedline', 'carrier', 'modem', 'cablemodem',
                'dsl', 'lte', '5g', 'starlink', 'connection',
                'website', 'websites', 'web', 'ipaddress', 'ipaddresses'
            )
        }

        @{
            Name   = 'Firewalls'
            Tokens = @(
                'firewall', 'firewalls', 'utm', 'ngfw',
                'securitygateway', 'sonicwall', 'fortigate', 'fortinet',
                'watchguard', 'sophosxg', 'sophosfirewall',
                'paloalto', 'panos', 'checkpoint', 'firebox',
                'opnsense', 'pfsense', 'edgefirewall'
            )
        }

        @{
            Name   = 'Wireless'
            Tokens = @(
                'wireless', 'wifi', 'wlan', 'accesspoint',
                'accesspoints', 'wirelessap', 'wap',
                'wirelesscontroller', 'wlc', 'unifiap', 'unifiwifi',
                'ruckus', 'aerohive', 'mistap', 'instantap',
                'meshnode', 'wifibridge', 'wirelessbridge'
            )
        }

        @{
            Name   = 'Printers'
            Tokens = @(
                'printer', 'printers', 'print', 'printing',
                'copier', 'copiers', 'mfp', 'multifunction',
                'scanner', 'scanners', 'plotter', 'labelprinter',
                'laserprinter', 'inkjet', 'printserver',
                'xerox', 'ricoh', 'konica', 'kyocera', 'brotherprinter'
            )
        }

        @{
            Name   = 'Peripherals / Accessories'
            Tokens = @(
                'accessory', 'accessories', 'peripheral', 'peripherals',
                'dock', 'dockingstation', 'monitor', 'display',
                'keyboard', 'mouse', 'webcam', 'headset',
                'adapter', 'dongle', 'cable', 'scanner',
                'barcode', 'barcodescanner', 'cardreader'
            )
        }

        @{
            Name   = 'Phones'
            Tokens = @(
                'phone', 'phones', 'voip', 'pbx', 
                'handset', 'handsets', 'sipphone', 'ipphone',
                'deskphone', 'softphone', 'conferencephone',
                'polycom', 'yealink', 'grandstream', 'avaya',
                'mitel', 'freepbx', '3cx', 'teamsphone'
            )
        }

        @{
            Name   = 'Mobile Devices'
            Tokens = @(
                'mobile', 'mobiledevice', 'tablet', 'tablets',
                'ipad', 'ipads', 'iphone', 'iphones',
                'androidphone', 'androidtablet', 'cellphone',
                'smartphone', 'smartphones', 'pixelphone',
                'galaxyphone', 'iosdevice', 'byod', 'ruggedtablet'
            )
        }

        @{
            Name   = 'Storage'
            Tokens = @(
                'storage', 'nas', 'san', 'synology', 'qnap',
                'truenas', 'freenas', 'fileshare', 'diskarray',
                'storagearray', 'raidarray', 'iscsi', 'netapp',
                'datastore', 'storagepool', 'backupstorage',
                'jbod', 'das'
            )
        }

        @{
            Name   = 'Power'
            Tokens = @(
                'ups', 'batterybackup', 'battery', 'batteries',
                'pdu', 'powerstrip', 'powerunit', 'apcups',
                'smartups', 'tripplite', 'eatonups', 'cyberpower',
                'surgeprotector', 'powerconditioner', 'inverter',
                'generator', 'ats', 'rackpdu'
            )
        }

        @{
            Name   = 'Cameras / Surveillance'
            Tokens = @(
                'camera', 'cameras', 'ipcamera', 'securitycamera',
                'webcam', 'nvr', 'dvr', 'surveillance', 'cctv',
                'videorecorder', 'doorbellcamera', 'ptzcamera',
                'axiscamera', 'hikvision', 'dahua', 'avigilon',
                'verkada', 'blueiris'
            )
        }

        @{
            Name   = 'Virtualization'
            Tokens = @(
                'virtualization', 'virtual', 'vm', 'vms',
                'vmware', 'esxi', 'hypervisor', 'vcenter',
                'vsphere', 'hyperv', 'proxmox', 'xenserver',
                'xcpng', 'virtualmachine', 'virtualmachines',
                'cluster', 'computecluster', 'vhost'
            )
        }

        @{
            Name   = 'Backup'
            Tokens = @(
                'backup', 'backups', 'backupserver', 'backupappliance',
                'repository', 'backuprepo', 'veeam', 'datto',
                'acronis', 'backblaze', 'barracudabackup',
                'rubrik', 'cohesity', 'altaro', 'nakivo',
                'snapshot', 'snapshots', 'recoveryvault'
            )
        }

        @{
            Name   = 'Security'
            Tokens = @(
                'security', 'antivirus', 'edr', 'xdr', 'mdr',
                'endpointsecurity', 'defender', 'sentinelone',
                'crowdstrike', 'sophosendpoint', 'bitdefender',
                'malwarebytes', 'huntress', 'threatlocker',
                'dnsfilter', 'webfilter', 'siem', 'soc'
            )
        }

        @{
            Name   = 'Identity / Directory'
            Tokens = @(
                'identity', 'directory', 'activedirectory',
                'adserver', 'domaincontroller', 'dcserver','addc',
                'ldap', 'entra', 'azuread', 'okta', 'duo',
                'radius', 'nps', 'sso', 'mfa', 'idp', 'role',
                'authentication', 'authserver', 'directoryserver'
            )
        }

        @{
            Name   = 'Cloud / SaaS'
            Tokens = @(
                'cloud', 'saas', 'microsoft365', 'office365',
                'm365', 'azure', 'aws', 'gcp', 'tenant',
                'cloudtenant', 'sharepoint', 'onedrive',
                'exchangeonline', 'teamsservice', 'googleworkspace',
                'workspaceone', 'intune', 'cloudapp', 'hostedservice'
            )
        }

        @{
            Name   = 'Network Services'
            Tokens = @(
                'dns', 'dhcp', 'ntp', 'ipam', 'vpn',
                'proxy', 'proxyserver', 'loadbalancer', 'reverseproxy',
                'webproxy', 'dnsserver', 'dhcpserver', 'nameserver',
                'resolver', 'vpnserver', 'vpnconcentrator',
                'radiusproxy', 'natgateway', 'dhcprelay'
            )
        }

        @{
            Name   = 'Remote Access'
            Tokens = @(
                'remoteaccess', 'remote', 'rdp', 'rdgateway',
                'rdweb', 'remoteapp', 'screenconnect', 'connectwisecontrol',
                'logmein', 'splashtop', 'teamviewer', 'anydesk',
                'bomgar', 'beyondtrust', 'guacamole', 'vnc',
                'vpnclient', 'remotecontrol'
            )
        }

        @{
            Name   = 'IoT / Facilities'
            Tokens = @(
                'iot', 'sensor', 'sensors', 'thermostat',
                'doorcontroller', 'accesscontrol', 'badgereader',
                'intercom', 'kiosk', 'signage', 'digitaldisplay',
                'smarttv', 'conferenceroom', 'roompanel',
                'hvac', 'buildingcontrol', 'alarm', 'alarmpanel',
                'environmentalsensor'
            )
        }
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

function Get-SmartConfigurationPhraseFamily {
    param(
        [AllowNull()]
        [string]$TypeName,

        [AllowNull()]
        [string]$TypeKind
    )

    $label = (Normalize-Text (@($TypeName, $TypeKind) -join ' '))
    if ([string]::IsNullOrWhiteSpace($label)) { return $null }

    switch -Regex ($label) {
        '\bremote\s+access\b' { return 'Remote Access' }
        '\baccessor(?:y|ies)\b|\bperipheral(s)?\b' { return 'Peripherals / Accessories' }
        '\bnetwork\s+device\b' { return 'Network Devices' }
        '\bnetwork\s+security\s+appliance\b' { return 'Internet / WAN' }
        '\bsite\s+notes?\b' { return 'Site Notes' }
        '\bnew\s+system\s+setup\b' { return 'New System Setup' }
        '\bip\s+addresses?\b' { return 'Internet / WAN' }
        '\bweb\s*site\b|\bwebsite\b' { return 'Internet / WAN' }
        default { return $null }
    }
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

function Get-SmartConfigurationBestTokenScore {
    param(
        [AllowNull()]
        [string[]]$LeftTokens,

        [AllowNull()]
        [string[]]$RightTokens
    )

    $bestScore = 0.0
    foreach ($leftToken in @($LeftTokens)) {
        foreach ($rightToken in @($RightTokens)) {
            $score = Get-SmartConfigurationTokenSimilarity -A $leftToken -B $rightToken
            if ($score -gt $bestScore) {
                $bestScore = $score
            }
        }
    }

    return $bestScore
}

function Get-SmartConfigurationRecordScore {
    param(
        [Parameter(Mandatory)]
        $Left,

        [Parameter(Mandatory)]
        $Right
    )

    $leftTypeTokens = @($Left.TypeTokens)
    $rightTypeTokens = @($Right.TypeTokens)
    $leftKindTokens = @($Left.KindTokens)
    $rightKindTokens = @($Right.KindTokens)
    $leftTypeGeneric = ($leftTypeTokens.Count -eq 0)
    $rightTypeGeneric = ($rightTypeTokens.Count -eq 0)

    if ([bool]$Left.TypeNameIsBlank -ne [bool]$Right.TypeNameIsBlank) { return 0.0 }

    if ($Left.Family -and $Right.Family -and $Left.Family -eq $Right.Family) { return 1.0 }

    if (-not $leftTypeGeneric -and -not $rightTypeGeneric -and $Left.TypeFamily -and $Right.TypeFamily -and $Left.TypeFamily -eq $Right.TypeFamily) {
        return 1.0
    }

    if ($leftTypeGeneric -and $rightTypeGeneric) {
        if ($Left.KindFamily -and $Right.KindFamily -and $Left.KindFamily -eq $Right.KindFamily) { return 0.96 }
        if ($Left.PhraseFamily -and $Right.PhraseFamily -and $Left.PhraseFamily -eq $Right.PhraseFamily) { return 0.92 }
        if ($Left.NormalizedKind -and $Right.NormalizedKind -and $Left.NormalizedKind -eq $Right.NormalizedKind) { return 0.94 }
        if ($leftKindTokens.Count -eq 0 -and $rightKindTokens.Count -eq 0) {
            if (-not $Left.PhraseFamily -and -not $Right.PhraseFamily) { return 0.90 }
            return 0.0
        }
        return Get-SmartConfigurationBestTokenScore -LeftTokens $leftKindTokens -RightTokens $rightKindTokens
    }

    if ($leftTypeGeneric -and -not $rightTypeGeneric) {
        if ($Left.KindFamily -and $Right.TypeFamily -and $Left.KindFamily -eq $Right.TypeFamily) { return 0.93 }
        return Get-SmartConfigurationBestTokenScore -LeftTokens $leftKindTokens -RightTokens $rightTypeTokens
    }

    if (-not $leftTypeGeneric -and $rightTypeGeneric) {
        if ($Left.TypeFamily -and $Right.KindFamily -and $Left.TypeFamily -eq $Right.KindFamily) { return 0.93 }
        return Get-SmartConfigurationBestTokenScore -LeftTokens $leftTypeTokens -RightTokens $rightKindTokens
    }

    return Get-SmartConfigurationBestTokenScore -LeftTokens $leftTypeTokens -RightTokens $rightTypeTokens
}

function ConvertTo-SmartConfigurationMixedFamilyName {
    param(
        [AllowNull()]
        [string[]]$Families,

        [int]$MaxLength = 24
    )

    $familyList = @($Families | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique | Sort-Object)
    if ($familyList.Count -eq 0) { return $null }
    if ($familyList.Count -eq 1) { return $familyList[0] }

    $networkFamilies = @(
        'Firewalls',
        'Internet / WAN',
        'Network Devices',
        'Network Services',
        'Routers',
        'Switches',
        'Wireless'
    )
    $computerFamilies = @(
        'Servers',
        'Virtualization',
        'Workstations'
    )
    $identityFamilies = @(
        'Identity / Directory',
        'People / Users'
    )

    $allNetwork = @($familyList | Where-Object { $networkFamilies -notcontains $_ }).Count -eq 0
    if ($allNetwork) { return 'Network' }

    $allComputers = @($familyList | Where-Object { $computerFamilies -notcontains $_ }).Count -eq 0
    if ($allComputers) { return 'Computers' }

    $hasNetwork = @($familyList | Where-Object { $networkFamilies -contains $_ }).Count -gt 0
    $hasIdentity = @($familyList | Where-Object { $identityFamilies -contains $_ }).Count -gt 0
    $onlyNetworkIdentity = @($familyList | Where-Object { ($networkFamilies + $identityFamilies) -notcontains $_ }).Count -eq 0
    if ($hasNetwork -and $hasIdentity -and $onlyNetworkIdentity) {
        return 'Network / Identity'
    }

    $combined = @($familyList | Select-Object -First 3) -join ' / '
    if ($combined.Length -le $MaxLength) {
        return $combined
    }

    return 'Mixed Infrastructure'
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
    if ($families.Count -gt 1) {
        $mixedFamilyName = ConvertTo-SmartConfigurationMixedFamilyName -Families $families
        if (-not [string]::IsNullOrWhiteSpace($mixedFamilyName)) {
            return $mixedFamilyName
        }
    }

    $kindGroups = @($Records |
        Where-Object {
            -not [string]::IsNullOrWhiteSpace($_.TypeKind) -and
            -not (Test-SmartConfigurationGenericLabel -Value $_.TypeKind)
        } |
        Group-Object TypeKind |
        Sort-Object -Property @{ Expression = 'Count'; Descending = $true }, @{ Expression = 'Name'; Descending = $false })
    if ($kindGroups.Count -gt 0 -and $kindGroups[0].Count -eq @($Records).Count) {
        return [System.Globalization.CultureInfo]::CurrentCulture.TextInfo.ToTitleCase($kindGroups[0].Name.ToLowerInvariant())
    }

    $typeGroups = @($Records |
        Where-Object {
            -not [string]::IsNullOrWhiteSpace($_.TypeName) -and
            -not (Test-SmartConfigurationGenericLabel -Value $_.TypeName)
        } |
        Group-Object TypeName |
        Sort-Object -Property @{ Expression = 'Count'; Descending = $true }, @{ Expression = 'Name'; Descending = $false })
    if ($typeGroups.Count -gt 0) {
        return $typeGroups[0].Name
    }

    return 'Other Configurations'
}

function ConvertTo-SmartConfigurationOtherCategoryName {
    param(
        [Parameter(Mandatory)]
        [object[]]$OtherGroups,

        [string]$OtherCategoryName = 'Other Configurations',

        [int]$MaxParts = 4
    )

    $textInfo = [System.Globalization.CultureInfo]::CurrentCulture.TextInfo
    $seen = @{}
    $parts = [System.Collections.Generic.List[string]]::new()

    foreach ($group in @($OtherGroups | Sort-Object -Property @{ Expression = 'Count'; Descending = $true }, @{ Expression = 'CategoryName'; Descending = $false })) {
        $candidates = @()
        $sourceTypes = @($group.SourceTypes | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $sourceKinds = @($group.SourceKinds | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

        if ($sourceTypes.Count -gt 0 -and $sourceTypes.Count -le 2) {
            $candidates += $sourceTypes
        } elseif ($sourceKinds.Count -gt 0 -and $sourceKinds.Count -le 2) {
            $candidates += $sourceKinds
        } elseif (-not [string]::IsNullOrWhiteSpace([string]$group.CategoryName)) {
            $candidates += [string]$group.CategoryName
        } else {
            $candidates += @($group.Tokens | Select-Object -First 1)
        }

        foreach ($candidate in $candidates) {
            if ($parts.Count -ge $MaxParts) { break }
            if ([string]::IsNullOrWhiteSpace([string]$candidate)) { continue }

            $clean = ([string]$candidate).Trim() -replace '[\\/]+', ' ' -replace '\s+', ' '
            $clean = $clean -replace '(?i)\b(configuration|configurations|config|device|devices|asset|assets)\b', ''
            $clean = ($clean -replace '\s+', ' ').Trim()
            if ([string]::IsNullOrWhiteSpace($clean)) { continue }
            if ($clean -ieq $OtherCategoryName -or $clean -ieq 'Other') { continue }

            $display = $textInfo.ToTitleCase($clean.ToLowerInvariant())
            $key = $display.ToLowerInvariant()
            if ($seen.ContainsKey($key)) { continue }

            $seen[$key] = $true
            $parts.Add($display)
        }

        if ($parts.Count -ge $MaxParts) { break }
    }

    if ($parts.Count -eq 0) {
        return $OtherCategoryName
    }

    return "Other - $(@($parts) -join '/')"
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
                $typeNameIsBlank = Test-SmartConfigurationBlankLabel -Value $typeName
                $typeTokens = if ($typeNameIsBlank) { @() } else { @(Get-SmartConfigurationTokens -TypeName $typeName -TypeKind $null) }
                $kindTokens = @(Get-SmartConfigurationTokens -TypeName $null -TypeKind $typeKind)
                $tokens = @(@($typeTokens) + @($kindTokens) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
                $typeFamily = Get-SmartConfigurationKnownFamily -Tokens $typeTokens
                $kindFamily = Get-SmartConfigurationKnownFamily -Tokens $kindTokens
                $phraseFamily = Get-SmartConfigurationPhraseFamily -TypeName $typeName -TypeKind $null
                $family = if ($typeNameIsBlank) {
                    'Configurations'
                } elseif ($phraseFamily) {
                    $phraseFamily
                } elseif ($typeTokens.Count -gt 0 -and $typeFamily) {
                    $typeFamily
                } elseif ($kindFamily) {
                    $kindFamily
                } else {
                    $null
                }

                [pscustomobject]@{
                    Id             = $_.Name
                    TypeName       = $typeName
                    TypeKind       = $typeKind
                    TypeNameIsBlank = $typeNameIsBlank
                    NormalizedKind = @($kindTokens | Select-Object -First 1)[0]
                    TypeTokens     = $typeTokens
                    KindTokens     = $kindTokens
                    TypeFamily     = $typeFamily
                    KindFamily     = $kindFamily
                    PhraseFamily   = $phraseFamily
                    Tokens         = $tokens
                    Family         = $family
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
            | Sort-Object -Property @{ Expression = 'Count'; Descending = $true }, @{ Expression = 'CategoryName'; Descending = $false }
    )

    if ($groups.Count -gt $MaxCategories) {
        $keptGroups = @($groups | Select-Object -First ([math]::Max(0, $MaxCategories - 1)))
        $otherGroups = @($groups | Select-Object -Skip ([math]::Max(0, $MaxCategories - 1)))
        $otherRecords = @($otherGroups | ForEach-Object { $_.Records })
        $otherConfigurations = @($otherGroups | ForEach-Object { $_.Configurations })
        $otherDisplayName = ConvertTo-SmartConfigurationOtherCategoryName -OtherGroups $otherGroups -OtherCategoryName $OtherCategoryName

        $groups = @($keptGroups) + [pscustomobject]@{
            CategoryName   = $otherDisplayName
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
