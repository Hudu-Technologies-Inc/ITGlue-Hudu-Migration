#requires -Version 7.2
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
. "$repoRoot/Public/NetworkInformation.ps1"
$checks = 0
function Assert-IPAM { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message }; $script:checks++ }
function Reset-IPAMFixture {
    $script:networks = [Collections.Generic.List[object]]::new()
    $script:addresses = [Collections.Generic.List[object]]::new()
    $script:vlans = [Collections.Generic.List[object]]::new()
    $script:zones = [Collections.Generic.List[object]]::new()
    $script:assetReads = [Collections.Generic.List[object]]::new()
    $script:layoutReads = 0
    $script:apiAssets = @(); $script:apiLayouts = @()
}
function Get-HuduNetworks { param($CompanyId) $script:networks | Where-Object company_id -eq $CompanyId }
function New-HuduNetwork {
    param($CompanyId,$Address,$Name,$Description,$NetworkType)
    $n = [pscustomobject]@{id=($script:networks.Count+1);company_id=$CompanyId;address=$Address;name=$Name;network_type=$NetworkType}
    $script:networks.Add($n); return $n
}
function Get-HuduIPAddresses { param($CompanyId) $script:addresses | Where-Object company_id -eq $CompanyId }
function New-HuduIPAddress {
    param($Address,$CompanyID,$NetworkId,$SkipDNSValidation,$Status,$FQDN,$Description,$Notes,$AssetID)
    $ip = [pscustomobject]@{id=($script:addresses.Count+1);company_id=$CompanyID;address=$Address;network_id=$NetworkId;asset_id=$AssetID;fqdn=$FQDN;status=$Status}
    $script:addresses.Add($ip); return $ip
}
function Get-HuduVlanZones { param($CompanyId) $script:zones | Where-Object company_id -eq $CompanyId }
function New-HuduVLANZone {
    param($Name,$CompanyId,$VLANIdRanges)
    $z = [pscustomobject]@{id=($script:zones.Count+1);company_id=$CompanyId;name=$Name;vlan_id_ranges=$VLANIdRanges}
    $script:zones.Add($z); return $z
}
function Get-HuduVlans { param($CompanyId) $script:vlans | Where-Object company_id -eq $CompanyId }
function New-HuduVlan {
    param($CompanyId,$Name,$VlanId,$VlanZoneId)
    $v = [pscustomobject]@{id=($script:vlans.Count+1);company_id=$CompanyId;name=$Name;vlan_id=$VlanId;vlan_zone_id=$VlanZoneId}
    $script:vlans.Add($v); return $v
}
function Set-HuduVlan { throw 'Unexpected VLAN update in fixture.' }
function Set-HuduVlanZone { throw 'Unexpected VLAN-zone update in fixture.' }
function Get-HuduAssetLayouts { param($layoutid) $script:layoutReads++; $script:apiLayouts | Where-Object { -not $layoutid -or $_.id -eq $layoutid } }
function Get-HuduAssets {
    param($assetlayoutid,$companyid)
    $script:assetReads.Add([pscustomobject]@{Layout=$assetlayoutid;Company=$companyid})
    # Intentionally return other companies too, to exercise the scope backstop.
    $script:apiAssets | Where-Object asset_layout_id -eq $assetlayoutid
}
function Invoke-RestMethod { throw 'Unexpected live API request in offline IPAM test.' }
function Invoke-WebRequest { throw 'Unexpected live download in offline IPAM test.' }
function New-IPAMAsset {
    param([int]$Id=1,[int]$Company=1,[int]$Layout=10,[object[]]$Fields=@(@{label='Primary IP';value='10.44.1.10/24'}))
    [pscustomobject]@{id=$Id;company_id=$Company;asset_layout_id=$Layout;name="Device $Id";fields=$Fields}
}
function New-IPAMMapping {
    param($Asset,[string]$Status='Created-By-Script',$Interfaces)
    [pscustomobject]@{HuduID=$Asset.id;HuduObject=$Asset;Imported=$Status;ITGObject=@{attributes=@{'configuration-interfaces'=$Interfaces}}}
}
function Invoke-CachedFixture {
    param([object[]]$Assets,[int[]]$Companies=@(1))
    @(Invoke-OmniIPAMSyncByAssetLayout -IPAddressFieldLabels $IPaddressFieldLabels -CachedAssets $Assets -AllowedCompanyId $Companies 6>$null)
}

