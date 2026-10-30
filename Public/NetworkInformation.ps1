function Get-OmniIPAMNormalizedLabel {
  param([AllowNull()][string]$Label)

  if ([string]::IsNullOrWhiteSpace($Label)) { return $null }
  return ($Label.Trim() -replace '[^\w\s]', '' -replace '\s+', '_').ToLowerInvariant()
}

function Get-OmniIPAMFieldLabel {
  param([AllowNull()]$Field)

  foreach ($candidate in @($Field.label, $Field.caption, $Field.name, $Field.field_name, $Field.fieldName)) {
    if (-not [string]::IsNullOrWhiteSpace("$candidate")) {
      return "$candidate"
    }
  }

  return $null
}

function Get-OmniIPAMLayoutId {
  param([AllowNull()]$Layout)

  foreach ($candidate in @($Layout.id, $Layout.asset_layout_id, $Layout.assetLayoutId, $Layout.layout_id, $Layout.layoutId)) {
    if ($null -ne $candidate -and "$candidate" -match '^\d+$') {
      return [int]$candidate
    }
  }

  return $null
}

function Get-OmniIPAMLayoutName {
  param([AllowNull()]$Layout)

  foreach ($candidate in @($Layout.name, $Layout.Name, $Layout.title, $Layout.Title)) {
    if (-not [string]::IsNullOrWhiteSpace("$candidate")) {
      return "$candidate"
    }
  }

  return $null
}

function Get-OmniIPAMAssetObject {
  param([AllowNull()]$Asset)

  foreach ($candidate in @($Asset.HuduObject, $Asset.asset, $Asset.Asset)) {
    if ($null -ne $candidate) {
      return $candidate
    }
  }

  return $Asset
}

function Get-OmniIPAMMigrationAsset {
  param(
    [AllowNull()][AllowEmptyCollection()][object[]]$MigrationItems,
    [AllowNull()][AllowEmptyCollection()][int[]]$AllowedCompanyId
  )
  $seen = [Collections.Generic.HashSet[string]]::new()
  foreach ($item in $MigrationItems) {
    if ($null -eq $item) { continue }
    $status = ([string]($item.Imported ?? $item.Status) -replace '[-_\s]', '').ToLowerInvariant()
    if ($status -notin @('createdbyscript', 'updatedbyscript', 'created', 'updated', 'preexisting')) { continue }
    foreach ($cachedObject in @($item.HuduObject)) {
      $asset = Get-OmniIPAMAssetObject $cachedObject
      if ($null -eq $asset -or -not (Get-OmniIPAMAssetLayoutId $asset)) { continue }
      $companyId = Get-HuduIPAMAssetCompanyId $asset
      $assetId = Get-HuduIPAMAssetId $asset
      if (-not $companyId -or $assetId -le 0) { continue }
      if ($PSBoundParameters.ContainsKey('AllowedCompanyId') -and $companyId -notin $AllowedCompanyId) { continue }
      if (-not $seen.Add("${companyId}:$assetId")) { continue }
      $fields = @($asset.fields | Where-Object { $null -ne $_ })
      $interfaces = $item.ITGObject.attributes.'configuration-interfaces'
      if ($null -ne $interfaces -and -not [string]::IsNullOrWhiteSpace("$interfaces")) {
        $fields = @($fields | Where-Object { (Get-OmniIPAMNormalizedLabel (Get-OmniIPAMFieldLabel $_)) -ne 'configuration_interfaces' })
        $fields += [pscustomobject]@{label='Configuration Interfaces'; value=$interfaces}
      }
      # Preserve source interface masks/VLANs without altering cached Hudu objects.
      [pscustomobject]@{id=$assetId; company_id=$companyId; asset_layout_id=(Get-OmniIPAMAssetLayoutId $asset); name=$asset.name; fields=$fields}
    }
  }
}

function Get-OmniIPAMAssetLayoutId {
  param([AllowNull()]$Asset)

  $assetObject = Get-OmniIPAMAssetObject -Asset $Asset
  foreach ($candidate in @(
    $assetObject.asset_layout_id,
    $assetObject.assetLayoutId,
    $assetObject.AssetLayoutId,
    $assetObject.layout_id,
    $assetObject.layoutId
  )) {
    if ($null -ne $candidate -and "$candidate" -match '^\d+$') {
      return [int]$candidate
    }
  }

  return $null
}

function Get-OmniIPAMLayoutFields {
  param([AllowNull()]$Layout)

  foreach ($candidate in @(
    $Layout.fields,
    $Layout.asset_layout_fields,
    $Layout.assetLayoutFields,
    $Layout.layout_fields,
    $Layout.layoutFields
  )) {
    if ($null -ne $candidate) {
      return @($candidate)
    }
  }

  return @()
}