Reset-IPAMFixture
$script:apiAssets = @(New-IPAMAsset -Company 99)
$script:apiLayouts = @([pscustomobject]@{id=10;name='Tenant devices';fields=@(@{label='Primary IP'})})
$null = Invoke-CachedFixture -Assets @()
Assert-IPAM ($assetReads.Count -eq 0 -and $layoutReads -eq 0 -and $addresses.Count -eq 0) 'An empty migration cache expanded to tenant assets/layouts.'
$null = Invoke-OmniIPAMSyncByAssetLayout -IPAddressFieldLabels $IPaddressFieldLabels -CachedAssets @() -DryRun
Assert-IPAM ($assetReads.Count -eq 0 -and $layoutReads -eq 0) 'An empty-cache dry run enumerated the tenant.'
$null = Invoke-CachedFixture -Assets @((New-IPAMAsset -Company 99))
Assert-IPAM ($addresses.Count -eq 0 -and $assetReads.Count -eq 0) 'An out-of-scope cached asset was processed.'
$null = Invoke-CachedFixture -Assets @((New-IPAMAsset -Fields @()))
Assert-IPAM ($addresses.Count -eq 0 -and $layoutReads -eq 0) 'A fieldless cached asset triggered a layout hydration request.'
$null = Invoke-OmniIPAMSyncByAssetLayout -IPAddressFieldLabels $IPaddressFieldLabels -AssetLayouts @() 6>$null
Assert-IPAM ($assetReads.Count -eq 0 -and $layoutReads -eq 0) 'An explicit empty layout list expanded to all layouts.'
$asset = New-IPAMAsset
$result = Invoke-CachedFixture -Assets @($asset)
Assert-IPAM ($assetReads.Count -eq 0 -and $layoutReads -eq 0 -and $addresses.Count -eq 1 -and $result[0].ProcessedAssetCount -eq 1) 'A partial cache was expanded, or did not process its own asset.'
Assert-IPAM ($addresses[0].company_id -eq 1 -and $addresses[0].asset_id -eq 1 -and $addresses[0].status -eq 'assigned') 'The cached IP lost its company/asset assignment.'
$beforeNetworks=$networks.Count; $beforeAddresses=$addresses.Count
$preview=@(Invoke-OmniIPAMSyncByAssetLayout -IPAddressFieldLabels $IPaddressFieldLabels -CachedAssets @($asset) -DryRun)
Assert-IPAM ($preview.Count -eq 1 -and $networks.Count -eq $beforeNetworks -and $addresses.Count -eq $beforeAddresses) 'DryRun mutated IPAM records or failed to report cached eligibility.'

Reset-IPAMFixture
$script:apiLayouts = @([pscustomobject]@{id=10;name='Tenant devices';fields=@(@{label='Primary IP'})})
$script:apiAssets = @(New-IPAMAsset -Id 1 -Company 1; New-IPAMAsset -Id 2 -Company 99)
$null = Invoke-OmniIPAMSyncByAssetLayout -IPAddressFieldLabels $IPaddressFieldLabels -AllowedCompanyId @(1) 6>$null
Assert-IPAM ($addresses.Count -eq 1 -and $addresses[0].company_id -eq 1 -and $assetReads[0].Company -eq 1) 'API fallback omitted the company filter or wrote out-of-scope data.'

Reset-IPAMFixture
$asset = New-IPAMAsset -Fields @(@{label='IP';value=''},@{label='Primary IP';value='10.44.1.10/24'},@{label='Secondary IP';value='10.44.2.20/24'})
$result = Invoke-CachedFixture -Assets @($asset)
Assert-IPAM ($addresses.Count -eq 2 -and '10.44.1.10' -in $addresses.address -and '10.44.2.20' -in $addresses.address) 'A blank preferred field or a secondary field hid another IP column.'
Assert-IPAM ($result[0].IPAddressFieldLabels.Count -eq 3 -and $result[0].ProcessedAssetCount -eq 1) 'Multi-column processing double-counted an asset or lost its labels.'
$null = Invoke-CachedFixture -Assets @($asset)
Assert-IPAM ($addresses.Count -eq 2 -and $networks.Count -eq 2) 'Rerunning multiple IP fields created duplicates.'

Reset-IPAMFixture
$asset = New-IPAMAsset -Fields @(@{label='Primary IP';value='[{"ip":"10.44.8.10","mask":"255.255.0.0","vlan_id":20}]'})
$null = Invoke-CachedFixture -Assets @($asset)
Assert-IPAM ($networks.Count -eq 1 -and $networks[0].address -eq '10.44.0.0/16') 'A dotted netmask was replaced with the default prefix.'
Assert-IPAM ($addresses.Count -eq 1 -and $addresses[0].address -eq '10.44.8.10') 'A dotted netmask was imported as an IP address.'
Assert-IPAM ($vlans.Count -eq 1 -and $vlans[0].vlan_id -eq 20 -and $zones.Count -eq 1) 'Structured interface VLAN information was lost.'
$null = Invoke-CachedFixture -Assets @($asset)
Assert-IPAM ($addresses.Count -eq 1 -and $networks.Count -eq 1 -and $vlans.Count -eq 1 -and $zones.Count -eq 1) 'Rerunning structured interfaces duplicated IPAM records.'
foreach ($value in @('{"ip":"10.44.8.10","netmask":"255.255.0.0"}', @(@{ip='10.44.8.10';mask='255.255.0.0'}))) {
    $interfaces = @(Convert-HuduIPAMAddressFieldToInterfaces -AddressValue $value)
    Assert-IPAM ($interfaces.Count -eq 1 -and $interfaces[0].Prefix -eq 16) 'JSON objects or native structured interfaces lost their netmask.'
}
$interfaces = @(Convert-HuduIPAMAddressFieldToInterfaces -AddressValue @(@{ip='10.44.8.10';mask='255.0.255.0'}) 3>$null)
Assert-IPAM ($interfaces.Count -eq 0) 'A noncontiguous mask silently became an inferred network.'
$interfaces = @(Convert-HuduIPAMAddressFieldToInterfaces -AddressValue '10.44.8.10/99' 3>$null)
Assert-IPAM ($interfaces.Count -eq 0) 'An invalid explicit prefix was silently accepted.'
$interfaces = @(Convert-HuduIPAMAddressFieldToInterfaces -AddressValue '[bad JSON]' 3>$null)
Assert-IPAM ($interfaces.Count -eq 0) 'Invalid JSON fell through to unstructured IP extraction.'

Reset-IPAMFixture
$configuration = New-IPAMMapping -Asset (New-IPAMAsset -Layout 20 -Fields @(@{label='Primary IP';value='10.55.8.10'},@{label='Hostname';value='server.local'})) -Interfaces @(@{ip='10.55.8.10';netmask='255.255.0.0';vlan_id=30},@{ip='10.55.9.10';cidr=16;vlan_id=30})
$inputs = @(Get-OmniIPAMMigrationAsset -MigrationItems @($configuration) -AllowedCompanyId @(1))
Assert-IPAM ($inputs.Count -eq 1 -and $configuration.HuduObject.fields.Count -eq 2 -and $inputs[0].fields.Count -eq 3) 'Source interfaces were lost or the original Hudu object was modified.'
$null = Invoke-CachedFixture -Assets $inputs
Assert-IPAM ($networks.Count -eq 1 -and $networks[0].address -eq '10.55.0.0/16' -and $addresses.Count -eq 2 -and $vlans[0].vlan_id -eq 30) 'Configuration interfaces did not retain masks, secondary addresses, and VLANs.'
Assert-IPAM (@($addresses | Where-Object { $_.asset_id -ne 1 -or $_.fqdn -ne 'server.local' }).Count -eq 0) 'Secondary interface addresses lost hostname/asset assignment.'