function Resolve-OmniIPAMPreferredLabel {
  param(
    [AllowNull()][string[]]$AvailableLabels,
    [AllowNull()][string[]]$CandidateLabels
  )

  $available = @($AvailableLabels | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  if ($available.Count -eq 0 -or -not $CandidateLabels) { return $null }

  $availableByNormalizedLabel = @{}
  foreach ($label in $available) {
    $normalized = Get-OmniIPAMNormalizedLabel -Label $label
    if ($normalized -and -not $availableByNormalizedLabel.ContainsKey($normalized)) {
      $availableByNormalizedLabel[$normalized] = $label
    }
  }

  foreach ($candidate in @($CandidateLabels)) {
    $normalizedCandidate = Get-OmniIPAMNormalizedLabel -Label $candidate
    if ($normalizedCandidate -and $availableByNormalizedLabel.ContainsKey($normalizedCandidate)) {
      return $availableByNormalizedLabel[$normalizedCandidate]
    }
  }

  return $null
}

function Resolve-OmniIPAMFieldLabels {
  param([string[]]$AvailableLabels, [string[]]$CandidateLabels)
  $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  foreach ($candidate in $CandidateLabels) {
    foreach ($label in $AvailableLabels) {
      if ((Get-OmniIPAMNormalizedLabel $label) -eq (Get-OmniIPAMNormalizedLabel $candidate) -and $seen.Add($label)) { $label }
    }
  }
}

function Resolve-OmniIPAMAssetLayouts {
  param(
    [AllowNull()][object[]]$AssetLayouts,
    [AllowNull()][int[]]$AssetLayoutId
  )

  $layouts = if ($PSBoundParameters.ContainsKey('AssetLayouts')) {
    @($AssetLayouts)
  } else {
    @(Get-HuduAssetLayouts)
  }

  foreach ($layout in $layouts) {
    $resolvedLayout = if ($layout.asset_layout) { $layout.asset_layout } else { $layout }
    $layoutId = Get-OmniIPAMLayoutId -Layout $resolvedLayout
    if ($AssetLayoutId -and $layoutId -notin $AssetLayoutId) { continue }
    $resolvedLayout
  }
}

function Get-OmniIPAMEligibleAssetLayout {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [Alias('IPFieldLabels','IPLabels')]
    [string[]]$IPAddressFieldLabels,

    [string[]]$HostnameFieldLabels = @('Hostname', 'Host Name', 'Device Name', 'DNS Name', 'FQDN', 'Name'),
    [string[]]$DefaultGatewayFieldLabels = @('Default Gateway', 'Gateway', 'Default Gateway IP', 'Gateway IP'),
    [AllowNull()][object[]]$AssetLayouts,
    [AllowNull()][int[]]$AssetLayoutId,
    [switch]$RequireHostname,
    [switch]$RequireGateway,
    [switch]$SkipLayoutHydration,
    [switch]$EligibleOnly
  )

  $layoutParams = @{AssetLayoutId=$AssetLayoutId}
  if ($PSBoundParameters.ContainsKey('AssetLayouts')) { $layoutParams.AssetLayouts = $AssetLayouts }
  foreach ($layout in Resolve-OmniIPAMAssetLayouts @layoutParams) {
    $layoutId = Get-OmniIPAMLayoutId -Layout $layout
    $layoutName = Get-OmniIPAMLayoutName -Layout $layout
    $fieldLabels = @(
      Get-OmniIPAMLayoutFields -Layout $layout |
        ForEach-Object { Get-OmniIPAMFieldLabel -Field $_ } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Select-Object -Unique
    )
    if (-not $SkipLayoutHydration -and $fieldLabels.Count -eq 0 -and $layoutId -and (Get-Command -Name Get-HuduAssetLayouts -ErrorAction SilentlyContinue)) {
      $hydratedLayoutResponse = Get-HuduAssetLayouts -layoutid $layoutId
      $hydratedLayout = if ($hydratedLayoutResponse.asset_layout) { $hydratedLayoutResponse.asset_layout } else { $hydratedLayoutResponse }
      $hydratedFieldLabels = @(
        Get-OmniIPAMLayoutFields -Layout $hydratedLayout |
          ForEach-Object { Get-OmniIPAMFieldLabel -Field $_ } |
          Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
          Select-Object -Unique
      )
      if ($hydratedFieldLabels.Count -gt 0) {
        $layout = $hydratedLayout
        $fieldLabels = $hydratedFieldLabels
      }
    }

    $ipLabels = @(Resolve-OmniIPAMFieldLabels -AvailableLabels $fieldLabels -CandidateLabels $IPAddressFieldLabels)
    $ipFieldLabel = $ipLabels | Select-Object -First 1
    $hostnameFieldLabel = Resolve-OmniIPAMPreferredLabel -AvailableLabels $fieldLabels -CandidateLabels $HostnameFieldLabels
    $gatewayFieldLabel = Resolve-OmniIPAMPreferredLabel -AvailableLabels $fieldLabels -CandidateLabels $DefaultGatewayFieldLabels

    $reasons = New-Object System.Collections.Generic.List[string]
    if (-not $ipFieldLabel) { $reasons.Add('No eligible IP address field label found.') | Out-Null }
    if ($RequireHostname -and -not $hostnameFieldLabel) { $reasons.Add('No eligible hostname field label found.') | Out-Null }
    if ($RequireGateway -and -not $gatewayFieldLabel) { $reasons.Add('No eligible gateway field label found.') | Out-Null }

    $eligible = ($reasons.Count -eq 0)
    if ($EligibleOnly -and -not $eligible) { continue }

    [pscustomobject]@{
      Eligible                 = $eligible
      LayoutId                 = $layoutId
      LayoutName               = $layoutName
      IPAddressFieldLabel      = $ipFieldLabel
      IPAddressFieldLabels     = $ipLabels
      HostnameFieldLabel       = $hostnameFieldLabel
      DefaultGatewayFieldLabel = $gatewayFieldLabel
      FieldLabels              = $fieldLabels
      Reason                   = if ($eligible) { 'Eligible' } else { $reasons -join ' ' }
      Layout                   = $layout
    }
  }
}



function Get-Mask32 {
  param([Parameter(Mandatory)][int]$Prefix)
  if ($Prefix -le 0) { return [uint32]0 }
  if ($Prefix -ge 32){ return [uint32]0xFFFFFFFF }
  $mask = [uint32]0
  # set the first $Prefix bits to 1 (big-endian bit positions 31..0)
  for($i = 0; $i -lt $Prefix; $i++){
    $mask = $mask -bor ([uint32]1 -shl (31 - $i))
  }
  return $mask
}

function Convert-IPv4ToUInt32 {
  param([Parameter(Mandatory)][string]$Ip)
  $bytes = [System.Net.IPAddress]::Parse($Ip).GetAddressBytes()
  if ($bytes.Length -ne 4) { throw "IPv4 only: $Ip" }
  [Array]::Reverse($bytes)
  [BitConverter]::ToUInt32($bytes, 0)
}

function Convert-UInt32ToIPv4 {
  param([Parameter(Mandatory)][uint32]$Value)
  $bytes = [BitConverter]::GetBytes($Value)
  [Array]::Reverse($bytes)
  ([System.Net.IPAddress]::new($bytes)).ToString()
}

function Parse-Cidr {
  param([Parameter(Mandatory)][string]$Cidr) # e.g. "10.0.33.0/24"
  $ip, $prefix = $Cidr -split '/', 2
  $prefix = [int]$prefix
  if ($prefix -lt 0 -or $prefix -gt 32) { throw "Bad prefix: $prefix in $Cidr" }

  $netU = Convert-IPv4ToUInt32 $ip

  if ($prefix -eq 0) {
    $mask = [uint32]0
  } else {
    $rightZeros = 32 - $prefix
    # Build a mask of top $prefix 1-bits by inverting $rightZeros low 1-bits.
    $lowOnes = ([uint32]1 -shl $rightZeros) - 1      # 0…00011111111
    $mask    = -bnot $lowOnes                        # 1…11100000000
  }

  $start = $netU -band $mask
  $end   = $start -bor ((-bnot $mask) -band 0xFFFFFFFF)

  [pscustomobject]@{
    Cidr   = $Cidr
    Prefix = $prefix
    Start  = $start
    End    = $end
  }
}

function Test-CidrContains {
  param([Parameter(Mandatory)][string]$Outer,
        [Parameter(Mandatory)][string]$Inner)
  try {
    $o = Parse-Cidr $Outer
    $i = Parse-Cidr $Inner
    ($i.Start -ge $o.Start -and $i.End -le $o.End)
  } catch { $false }
}


function Get-NetworkChain {
  param(
    [Parameter(Mandatory)]$Network,
    [Parameter(Mandatory)][object[]]$AllNetworks
  )
  $chain = New-Object System.Collections.Generic.List[object]
  $chain.Add($Network) | Out-Null

  if ($Network.ancestry) {
    $ids = $Network.ancestry -split '/' | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ }
    foreach ($parentId in $ids) {
      $p = $AllNetworks | Where-Object id -eq $parentId | Select-Object -First 1
      if ($p) { $chain.Add($p) | Out-Null }
    }
  } else {
    foreach ($p in $AllNetworks) {
      if ($p.id -ne $Network.id -and $p.address -and (Test-CidrContains -Outer $p.address -Inner $Network.address)) {
        $chain.Add($p) | Out-Null
      }
    }
  }

  $chain | Sort-Object { (Parse-Cidr $_.address).Prefix } -Descending
}

# --- helpers for extraction / normalization -----------------------------------
function Get-AsArray { param($x) if ($null -eq $x) { @() } elseif ($x -is [System.Collections.IEnumerable] -and -not ($x -is [string])) { @($x) } else { ,$x } }

function Get-HuduAssetFieldValue {
  param(
    [Parameter(Mandatory)]$Asset,
    [Parameter(Mandatory)][string]$Label
  )

  if ($null -eq $Asset -or $null -eq $Asset.fields) { return $null }

  $field = @(
    $Asset.fields | Where-Object {
      (Get-OmniIPAMNormalizedLabel (Get-OmniIPAMFieldLabel $_)) -eq (Get-OmniIPAMNormalizedLabel $Label)
    } | Select-Object -First 1
  )[0]

  if ($null -eq $field) { return $null }
  $field.value
}

$__Ipv4Rx = '(?<!\d)(?:25[0-5]|2[0-4]\d|1?\d{1,2})(?:\.(?:25[0-5]|2[0-4]\d|1?\d{1,2})){3}(?!\d)'