Reset-IPAMFixture
$items = @(
    New-IPAMMapping -Asset (New-IPAMAsset -Id 1)
    New-IPAMMapping -Asset (New-IPAMAsset -Id 2) -Status 'Updated By Script'
    New-IPAMMapping -Asset (New-IPAMAsset -Id 3) -Status 'Pre-Existing'
    New-IPAMMapping -Asset (New-IPAMAsset -Id 4) -Status 'First Pass'
    New-IPAMMapping -Asset (New-IPAMAsset -Id 5) -Status 'Update-Failed'
    New-IPAMMapping -Asset (New-IPAMAsset -Id 6 -Company 99)
    New-IPAMMapping -Asset (New-IPAMAsset -Id 1)
    [pscustomobject]@{Imported='Created-By-Script';HuduObject=@{id=9;name='An article';company_id=1}}
)
$inputs = @(Get-OmniIPAMMigrationAsset -MigrationItems $items -AllowedCompanyId @(1))
Assert-IPAM ($inputs.Count -eq 3 -and ($inputs.id -join ',') -eq '1,2,3') 'Migration inputs included failed/stub/unscoped/non-asset records or duplicate assets.'
$wrapped = [pscustomobject]@{Status='created';HuduObject=@{asset=(New-IPAMAsset -Id 11)}}
$wrappedInputs = @(Get-OmniIPAMMigrationAsset -MigrationItems @($wrapped) -AllowedCompanyId @(1))
Assert-IPAM ($wrappedInputs.Count -eq 1 -and $wrappedInputs[0].id -eq 11) 'A successful wrapped Hudu asset response was excluded.'
Assert-IPAM (@(Get-OmniIPAMMigrationAsset -MigrationItems $items -AllowedCompanyId @()).Count -eq 0) 'An empty company scope was ignored.'

# Exercise actual migration wiring for configurations, locations, contacts, and
# flexible assets, including a split configuration layout absent from FlexLayouts.
$MatchedConfigurations = @($configuration)
$MatchedLocations = @(New-IPAMMapping -Asset (New-IPAMAsset -Id 2 -Layout 30 -Fields @(@{label='IP Address';value='10.60.1.10/24'})))
$MatchedContacts = @(New-IPAMMapping -Asset (New-IPAMAsset -Id 3 -Layout 40 -Fields @(@{label='Management IP';value='10.70.1.10/24'})))
$MatchedAssets = @(New-IPAMMapping -Asset (New-IPAMAsset -Id 4 -Layout 50 -Fields @(@{label='IP';value='10.80.1.10/24'})))
$MatchedLayouts = @([pscustomobject]@{HuduObject=@{id=50;name='Flexible layout'}})
$CompaniesToMigrate = @([pscustomobject]@{HuduID=1})
$main = Get-Content -LiteralPath "$repoRoot/ITGlue-Hudu-Migration.ps1" -Raw
$block = [regex]::Match($main, '(?s)(?<block>\$ipamCompanyIds = .*?)\r?\n\}').Groups['block'].Value
Assert-IPAM (-not [string]::IsNullOrWhiteSpace($block)) 'Could not find actual migration IPAM input construction.'
& ([scriptblock]::Create($block)) 6>$null
Assert-IPAM ($addresses.Count -eq 5 -and $networks.Count -eq 4 -and $assetReads.Count -eq 0 -and $layoutReads -eq 0) 'Actual migration wiring omitted an asset category, split layout, or expanded beyond its cache.'

Reset-IPAMFixture
$null = Invoke-CachedFixture -Assets @((New-IPAMAsset -Company 1),(New-IPAMAsset -Id 2 -Company 2)) -Companies @(1,2)
Assert-IPAM ($addresses.Count -eq 2 -and $networks.Count -eq 2 -and @($addresses.company_id | Select-Object -Unique).Count -eq 2) 'Identical private IPs in different companies were merged.'
Reset-IPAMFixture
$null = Invoke-CachedFixture -Assets @((New-IPAMAsset -Fields @(@{label='Primary IP';value='10.44.8.10/23 vlan 20'})))
Assert-IPAM ($networks[0].address -eq '10.44.8.0/23' -and $vlans[0].vlan_id -eq 20) 'CIDR/VLAN text support regressed.'
Reset-IPAMFixture
$null = Invoke-CachedFixture -Assets @((New-IPAMAsset -Fields @(@{label='Primary IP';value='8.8.8.4/29'})))
Assert-IPAM ($networks[0].address -eq '8.8.8.4/32') 'Public-address /32 behavior changed.'

$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'Public/NetworkInformation.ps1'),[ref]$null,[ref]$null)
$duplicates = @($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$true) | Group-Object Name | Where-Object Count -gt 1)
Assert-IPAM ($duplicates.Count -eq 0) 'Inactive duplicate IPAM helper definitions remain.'
Write-Output "Passed $checks Omni-IPAM regression checks (offline)."