function Extract-IPv4sFromString {
  param([string]$Text)
  if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
  [regex]::Matches($Text, $__Ipv4Rx) | ForEach-Object { $_.Value } | Select-Object -Unique
}

function Extract-IPv4sFromInterfaces {
  <#
    Accepts many shapes:
      - JSON string of objects: [{ "ip":"10.0.1.12", "mask":24, "vlan_id":10 }, ...]
      - PSCustomObjects with properties: .ip / .address / .cidr / .mask / .netmask / .vlan / .vlan_id
      - Mixed text blob (“eth0: 10.0.1.12/24 vlan 10”)
    Returns objects with { IP, Prefix?, Netmask?, VlanId? }
  #>
  param($InterfacesValue)

  $results = New-Object System.Collections.Generic.List[object]

  foreach ($piece in (Get-AsArray $InterfacesValue)) {
    $raw = $piece
    # try JSON first
    if ($raw -is [string] -and $raw.TrimStart() -match '^[\[{]') {
      try {
        $arr = $raw | ConvertFrom-Json -ErrorAction Stop
        foreach ($it in @($arr)) {
          $ip  = $it.ip ?? $it.address
          $cidr= $it.cidr ?? $it.prefix
          $mask= $it.mask ?? $it.netmask
          $vid = $it.vlan_id ?? $it.vlan ?? $it.vlanId
          if ($ip -and ($ip -match $__Ipv4Rx)) {
            $o = [pscustomobject]@{
              IP      = $ip
              Prefix  = $cidr
              Netmask = $mask
              VlanId  = $vid
            }
            $results.Add($o) | Out-Null
          }
        }
        continue
      } catch { Write-Warning 'Skipping an invalid JSON interface value.'; continue }
    }

    # structured object (PSCustomObject/Hashtable)
    if ($raw -isnot [string]) {
      $ip  = $raw.ip ?? $raw.address ?? $raw.IP
      $cidr= $raw.cidr ?? $raw.CIDR ?? $raw.prefix ?? $raw.Prefix
      $mask= $raw.mask ?? $raw.netmask ?? $raw.Netmask
      $vid = $raw.vlan_id ?? $raw.vlan ?? $raw.VlanId ?? $raw.Vlan
      if ($ip -and ($ip -match $__Ipv4Rx)) {
        $results.Add([pscustomobject]@{ IP=$ip; Prefix=$cidr; Netmask=$mask; VlanId=$vid }) | Out-Null
        continue
      }
    }

    # fallback: parse any IPv4s out of strings
    foreach ($ip in Extract-IPv4sFromString -Text ([string]$raw)) {
      # try to detect /XX and vlan N around it
      $prefix = ([regex]::Match([string]$raw, [regex]::Escape($ip) + '/(\d{1,2})')).Groups[1].Value
      $vid    = ([regex]::Match([string]$raw, '\bvlan\s+(\d{1,4})\b', 'IgnoreCase')).Groups[1].Value
      $results.Add([pscustomobject]@{
        IP      = $ip
        Prefix  = ($prefix ? [int]$prefix : $null)
        Netmask = $null
        VlanId  = ($vid ? [int]$vid : $null)
      }) | Out-Null
    }
  }

  $($results | ForEach-Object { $_ })
}

function Collect-CompanyIpObservations {
  <#
    Input: $ConfigCollection from your per-device loop
    Output: @(
      [pscustomobject]@{ IP='10.0.1.12'; Gateways=@('10.0.1.1'); Hostnames=@('PC-12'); VlanIds=@(10); ObservedMasks=@(24) }
    )
  #>
  param(
    [Parameter(Mandatory)] $ConfigCollection,
    [string]$HostnameText = $null
  )

  $bucket = @{} # key = ip ; value = mutable psobj

  # pull from “primary_ip”, “default_gateway”, and “configuration_interfaces”
  foreach ($row in (Get-AsArray $ConfigCollection)) {
    $primaryIpText = $row.primary_ip
    if ([string]::IsNullOrWhiteSpace("$primaryIpText") -and $row.HuduObject) {
      $primaryIpText = Get-HuduAssetFieldValue -Asset $row.HuduObject -Label 'Primary IP'
    }

    $defaultGatewayText = $row.default_gateway
    if ([string]::IsNullOrWhiteSpace("$defaultGatewayText") -and $row.HuduObject) {
      $defaultGatewayText = Get-HuduAssetFieldValue -Asset $row.HuduObject -Label 'Default Gateway'
    }

    $interfacesValue = $row.configuration_interfaces
    if ($null -eq $interfacesValue -and $row.HuduObject) {
      $interfacesValue = Get-HuduAssetFieldValue -Asset $row.HuduObject -Label 'Configuration Interfaces'
    }

    $hostnameValue = $row.hostname
    if ([string]::IsNullOrWhiteSpace("$hostnameValue") -and $row.HuduObject) {
      $hostnameValue = Get-HuduAssetFieldValue -Asset $row.HuduObject -Label 'Hostname'
    }

    foreach ($ip in Extract-IPv4sFromString -Text $primaryIpText) {
      if (-not $bucket.ContainsKey($ip)) { $bucket[$ip] = [pscustomobject]@{ IP=$ip; Gateways=@(); Hostnames=@(); VlanIds=@(); ObservedMasks=@() } }
    }

    foreach ($gw in Extract-IPv4sFromString -Text $defaultGatewayText) {
      # try to associate gateway with peers in same /24 later; still record as an observed gateway
      if (-not $bucket.ContainsKey($gw)) { $bucket[$gw] = [pscustomobject]@{ IP=$gw; Gateways=@(); Hostnames=@(); VlanIds=@(); ObservedMasks=@() } }
      # mark it as a gateway (itself)
      $bucket[$gw].Gateways += $gw
    }

    # interfaces (best source of vlan + prefix)
    foreach ($iface in Extract-IPv4sFromInterfaces -InterfacesValue $interfacesValue) {
      $ip = $iface.IP
      if (-not $ip) { continue }
      if (-not $bucket.ContainsKey($ip)) { $bucket[$ip] = [pscustomobject]@{ IP=$ip; Gateways=@(); Hostnames=@(); VlanIds=@(); ObservedMasks=@() } }
      if ($iface.VlanId)   { $bucket[$ip].VlanIds += [int]$iface.VlanId }
      if ($iface.Prefix)   { $bucket[$ip].ObservedMasks += [int]$iface.Prefix }
      elseif ($iface.Netmask -match $__Ipv4Rx) {
        # convert dotted mask to prefix
        $prefix = ([System.Net.IPAddress]::Parse($iface.Netmask).GetAddressBytes() | ForEach-Object {
          [Convert]::ToString($_,2).PadLeft(8,'0')
        }) -join ''
        $bucket[$ip].ObservedMasks += ($prefix.ToCharArray() | Where-Object { $_ -eq '1' } | Measure-Object).Count
      }
    }

    if ($hostnameValue) {
      foreach ($ip in Extract-IPv4sFromString -Text $primaryIpText) {
        $bucket[$ip].Hostnames += "$hostnameValue"
      }
    }
  }

  # optional: a hostname string passed in
  if ($HostnameText) {
    foreach ($ip in Extract-IPv4sFromString -Text $HostnameText) {
      if (-not $bucket.ContainsKey($ip)) { $bucket[$ip] = [pscustomobject]@{ IP=$ip; Gateways=@(); Hostnames=@(); VlanIds=@(); ObservedMasks=@() } }
    }
  }

  # dedupe lists
  foreach ($k in $bucket.Keys) {
    $bucket[$k].Gateways      = @($bucket[$k].Gateways      | Select-Object -Unique)
    $bucket[$k].Hostnames     = @($bucket[$k].Hostnames     | Where-Object { $_ } | Select-Object -Unique)
    $bucket[$k].VlanIds       = @($bucket[$k].VlanIds       | Where-Object { $_ -ne 0 } | Select-Object -Unique)
    $bucket[$k].ObservedMasks = @($bucket[$k].ObservedMasks | Where-Object { $_ -ge 8 -and $_ -le 32 } | Select-Object -Unique)
  }

  $bucket.Values
}

function Convert-HuduIPAMAddressFieldToInterfaces {
  param(
    [Parameter(Mandatory)]$AddressValue,
    [ValidateRange(8,30)][int]$DefaultPrivatePrefix = 24,
    [ValidateRange(0,32)][int]$DefaultPublicPrefix = 32,
    [switch]$DeferDefaultPrefix
  )

  $interfaces = New-Object System.Collections.Generic.List[object]
  $seen = New-Object System.Collections.Generic.HashSet[string]

  foreach ($iface in Extract-IPv4sFromInterfaces -InterfacesValue $AddressValue) {
    $ip, $inlinePrefix = [string]$iface.IP -split '/', 2
    if ([string]::IsNullOrWhiteSpace("$ip")) { continue }
    if ([regex]::Match($ip, "^$__Ipv4Rx`$").Value -ne $ip) { continue }

    $prefix = $null
    $explicitPrefix = $iface.Prefix ?? $inlinePrefix
    if (-not [string]::IsNullOrWhiteSpace("$explicitPrefix")) {
      if ("$explicitPrefix" -notmatch '(?:^|/)(\d{1,2})$') { Write-Warning "Skipping invalid prefix for $ip."; continue }
      $prefix = [int]$Matches[1]
      if ($prefix -gt 32) { Write-Warning "Skipping invalid prefix for $ip."; continue }
    }
    if ($null -eq $prefix -and -not [string]::IsNullOrWhiteSpace("$($iface.Netmask)")) {
      $mask = [string]$iface.Netmask
      if ($mask -match '^\d{1,2}$' -and [int]$mask -le 32) { $prefix = [int]$mask }
      else {
        $maskAddress = $null
        if (-not [Net.IPAddress]::TryParse($mask, [ref]$maskAddress) -or $maskAddress.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { Write-Warning "Skipping invalid netmask for $ip."; continue }
        $bits = ($maskAddress.GetAddressBytes() | ForEach-Object { [Convert]::ToString($_, 2).PadLeft(8, '0') }) -join ''
        if ($bits -notmatch '^1*0*$') { Write-Warning "Skipping noncontiguous netmask for $ip."; continue }
        $prefix = ($bits -replace '0', '').Length
      }
    }
    if ($null -eq $prefix -and -not $DeferDefaultPrefix) {
      $prefix = if (Test-Rfc1918 -Ip $ip) { $DefaultPrivatePrefix } else { $DefaultPublicPrefix }
    }

    $key = "$ip|$prefix|$($iface.Netmask)|$($iface.VlanId)"
    if (-not $seen.Add($key)) { continue }

    $interfaces.Add([pscustomobject]@{
      IP      = $ip
      Prefix  = $prefix
      Netmask = $iface.Netmask
      VlanId  = $iface.VlanId
    }) | Out-Null
  }

  $interfaces | ForEach-Object { $_ }
}

function Get-HuduIPAMAssetCompanyId {
  param(
    [Parameter(Mandatory)]$Asset,
    [int]$CompanyId = 0
  )

  if ($CompanyId -gt 0) { return $CompanyId }
  foreach ($candidate in @($Asset.company_id, $Asset.companyId, $Asset.CompanyId, $Asset.company.id)) {
    if ($null -ne $candidate -and "$candidate" -match '^\d+$' -and [int]$candidate -gt 0) {
      return [int]$candidate
    }
  }

  return $null
}

function Get-HuduIPAMAssetId {
  param([Parameter(Mandatory)]$Asset)

  foreach ($candidate in @($Asset.id, $Asset.asset_id, $Asset.assetId, $Asset.AssetId)) {
    if ($null -ne $candidate -and "$candidate" -match '^\d+$') {
      return [int]$candidate
    }
  }

  return 0
}

function Get-HuduIPAMAssetName {
  param([Parameter(Mandatory)]$Asset)

  foreach ($candidate in @($Asset.name, $Asset.Name, $Asset.title, $Asset.Title)) {
    if (-not [string]::IsNullOrWhiteSpace("$candidate")) {
      return "$candidate"
    }
  }

  return $null
}

function Invoke-HuduAssetIPAMSync {
  <#
    Builds Hudu IPAM from an arbitrary Hudu asset array by reading one field label
    as the IP source. Example:
      Invoke-HuduAssetIPAMSync -Assets $assets -IPAddressFieldLabel 'Management IP'
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory, ValueFromPipeline)]$Assets,
    [Parameter(Mandatory)]
    [Alias('FieldLabel','IPFieldLabel','Label','IPAddressFieldLabels')]
    [string[]]$IPAddressFieldLabel,
    [int]$CompanyId = 0,
    [string]$HostnameFieldLabel = 'Hostname',
    [string]$DefaultGatewayFieldLabel = 'Default Gateway',
    [ValidateRange(8,30)][int]$DefaultPrivatePrefix = 24,
    [ValidateRange(0,32)][int]$DefaultPublicPrefix = 32
  )

  begin {
    $assetList = New-Object System.Collections.Generic.List[object]
  }

  process {
    foreach ($asset in (Get-AsArray $Assets)) {
      if ($null -ne $asset) {
        $assetList.Add($asset) | Out-Null
      }
    }
  }

  end {
    $matchedAssets = @(
      foreach ($asset in $assetList) {
        $companyIdForAsset = Get-HuduIPAMAssetCompanyId -Asset $asset -CompanyId $CompanyId
        if ($null -eq $companyIdForAsset) {
          Write-Warning "Skipping asset '$((Get-HuduIPAMAssetName -Asset $asset) ?? '<unnamed>')' because it has no company_id. Pass -CompanyId to override."
          continue
        }

        $interfaces = @(
          foreach ($label in $IPAddressFieldLabel) {
            $value = Get-HuduAssetFieldValue -Asset $asset -Label $label
            if ($null -ne $value -and -not [string]::IsNullOrWhiteSpace("$value")) {
              Convert-HuduIPAMAddressFieldToInterfaces -AddressValue $value -DeferDefaultPrefix
            }
          }
        )
        if ($interfaces.Count -eq 0) { continue }
        foreach ($group in @($interfaces | Group-Object IP)) {
          $explicit = @($group.Group | Where-Object { $null -ne $_.Prefix })
          foreach ($iface in $group.Group) {
            if ($null -eq $iface.Prefix) {
              $iface.Prefix = if ($explicit.Count -gt 0) { $explicit[0].Prefix } elseif (Test-Rfc1918 $iface.IP) { $DefaultPrivatePrefix } else { $DefaultPublicPrefix }
            }
          }
        }

        $assetId = Get-HuduIPAMAssetId -Asset $asset
        $assetName = Get-HuduIPAMAssetName -Asset $asset

        $hostname = $null
        if (-not [string]::IsNullOrWhiteSpace($HostnameFieldLabel)) {
          $hostname = Get-HuduAssetFieldValue -Asset $asset -Label $HostnameFieldLabel
        }
        if ([string]::IsNullOrWhiteSpace("$hostname")) {
          $hostname = $assetName
        }

        $defaultGateway = $null
        if (-not [string]::IsNullOrWhiteSpace($DefaultGatewayFieldLabel)) {
          $defaultGateway = Get-HuduAssetFieldValue -Asset $asset -Label $DefaultGatewayFieldLabel
        }

        $attributes = [pscustomobject]@{
          # Feed only parsed host addresses to the observation/assignment path;
          # regex-scanning a JSON blob would also import its dotted netmasks.
          'primary-ip'                 = (@($interfaces.IP | Select-Object -Unique) -join "`n")
          'default-gateway'            = $defaultGateway
          hostname                     = $hostname
          'configuration-interfaces'   = $interfaces
        }

        $huduObject = [pscustomobject]@{
          id         = $assetId
          company_id = $companyIdForAsset
          name       = $assetName
          fields     = @()
        }

        [pscustomobject]@{
          HuduID     = $assetId
          HuduObject = $huduObject
          ITGObject  = [pscustomobject]@{ attributes = $attributes }
          Name       = $assetName
        }
      }
    )

    if ($matchedAssets.Count -eq 0) {
      Write-Host "No assets with field '$IPAddressFieldLabel' found for IPAM import."
      return
    }

    Invoke-HuduConfigurationIPAMSync -MatchedConfigurations $matchedAssets
  }
}

function Invoke-HuduConfigurationIPAMSync {
  param(
    [Parameter(Mandatory)]$MatchedConfigurations
  )
  $IPAMResults = [System.Collections.ArrayList]@()

  $configsWithCompanies = @(
    $MatchedConfigurations | Where-Object {
      $null -ne $_.HuduID -and
      $null -ne $_.HuduObject -and
      $null -ne $_.HuduObject.company_id
    }
  )

  if ($configsWithCompanies.Count -eq 0) {
    Write-Host "No matched configurations found for IPAM import."
    return
  }

  $configGroups = $configsWithCompanies | Group-Object { "$($_.HuduObject.company_id)" } -AsHashTable -AsString

  foreach ($companyIdKey in $configGroups.Keys) {
    $configsForCompany = @($configGroups[$companyIdKey])
    if ($configsForCompany.Count -eq 0) { continue }
    $CompanyResults = @{}

    [int]$companyId = $companyIdKey
    Write-Host "Company ID $companyId has $($configsForCompany.Count) matched configurations for IPAM processing"

    $configCollection = @(
      foreach ($matchedConfig in $configsForCompany) {
        $primaryIp = Get-HuduAssetFieldValue -Asset $matchedConfig.HuduObject -Label 'Primary IP'
        $defaultGateway = Get-HuduAssetFieldValue -Asset $matchedConfig.HuduObject -Label 'Default Gateway'
        $hostname = Get-HuduAssetFieldValue -Asset $matchedConfig.HuduObject -Label 'Hostname'

        if ([string]::IsNullOrWhiteSpace("$primaryIp")) {
          $primaryIp = $matchedConfig.ITGObject.attributes.'primary-ip'
        }
        if ([string]::IsNullOrWhiteSpace("$defaultGateway")) {
          $defaultGateway = $matchedConfig.ITGObject.attributes.'default-gateway'
        }
        if ([string]::IsNullOrWhiteSpace("$hostname")) {
          $hostname = $matchedConfig.ITGObject.attributes.hostname
        }
        if ([string]::IsNullOrWhiteSpace("$hostname")) {
          $hostname = $matchedConfig.Name
        }

        [pscustomobject]@{
          primary_ip               = $primaryIp
          default_gateway          = $defaultGateway
          hostname                 = $hostname
          configuration_interfaces = $matchedConfig.ITGObject.attributes.'configuration-interfaces'
          HuduObject               = $matchedConfig.HuduObject
          HuduID                   = $matchedConfig.HuduID
        }
      }
    )

    $obs = @(Collect-CompanyIpObservations -ConfigCollection $configCollection)
    if ($obs.Count -eq 0) {
      Write-Host "No IP observations for company ID $companyId; skipping IPAM."
      continue
    }
    $CompanyResults["Observations"]=$obs

    $cidrs = @(Guess-NetworksFromObservations -Observations $obs)
    $cidrs = @(Convert-OmniIPAMPublicNetworksToHostCidrs -Cidrs $cidrs -Observations $obs)
    Write-Host "$($cidrs.Count) observed CIDRs for company ID $companyId"
    if ($cidrs.Count -gt 0) {
      Write-Host "Inferred $($cidrs.Count) candidate networks for company ID ${companyId}: $($cidrs -join ', ')"
    }


    $ensuredNetworks = New-Object System.Collections.Generic.List[object]
    $ensuredIpAddresses = New-Object System.Collections.Generic.List[object]

    
    if (($cidrs.Count -eq 0) -and ($obs.Count -gt 0)) {
      $publicSingles = @(
        $obs |
          Where-Object { -not (Test-Rfc1918 -Ip $_.IP) } |
          Select-Object -ExpandProperty IP -Unique
      )

      foreach ($publicIp in $publicSingles) {
        $net = Ensure-HuduNetwork -CompanyId $companyId -Address $publicIp -Description 'Auto-imported from configurations (public host)'
        if ($net) { $ensuredNetworks.Add($net) | Out-Null }
      }
    }

    foreach ($cidr in $cidrs) {
      Write-Host "Processing network for CIDR $cidr"
      $net = Ensure-HuduNetwork -CompanyId $companyId -Address $cidr -Name $cidr -Description 'Auto-imported from configurations'
      if ($net) { $ensuredNetworks.Add($net) | Out-Null }
    }

    $networkIndex = if ($ensuredNetworks.Count -gt 0) { @(Build-NetworkIndex -Networks @($ensuredNetworks | ForEach-Object { $_ })) } else { @() }
    if ($networkIndex.Count -eq 0) {
      Write-Host "No networks were created or matched for company ID $companyId; skipping IP creation."
      continue
    }

    $obsByIp = @{}
    foreach ($observation in $obs) {
      if (-not $obsByIp.ContainsKey($observation.IP)) {
        $obsByIp[$observation.IP] = $observation
      }
    }

    $assetIdsByIp = @{}
    foreach ($row in $configCollection) {
      foreach ($ip in Extract-IPv4sFromString -Text $row.primary_ip) {
        $assetId = $row.HuduObject.id
        if (-not $assetId) {
          $assetId = $row.HuduID
        }

        if (-not $assetIdsByIp.ContainsKey($ip) -and $assetId) {
          $assetIdsByIp[$ip] = [int]$assetId
        }
      }
    }

    foreach ($ip in ($obsByIp.Keys | Sort-Object)) {
      $net = Find-NetworkForIp -Ip $ip -NetworkIndex $networkIndex -CompanyId $companyId
      if ($null -eq $net) { continue }

      $ipParams = @{
        Address     = $ip
        CompanyId   = $companyId
        NetworkId   = $net.id
        Description = 'Auto-imported from configurations'
      }

      $fqdn = @($obsByIp[$ip].Hostnames | Where-Object { $_ } | Select-Object -First 1)[0]
      if ($fqdn) {
        $ipParams.FQDN = $fqdn
      }

      if ($assetIdsByIp.ContainsKey($ip)) {
        $ipParams.AssetId = $assetIdsByIp[$ip]
        $ipParams.Status = 'assigned'
      } else {
        $ipParams.Status = 'unassigned'
      }

      $ipObj = Ensure-HuduIPAddress @ipParams
      if ($ipObj) { $ensuredIpAddresses.Add($ipObj) | Out-Null }
    }

    $vlanIds = @(
      $obs |
        ForEach-Object { $_.VlanIds } |
        Where-Object { $_ -ge 1 -and $_ -le 4094 } |
        Sort-Object -Unique
    )
    if ($vlanIds.Count -gt 0) {
      $vlanRanges = Compress-IntsToRanges -Ints $vlanIds
      $zone = Ensure-HuduVlanZone -CompanyId $companyId -ZoneName 'Imported VLANs' -Ranges $vlanRanges
      foreach ($vlanId in $vlanIds) {
        if ($zone) {
          Ensure-HuduVlan -CompanyId $companyId -VlanId $vlanId -ZoneId $zone.id -Name "VLAN $vlanId" | Out-Null
        } else {
          Ensure-HuduVlan -CompanyId $companyId -VlanId $vlanId -Name "VLAN $vlanId" | Out-Null
        }
      }
    }
    $CompanyResults["Networks"]=$ensuredNetworks
    $CompanyResults["Addresses"]=$ensuredIpAddresses
    $CompanyResults["VLANIDs"]=$vlanIds
    [void]$IPAMResults.Add($CompanyResults)

    Write-Host "Company ID $companyId IPAM summary: $($ensuredNetworks.Count) networks, $($ensuredIpAddresses.Count) IP addresses"
  }
  return $IPAMResults
}

function Guess-NetworksFromObservations {
  <#
    Strategy:
      - If we see a gateway X.Y.Z.1 or .254 with peers sharing X.Y.Z.*, we propose /24 X.Y.Z.0/24.
      - Else, if multiple ObservedMasks exist on hosts (e.g., 23 or 25), we honor the most common.
      - Else, crowd cluster by first 3 octets (/24) when >= 2 hosts observed.
    Returns unique CIDR strings.
  #>
  param([Parameter(Mandatory)]$Observations)

  $cidrs = New-Object System.Collections.Generic.HashSet[string]

  # group by /24 stem
  $byStem = $Observations | Group-Object {
    $parts = $_.IP.Split('.')
    if ($parts.Length -eq 4) { "$($parts[0]).$($parts[1]).$($parts[2])" } else { 'other' }
  }

  foreach ($g in $byStem) {
    if ($g.Name -eq 'other') { continue }
    $peers = @($g.Group)

    # gateway hint
    $gwCandidates = $peers | Where-Object {
      $_.IP -match '(\.1|\.254)$' -or ($_.Gateways -contains $_.IP)
    }

    $chosenPrefix = $null
    $prefixVotes  = @{}
    foreach ($o in $peers) {
      foreach ($p in $o.ObservedMasks) {
        $prefixVotes[$p] = 1 + ($prefixVotes[$p] ?? 0)
      }
    }
    if ($prefixVotes.Keys.Count -gt 0) {
      $chosenPrefix = ($prefixVotes.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1).Key
    }

    if (-not $chosenPrefix) {
      if ($gwCandidates.Count -gt 0 -or $peers.Count -ge 2) { $chosenPrefix = 24 }
    }

    if ($chosenPrefix) {
      $firstPeerIp = @($peers | Select-Object -ExpandProperty IP -First 1)[0]
      try {
        $network = Parse-Cidr ("{0}/{1}" -f $firstPeerIp, [int]$chosenPrefix)
        $netStart = Convert-UInt32ToIPv4 -Value ([uint32]$network.Start)
        $cidrs.Add("$netStart/$chosenPrefix") | Out-Null
      } catch {
        Write-Warning "Could not infer network base for $firstPeerIp/$chosenPrefix. $($_.Exception.Message)"
      }
    }
  }

  # also: when we have explicit prefix per observation (e.g., from / interfaces), honor those /32 or /30 (rare)
  foreach ($o in $Observations) {
    foreach ($p in $o.ObservedMasks) {
      try {
        # derive network base from host/prefix
        $row = Parse-Cidr ("{0}/{1}" -f $o.IP, [int]$p)
        $netIp = Convert-UInt32ToIPv4 -Value ([uint32]$row.Start)
        $cidrs.Add("$netIp/$p") | Out-Null
      } catch {}
    }
  }

  return $($cidrs | ForEach-Object { $_ })
}
function Compress-IntsToRanges {
  param([int[]]$Ints) # not mandatory

  if (-not $Ints -or $Ints.Count -eq 0) { return $null }

  $vals = $Ints | Where-Object { $_ -ge 1 -and $_ -le 4094 } | Sort-Object -Unique
  if ($vals.Count -eq 0) { return $null }

  $ranges = New-Object System.Collections.Generic.List[string]
  $start = $vals[0]; $prev = $start
  for ($i = 1; $i -lt $vals.Count; $i++) {
    $cur = $vals[$i]
    if ($cur -eq $prev + 1) { $prev = $cur; continue }
       if ($start -eq $prev) { $ranges.Add("$start") | Out-Null} else { $ranges.Add("$start-$prev") | Out-Null } 
    $start = $prev = $cur
  }
  if ($start -eq $prev) { $ranges.Add("$start") | Out-Null } else { $ranges.Add("$start-$prev") | Out-Null } 
  ($ranges -join ',')
}
function Test-CidrEquivalent {
  param([Parameter(Mandatory)][string]$A, [Parameter(Mandatory)][string]$B)
  try {
    $pa = Parse-Cidr $A
    $pb = Parse-Cidr $B
    return ($pa.Start -eq $pb.Start -and $pa.End -eq $pb.End)
  } catch { $false }
}

function Test-Rfc1918 {
  param([Parameter(Mandatory)][string]$Ip)
  switch -regex ($Ip) {
    '^10\.'                                  { return $true }
    '^172\.(1[6-9]|2[0-9]|3[0-1])\.'         { return $true }
    '^192\.168\.'                            { return $true }
    default                                  { return $false }
  }
}

function Build-NetworkIndex {
  param([Parameter(Mandatory)][object[]]$Networks)
  $rows = @()
  foreach ($n in @($Networks)) {
    $cidrObj = if ($n.address) { Parse-Cidr $n.address } else { $null }
    if ($cidrObj) {
      $rows += [pscustomobject]@{ Network = $n; Cidr = $cidrObj }
    } else {
      # Log once but do not throw
      Write-Host "Skip bad network address: $($n.address)" -ForegroundColor Yellow
    }
  }
  # Always return an array (possibly empty), never $null
  @($rows | Sort-Object { $_.Cidr.Prefix } -Descending)
}

function Find-NetworkForIp {
  param(
    [Parameter(Mandatory)][string]$Ip,
    [Parameter(Mandatory)][object[]]$NetworkIndex,
    [int]$CompanyId = $null
  )
  if (-not $NetworkIndex) { return $null }   # guard
  $ipU = Convert-IPv4ToUInt32 $Ip
  if ($null -eq $ipU) { return $null }

  foreach ($row in $NetworkIndex) {
    $n = $row.Network
    if ($CompanyId -and $n.company_id -ne $CompanyId) { continue }
    $c = $row.Cidr
    if ($ipU -ge $c.Start -and $ipU -le $c.End) { return $n }
  }
  $null
}
function Group-IpAddressesByNetwork {
  param(
    [Parameter(Mandatory)][object[]]$IpAddresses,
    [Parameter(Mandatory)][object[]]$Networks,
    [int]$CompanyId = $null
  )

  $idx = Build-NetworkIndex -Networks $Networks
  if ($null -eq $idx) { $idx = @() }  # harden

  $groups = @{}
  foreach ($ip in @($IpAddresses)) {
    if (-not $ip.address) { continue }
    if ($CompanyId -and $ip.company_id -ne $CompanyId) { continue }

    $net = Find-NetworkForIp -Ip $ip.address -NetworkIndex $idx -CompanyId $CompanyId
    $key = if ($net) { "net:$($net.id)" } else { "unmatched" }

    if (-not $groups.ContainsKey($key)) {
      $groups[$key] = [pscustomobject]@{ Network = $net; IPs = New-Object System.Collections.Generic.List[object] }
    }
    $groups[$key].IPs.Add($ip) | Out-Null
  }

  $groups.Values
}

function Ensure-Cidr {
  param([Parameter(Mandatory)][string]$AddressOrHost, [int]$DefaultPrefix = 32)
  if ($AddressOrHost -match '/\d{1,2}$') { return $AddressOrHost }
  return "$AddressOrHost/$DefaultPrefix"
}

function Convert-OmniIPAMPublicNetworksToHostCidrs {
  param(
    [AllowNull()][string[]]$Cidrs,
    [Parameter(Mandatory)][object[]]$Observations
  )

  $results = New-Object System.Collections.Generic.HashSet[string]

  foreach ($cidr in @($Cidrs)) {
    if ([string]::IsNullOrWhiteSpace($cidr)) { continue }

    $baseIp = ($cidr -split '/', 2)[0]
    if (Test-Rfc1918 -Ip $baseIp) {
      $results.Add($cidr) | Out-Null
    }
  }

  foreach ($observation in @($Observations)) {
    $ip = [string]$observation.IP
    if ([string]::IsNullOrWhiteSpace($ip)) { continue }
    if (-not (Test-Rfc1918 -Ip $ip)) {
      $results.Add("$ip/32") | Out-Null
    }
  }

  $results | ForEach-Object { $_ }
}

function Ensure-HuduIPAddress {
  param(
    [Parameter(Mandatory)][string]$Address,
    [Parameter(Mandatory)][int]$CompanyId,
    [Parameter(Mandatory)][int]$NetworkId,
    [string]$Status,
    [string]$FQDN,
    [string]$Description='',
    [string]$Notes='',
    [int]$AssetId,
    [bool]$SkipDNSValidation=$true
  )

  # Try to find existing IP by company+network+address (adjust if your API exposes a direct GET)
  $existing = (Get-HuduIPAddresses -CompanyId $CompanyId) |  Where-Object { $_.address -eq $Address } | Select-Object -First 1
  if ($existing) { return $existing }

  $newIpParams = @{
    Address = $Address
    CompanyID = $CompanyId
    NetworkId = $NetworkId
    SkipDNSValidation = $SkipDNSValidation
  }

  $newIpCommand = Get-Command -Name New-HuduIPAddress -ErrorAction SilentlyContinue

  if (
    $PSBoundParameters.ContainsKey('Status') -and
    -not [string]::IsNullOrWhiteSpace($Status) -and
    $null -ne $newIpCommand -and
    $newIpCommand.Parameters.ContainsKey('Status')
  ) {
    $newIpParams.Status = $Status
  }
  if ($PSBoundParameters.ContainsKey('FQDN') -and -not [string]::IsNullOrWhiteSpace($FQDN)) {
    $newIpParams.FQDN = $FQDN
  }
  if ($PSBoundParameters.ContainsKey('Description') -and -not [string]::IsNullOrWhiteSpace($Description)) {
    $newIpParams.Description = $Description
  }
  if ($PSBoundParameters.ContainsKey('Notes') -and -not [string]::IsNullOrWhiteSpace($Notes)) {
    $newIpParams.Notes = $Notes
  }
  if ($PSBoundParameters.ContainsKey('AssetId') -and $AssetId -gt 0) {
    $newIpParams.AssetID = $AssetId
  }

  return $(New-HuduIPAddress @newIpParams)
}
function Ensure-HuduNetwork {
  param(
    [Parameter(Mandatory)][int]$CompanyId,
    [Parameter(Mandatory)][string]$Address,   # host or CIDR
    [string]$Name,
    [string]$Description,
    [int]$NetworkType # 0=private(default), 1=public
  )

  $Address = $Address.Trim()
  $isHost = ($Address -notmatch '/')
  if ($Address -notmatch '/\d{1,2}$') {
    # normalize any bare private host as /24 by default (tweak to your taste)
    $defaultPrefix = if (-not (Test-Rfc1918 -Ip $Address)) { 32 } else { 24 }
    $Address = Ensure-Cidr -AddressOrHost $Address -DefaultPrefix $defaultPrefix
  }

  $baseIp = ($Address -split '/', 2)[0]
  if (-not $PSBoundParameters.ContainsKey('NetworkType')) {
    $NetworkType = if (Test-Rfc1918 -Ip $baseIp) { 0 } else { 1 }
  }

  if ($NetworkType -eq 1 -and -not (Test-Rfc1918 -Ip $baseIp) -and $Address -notmatch '/32$') {
    $Address = "$baseIp/32"
  }

  $Name = $Name ?? $Address

  $existing = Get-HuduNetworks -CompanyId $CompanyId | Where-Object {
      if (-not $_.address) { return $false }

      $same  = ($_.address -eq $Address)
      $cover = (Test-CidrContains -Outer $_.address -Inner $Address) -and
              (Test-CidrContains -Outer $Address     -Inner $_.address)

      return ($same -or $cover)
  } | Select-Object -First 1

  if ($existing) { return $existing }

  Write-Host "Creating Network $Address (type=$([string]($NetworkType ?? 0))) for company $CompanyId"
  New-HuduNetwork -CompanyId $CompanyId -Address $Address -name $(if ($([string]::IsNullOrEmpty($name))){$Address} else {$name}) `
                  -Description $Description -NetworkType $($NetworkType ?? 0)
}

function Ensure-HuduVlanZone {
  param(
    [Parameter(Mandatory)][int]$CompanyId,
    [Parameter(Mandatory)][string]$ZoneName,
    [string]$Ranges  # e.g. "10-12,20,30-31"
  )

  $existing = (Get-HuduVlanZones -CompanyId $CompanyId) |
              Where-Object { $_.name -eq $ZoneName } | Select-Object -First 1
  if ($existing) {
    # Optionally backfill ranges if missing and we have some
    if ($Ranges -and -not $existing.vlan_id_ranges) {
      try { Set-HuduVlanZone -Id $existing.id -VlanIdRanges $Ranges | Out-Null } catch {}
    }
    return $existing
  }

  # API requires non-empty ranges; if none provided, use a broad default.
  $rangesToUse = if ($Ranges -and $Ranges.Trim()) { $Ranges.Trim() } else { '1-4094' }

  Write-Host "Creating VLAN Zone '$ZoneName' (ranges $rangesToUse) for company $CompanyId"
  New-HuduVLANZone -Name $ZoneName -CompanyId $CompanyId -VLANIdRanges $rangesToUse
}

function Ensure-HuduVlan {
  param(
    [Parameter(Mandatory)][int]$CompanyId,
    [Parameter(Mandatory)][int]$VlanId,
    [int]$ZoneId,
    [string]$Name
  )
  $Name = $Name ?? "VLAN $VlanId"
  $existing = (Get-HuduVlans -CompanyId $CompanyId) | Where-Object { $_.vlan_id -eq $VlanId } | Select-Object -First 1
  if ($existing) {
    # attach zone if missing (best-effort)
    if ($ZoneId -and -not $existing.vlan_zone_id) {
      try { Set-HuduVlan -Id $existing.id -VlanZoneId $ZoneId | Out-Null } catch {}
    }
    return $existing
  }
  Write-Host "Creating VLAN $VlanId ($Name) for company $CompanyId (zone=$ZoneId)"
  New-HuduVlan -CompanyId $CompanyId -Name $Name -VlanId $VlanId -VlanZoneId $ZoneId
}


function Invoke-OmniIPAMSyncByAssetLayout {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [Alias('IPFieldLabels','IPLabels')]
    [string[]]$IPAddressFieldLabels,
    [string[]]$HostnameFieldLabels = @('Hostname', 'Host Name', 'Device Name', 'DNS Name', 'FQDN', 'Name'),
    [string[]]$DefaultGatewayFieldLabels = @('Default Gateway', 'Gateway', 'Default Gateway IP', 'Gateway IP'),
    [AllowNull()][object[]]$AssetLayouts,
    [AllowNull()][object[]]$CachedAssets,
    [AllowNull()][int[]]$AssetLayoutId,
    [AllowNull()][AllowEmptyCollection()][int[]]$AllowedCompanyId,
    [switch]$RequireHostname,
    [switch]$RequireGateway,
    [switch]$DryRun,
    [switch]$IncludeEmptyLayouts,
    [ValidateRange(8,30)][int]$DefaultPrivatePrefix = 24,
    [ValidateRange(0,32)][int]$DefaultPublicPrefix = 32
  )
  $cacheProvided = $PSBoundParameters.ContainsKey('CachedAssets')
  $companyScopeProvided = $PSBoundParameters.ContainsKey('AllowedCompanyId')
  if ($companyScopeProvided -and @($AllowedCompanyId | Where-Object { $_ -gt 0 }).Count -eq 0) { return }
  $cachedAssetObjects = @()
  $layoutParams = @{
    IPAddressFieldLabels=$IPAddressFieldLabels; HostnameFieldLabels=$HostnameFieldLabels
    DefaultGatewayFieldLabels=$DefaultGatewayFieldLabels; AssetLayoutId=$AssetLayoutId
    RequireHostname=$RequireHostname; RequireGateway=$RequireGateway; EligibleOnly=$true
  }
  if ($cacheProvided) {
    $layoutParams.SkipLayoutHydration = $true
    $cachedAssetObjects = @($CachedAssets | ForEach-Object { Get-OmniIPAMAssetObject $_ } | Where-Object {
      $null -ne $_ -and (Get-HuduIPAMAssetId $_) -gt 0 -and
      (Get-OmniIPAMAssetLayoutId $_) -gt 0 -and (Get-HuduIPAMAssetCompanyId $_) -gt 0 -and
      (-not $companyScopeProvided -or (Get-HuduIPAMAssetCompanyId $_) -in $AllowedCompanyId)
    })
    # Explicitly supplied migration caches are authoritative, including empty or
    # partial caches. Never expand them to every asset/layout in the tenant.
    if ($cachedAssetObjects.Count -eq 0) { return }
    $layoutParams.AssetLayouts = @(
      foreach ($group in @($cachedAssetObjects | Group-Object { Get-OmniIPAMAssetLayoutId $_ })) {
        $id = [int]$group.Name
        $metadata = $AssetLayouts | ForEach-Object { if ($_.asset_layout) { $_.asset_layout } else { $_ } } |
          Where-Object { (Get-OmniIPAMLayoutId $_) -eq $id } | Select-Object -First 1
        $name = if ($metadata) { Get-OmniIPAMLayoutName $metadata } else { "Asset layout $id" }
        $labels = @($group.Group.fields | ForEach-Object { Get-OmniIPAMFieldLabel $_ } | Where-Object { $_ } | Select-Object -Unique)
        [pscustomobject]@{id=$id; name=$name; fields=@($labels | ForEach-Object { [pscustomobject]@{label=$_} })}
      }
    )
  } elseif ($PSBoundParameters.ContainsKey('AssetLayouts')) {
    $layoutParams.AssetLayouts = $AssetLayouts
  }
  $eligibleLayouts = @(Get-OmniIPAMEligibleAssetLayout @layoutParams)
  if ($DryRun) { return $eligibleLayouts }

  foreach ($layoutCandidate in $eligibleLayouts) {
    if (-not $layoutCandidate.LayoutId) {
      Write-Warning "Skipping eligible layout '$($layoutCandidate.LayoutName)' because it has no layout ID."
      continue
    }
    $assets = if ($cacheProvided) {
      @($cachedAssetObjects | Where-Object { (Get-OmniIPAMAssetLayoutId $_) -eq $layoutCandidate.LayoutId })
    } elseif ($companyScopeProvided) {
      @(foreach ($companyId in $AllowedCompanyId) { Get-HuduAssets -assetlayoutid $layoutCandidate.LayoutId -companyid $companyId })
    } else {
      @(Get-HuduAssets -assetlayoutid $layoutCandidate.LayoutId)
    }
    $assets = @($assets | Where-Object {
      (Get-HuduIPAMAssetId $_) -gt 0 -and (Get-HuduIPAMAssetCompanyId $_) -gt 0 -and
      (-not $companyScopeProvided -or (Get-HuduIPAMAssetCompanyId $_) -in $AllowedCompanyId)
    })
    $assetsWithIpValues = @(
      foreach ($asset in $assets) {
        foreach ($label in $layoutCandidate.IPAddressFieldLabels) {
          $value = Get-HuduAssetFieldValue -Asset $asset -Label $label
          if ($null -ne $value -and -not [string]::IsNullOrWhiteSpace("$value") -and
              @(Convert-HuduIPAMAddressFieldToInterfaces -AddressValue $value -DeferDefaultPrefix).Count -gt 0) {
            $asset
            break
          }
        }
      }
    )
    if ($assetsWithIpValues.Count -eq 0 -and -not $IncludeEmptyLayouts) { continue }
    $syncParams = @{
      Assets=$assetsWithIpValues; IPAddressFieldLabel=$layoutCandidate.IPAddressFieldLabels
      DefaultPrivatePrefix=$DefaultPrivatePrefix; DefaultPublicPrefix=$DefaultPublicPrefix
    }
    if ($layoutCandidate.HostnameFieldLabel) { $syncParams.HostnameFieldLabel=$layoutCandidate.HostnameFieldLabel }
    if ($layoutCandidate.DefaultGatewayFieldLabel) { $syncParams.DefaultGatewayFieldLabel=$layoutCandidate.DefaultGatewayFieldLabel }
    [pscustomobject]@{
      LayoutId=$layoutCandidate.LayoutId; LayoutName=$layoutCandidate.LayoutName
      IPAddressFieldLabel=$layoutCandidate.IPAddressFieldLabel; IPAddressFieldLabels=$layoutCandidate.IPAddressFieldLabels
      HostnameFieldLabel=$layoutCandidate.HostnameFieldLabel; DefaultGatewayFieldLabel=$layoutCandidate.DefaultGatewayFieldLabel
      AssetCount=$assets.Count; ProcessedAssetCount=$assetsWithIpValues.Count
      Result=if ($assetsWithIpValues.Count -gt 0) { @(Invoke-HuduAssetIPAMSync @syncParams) } else { @() }
    }
  }
}

$IPaddressFieldLabels = $ipAddressFieldLabels ?? @(
"IP",
"Secondary IP",  
"IP Address",
"IP Block",
"Management IP",
"Primary IP Address",
"Management Ip Address / Url",
"Ip Address(Es)",
"interface",
"interfaces",
"Configuration Interfaces",
"Management IP Address/URL",
"Management URL/IP",
"Primary IP",
"Static IP"
"WAN Usable Static IP Range"
)  
  
$HostnameFieldLabels = $hostnameFieldLabels ?? @(
  'Hostname', 'Host Name', 'Device Name', 'FQDN', "Host", "Host Dashboard URL", "Name of Host (Vendor Tag)"
)

$gatewayFieldLabels = $gatewayFieldLabels ?? @(
"Default Gateway",
"Gateway",
"WAN Default Gateway",
"Gateway Address",
"Gateway(S)"
)

