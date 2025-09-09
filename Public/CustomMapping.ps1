function Build-LabelMap {
  param($Fields)  # supports hashtable, @{label;value} array, or single-pair objects
  $map = @{}

  if ($Fields -is [System.Collections.IDictionary]) {
    foreach ($k in $Fields.Keys) { $map[(Normalize-Key $k)] = $Fields[$k] }
    return $map
  }

  foreach ($f in @($Fields)) {
    if ($null -eq $f) { continue }
    if ($f.PSObject.Properties.Match('label').Count -and $f.PSObject.Properties.Match('value').Count) {
      $map[(Normalize-Key $f.label)] = $f.value
      continue
    }
    foreach ($p in $f.PSObject.Properties) {
      $map[(Normalize-Key $p.Name)] = $p.Value
    }
  }
  $map
}

function Get-SmooshedValue {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][pscustomobject]$SourceAsset,
    [Parameter(Mandatory)][string[]]$Labels,      # your SMOOSHLABELS (with spaces)
    [bool]$IncludeBlanks = $false,
    [bool]$IncludeHeaders = $true,                # your $includeLabelInSmooshedValues
    [bool]$PlainText = $false,                    # your $excludeHTMLinSMOOSH
    [string]$HtmlDelimiter = "<br><hr>",
    [string]$TextDelimiter = " "
  )

  $by = Build-LabelMap $SourceAsset.fields
  $pieces = New-Object System.Collections.Generic.List[string]

  foreach ($label in $Labels) {
    if ([string]::IsNullOrWhiteSpace($label)) { continue }
    $val = $by[(Normalize-Key $label)]

    if ($null -eq $val -or ($val -is [string] -and $val -eq '')) {
      if (-not $IncludeBlanks) { continue } else { $val = '' }
    }

    $piece = if ($IncludeHeaders) { "$label -`n$val" } else { "$val" }
    $pieces.Add($piece.Trim())
  }

  if ($pieces.Count -eq 0) { return '' }

  $out = if ($PlainText) { ($pieces -join $TextDelimiter) } else { ($pieces -join $HtmlDelimiter) }

  if ($PlainText) {
    $out = $out -replace "`r?`n", ' '
    $out = $out -replace '\s{2,}', ' '
    $out = Remove-HtmlTags -InputString $out
    $out = $out.Trim()
  }

  $out
}

function Get-RelinkableAssetTagLayoutFields {
    param (
        [int]$fromLayoutId
    )
    $linkableLayouts = @()
    $labelLinkMap = @{}
    $relinkables=$($(Get-HuduAssetLayouts -id $fromLayoutId).fields | where-object {$_.field_type -eq "AssetTag" -and $null -ne $_.linkable_id})
    write-host "$($relinkables.count) are likely relinkable."
    $linkableIDX=0
    foreach ($relinkable in $relinkables){
        $linkableIDX=$linkableIDX+1
        $linkablelayout = Get-HuduAssetLayouts -id $relinkable.linkable_id
        if (-not $linkablelayout -or $null -eq $linkablelayout) {continue}
        $labelLinkMap[$relinkable.label]=$linkablelayout
        write-host "linkable $linkableIDX of $($relinkables.count): label $($relinkable.label) is linkable to $($linkablelayout.name)"
        $linkableLayouts+=$linkablelayout
    }    
    return $labelLinkMap
}

function Get-SmooshedLinkableDescription {
    param (
        [array]$linkableObjects
    )
    $description=""
    if (-not $linkableObjects -or $linkableObjects.count -lt 1) {
        return ""
    }

    foreach ($linkable in $linkableObjects) {
        if ($linkable.linkedasset.url){
        $descriptor=@"
<br><hr>
<a href='$($linkable.linkedasset.url)'>Related $($linkable.LinkedLayout.name) - $($linkable.LinkedAsset.name)</a>
"@
} else {
        $descriptor=@"
Related $($linkable.LinkedLayout.name) - $($linkable.LinkedAsset.name)
"@    
    }
        $description="$description<br><hr>$descriptor"
    }
    return $description
}
function Set-HuduInstance {
    $HuduBaseURL = $HuduBaseURL ?? 
        $((Read-Host -Prompt 'Set the base domain of your Hudu instance (e.g https://myinstance.huducloud.com)') -replace '[\\/]+$', '') -replace '^(?!https://)', 'https://'
    $HuduAPIKey = $HuduAPIKey ?? "$(read-host "Please Enter Hudu API Key")"
    while ($HuduAPIKey.Length -ne 24) {
        $HuduAPIKey = (Read-Host -Prompt "Get a Hudu API Key from $($settings.HuduBaseDomain)/admin/api_keys").Trim()
        if ($HuduAPIKey.Length -ne 24) {
            Write-Host "This doesn't seem to be a valid Hudu API key. It is $($HuduAPIKey.Length) characters long, but should be 24." -ForegroundColor Red
        }
    }
    New-HuduAPIKey $HuduAPIKey
    Clear-Host
    New-HuduBaseURL $HuduBaseURL
}
function Normalize-Key([string]$k) {
  if (-not $k) { return $null }
  $k = $k.Trim().ToLowerInvariant()
  $k = ($k -replace '[\s\-]+','_') -replace '[^a-z0-9_]', ''
  ($k -replace '_{2,}','_').Trim('_')
}
function Get-RelinkableRelationsForAsset {
    param (
        [PSCustomObject]$sourceAsset,
        [hashtable]$labelLinkMap
    )
    $linkableObjects = @()
    foreach ($linkableField in $sourceAsset.fields | Where-Object {
        $_.label -and $_.label -in $labelLinkMap.Keys
    }) {
        $layoutForLinking = $labelLinkMap[$linkableField.label]

        try {
            $linkedItems = $null
            if ($linkableField.value -is [string] -and $linkableField.value.Trim().StartsWith("[")) {
                $linkedItems = $linkableField.value | ConvertFrom-Json
            }

            foreach ($linkedItem in $linkedItems) {
                $linkedAsset = Get-HuduAssets -Id $linkedItem.id
                if ($false -eq $includeRelationsForArchived -and $true -eq $linkedAsset.archived){
                    write-host "archived link, continuing"
                    continue
                }

                $linkableObjects+=[PSCustomObject]@{
                    SourceAssetId   = $sourceAsset.id
                    SourceField     = $linkableField.label
                    LinkedAsset     = $linkedAsset
                    LinkedLayout    = $layoutForLinking
                }
            }
        }
        catch {
            Write-Warning "Could not parse linked values for field [$($linkableField.label)] in asset [$($sourceAsset.id)]"
        }
    }
    return $linkableObjects
}
$PerJobSettings = @'
# if fields are blank, exclude during smoosh procress?
$includeblanksduringsmoosh = $false

# relate archived objects to new asset / object
$includeRelationsForArchived = $true

# set below to true if smooshing to plaintext field, otherwise leave for richtext field
# (strip html when going to text field)
$excludeHTMLinSMOOSH = $false

# include description of related objects in smoosh
# related objects will have a 1-line description based on related object type and name
$describeRelatedInSmoosh = $true

# include label - above value in smooshed? IE - 
# label -
# value
$includeLabelInSmooshedValues = $true
'@

function Get-FieldValueByLabel {
    param($Fields, [string]$Label, $Aliases = $null)
    if (-not $Label) { return $null }

    # Build candidate keys (space/underscore & case-insensitive)
    $wanted = $Label.Trim()
    $candidates = @(
        $wanted,
        ($wanted -replace '\s+', '_'),
        $wanted.ToLowerInvariant(),
        ($wanted -replace '\s+', '_').ToLowerInvariant()
    )

    if ($Aliases -and $Aliases.ContainsKey($wanted)) {
        $alias = $Aliases[$wanted]
        $candidates = @($alias, $alias.ToLowerInvariant()) + $candidates
    }

    if ($Fields -is [System.Collections.IDictionary]) {
        foreach ($k in $candidates) {
            if ($Fields.ContainsKey($k)) { return $Fields[$k] }
        }
        return $null
    }

    # Fallback: array of @{label=..; value=..} or single-pair objects
    foreach ($f in @($Fields)) {
        if ($f.PSObject.Properties.Match('label').Count -and
            $f.PSObject.Properties.Match('value').Count) {
            if ($f.label -ieq $wanted) { return $f.value }
        }
        foreach ($p in $f.PSObject.Properties) {
            if ($p.Name -ieq $wanted -or $p.Name -ieq ($wanted -replace '\s+','_')) {
                return $p.Value
            }
        }
    }
    $null
}


function Normalize-Region {
    param([string]$State)
    if (-not $State) { return $null }
    $s = $State.Trim()

    # Already 2 letters?
    if ($s -match '^[A-Za-z]{2}$') { return $s.ToUpper() }

    $us = @{
        'alabama'='AL'; 'alaska'='AK'; 'arizona'='AZ'; 'arkansas'='AR'; 'california'='CA'
        'colorado'='CO'; 'connecticut'='CT'; 'delaware'='DE'; 'florida'='FL'; 'georgia'='GA'
        'hawaii'='HI'; 'idaho'='ID'; 'illinois'='IL'; 'indiana'='IN'; 'iowa'='IA'
        'kansas'='KS'; 'kentucky'='KY'; 'louisiana'='LA'; 'maine'='ME'; 'maryland'='MD'
        'massachusetts'='MA'; 'michigan'='MI'; 'minnesota'='MN'; 'mississippi'='MS'; 'missouri'='MO'
        'montana'='MT'; 'nebraska'='NE'; 'nevada'='NV'; 'new hampshire'='NH'; 'new jersey'='NJ'
        'new mexico'='NM'; 'new york'='NY'; 'north carolina'='NC'; 'north dakota'='ND'
        'ohio'='OH'; 'oklahoma'='OK'; 'oregon'='OR'; 'pennsylvania'='PA'; 'rhode island'='RI'
        'south carolina'='SC'; 'south dakota'='SD'; 'tennessee'='TN'; 'texas'='TX'; 'utah'='UT'
        'vermont'='VT'; 'virginia'='VA'; 'washington'='WA'; 'west virginia'='WV'; 'wisconsin'='WI'; 'wyoming'='WY'
        'district of columbia'='DC'; 'washington dc'='DC'; 'dc'='DC'
    }
    $key = $s.ToLower()
    if ($us.ContainsKey($key)) { return $us[$key] }
    return $s  # fallback (leave as-is)
}

function Normalize-CountryName {
    param([string]$Country)
    if (-not $Country) { return $null }
    $c = $Country.Trim()
    $map = @{
        'us'='USA'; 'u.s.'='USA'; 'u.s.a'='USA'; 'usa'='USA'; 'united states'='USA'; 'united states of america'='USA'
        'uk'='United Kingdom'; 'u.k.'='United Kingdom'; 'gb'='United Kingdom'; 'gbr'='United Kingdom'
        'uae'='United Arab Emirates'
    }
    $key = $c.ToLower().Replace('.','')
    if ($map.ContainsKey($key)) { return $map[$key] }
    # Title-case fallback
    return -join ($c.ToLower().Split(' ') | ForEach-Object { if ($_){ $_.Substring(0,1).ToUpper()+$_.Substring(1) } })
}

function Normalize-Zip {
    param([string]$Zip)
    if (-not $Zip) { return $null }
    $z = $Zip -replace '\s+', ''  # collapse spaces (e.g., “802 02”)
    return $z.Trim()
}


function Remove-HtmlTags {
    param (
        [string]$InputString
    )
    $tags = @(
'hr','br', 'tr', 'td', 'th', 'table', 'div', 'span',
'p', 'ul', 'ol', 'li', 'h[1-6]', 'strong', 'em', 'b', 'i',
'colgroup', 'col', 'input', 'column', 'section', 'article',
'header', 'footer', 'aside', 'nav', 'main', 'figure', 'figcaption',
'blockquote', 'pre', 'address', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6',
'thead', 'tbody', 'tfoot','script','noscript','style','template','head','svg','math'
        )
    $cleaned = $InputString
    foreach ($tag in $tags) {
        # Regex matches both opening <tag ...> and closing </tag>
        $pattern = "<\/?$tag\b[^>]*>"
        $cleaned = [regex]::Replace($cleaned, $pattern, " ", "IgnoreCase")
    }
    return $cleaned.Trim()
}

function build-templatemap {
param ([array]$destfields,[string]$desiredMapFilePath="mapfile.ps1")
# Build entries like: @{from='';to='Some Label'}
$mapEntries = foreach ($f in $destfields) {
    if ($f.field_type -eq "AssetTag") {write-host "Skipping asset tag for $($f.label), those will be relinked."; continue}

    $toEsc = ([string]$f.label) -replace "'", "''"  # double single-quotes inside single-quoted PS strings
    $desttype = ([string]$($f.field_type ?? $f.type)) -replace "'", "''"  # double single-quotes inside single-quoted PS strings
    $req = ([string]$($f.required ?? $false)) -replace "'", "''"  # double single-quotes inside single-quoted PS strings
    if ($desttype -eq "ListSelect" -and $f.list_items) {
        "@{from='';to='$toEsc'; dest_type='$desttype'; required='$req'; striphtml='False';
                valid_listitems=" +'@({0})' -f (($f.list_items | ForEach-Object { "'{0}'" -f ($_ -replace "'", "''") }) -join ',')+'}'
    } 
    elseif ($desttype -eq "AddressData") {
        "@{to='$toEsc'; from='Meta'; dest_type='AddressData'; required='$req'; address=@{
                address_line_1=@{from=''}
                address_line_2=@{from=''}
                city=@{from=''}
                state=@{from=''}
                zip=@{from=''}
                country_name=@{from=''}
        }}"
    } else {
        "@{from='';to='$toEsc'; dest_type='$desttype'; required='$req'; striphtml='False'}"
    }
    }
# Wrap and write
$mappingText = @'
# source 
$CONSTANTS=@(
    ## @{literal="constval";to_label="constfield"}
)
$SMOOSHLABELS=@()
$mapping=@(
'@ + ($mapEntries -join ",`n") + @'
)
'@ + @"
$PerJobSettings
"@
Set-Content -Path $desiredMapFilePath -Value $mappingText -Encoding UTF8
}

function Convert-ITGImportsToHuduPreview {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [array]$ITGImports,

        # Each item should expose .ITGCompanyObject.id and .HuduCompanyObject.Id
        [Parameter(Mandatory)]
        [array]$CompaniesToMigrate,

        [string]$ImportAssetLayoutName = "ITG-Locations",
        [array]$AssetLayoutFields = @(),

        # Your map; can reference $unmatchedImport or accept -ITG/-Company/-UnmatchedImport
        [Parameter(Mandatory)]
        [scriptblock]$AssetFieldsMap,

        # When true (default), include rows even if company resolution fails
        [switch]$IncludeUnresolved = $true
    )

    begin {
        # Build org-id -> company map
        $CompanyByOrgId = @{}
        foreach ($c in $CompaniesToMigrate) {
            if ($c.ITGCompanyObject -and $c.ITGCompanyObject.id) {
                $CompanyByOrgId[$c.ITGCompanyObject.id] = $c
            }
        }
        Write-Verbose ("Company map count: {0}" -f $CompanyByOrgId.Count)
    }

    process {
        $out = foreach ($item in $ITGImports) {
            # Normalize to wrapper with .ITGObject/.Name/.Matched
            if ($item.PSObject.Properties.Name -contains 'ITGObject') {
                $unmatchedImport = $item
            } else {
                $nameGuess = $item.Name `
                    ?? $item.attributes?.name `
                    ?? $item.title `
                    ?? "ITG-$($item.id)"
                $unmatchedImport = [pscustomobject]@{
                    Name      = $nameGuess
                    ITGObject = $item
                    Matched   = $false
                }
            }

            if ($unmatchedImport.PSObject.Properties.Name -contains 'Matched' -and $unmatchedImport.Matched) { continue }

            # Resolve company
            $diag = [ordered]@{}
            $orgId = $unmatchedImport.ITGObject.HuduCompanyID
            $diag.orgId = $orgId

            # Build fields (supports both styles)
            $fields = $null
            try {
                $fields = & $AssetFieldsMap -ITG $unmatchedImport.ITGObject -Company $company -UnmatchedImport $unmatchedImport
                $diag.mapStyle = "parameterized"
            } catch {
                $fields = & $AssetFieldsMap
                $diag.mapStyle = "closure"
            }
            if (-not $fields) { $fields = @{} }

            # Emit preview
            [pscustomobject]@{
                Preview          = $true
                Name             = $($unmatchedImport.Name ?? $itgimport.attributes.name)
                CompanyId        = $($unmatchedImport.ITGObject.HuduCompanyID ?? $orgId)
                CompanyName      = $unmatchedImport.attributes."organization-name"
                AssetLayoutId    = $null
                AssetLayoutName  = $ImportAssetLayoutName
                fields           = $fields
                LayoutDefinition = $AssetLayoutFields
                ITGId            = $($unmatchedImport.id ?? $unmatchedImport.ITGObject.id)
                ITGObject        = $unmatchedImport.ITGObject
                _Diagnostics     = $diag
            }
        }

        ,$out
    }
}



# this is a proven method for transferring assets to new layout, but I'm thinking if we create faux/mock layout / fields, relations (assettag)
# the same format as hudu would provide, it should still work and allow custom mapping to existing layouts without having to migrate and then move; simply migrate to target

$FieldTypesThatDisallowLayoutUpdate = @(
    "ListSelect","AddressData"
)

function Set-AssetsToHuduLayout {
    param (
        [string]$desiredMapFileName,
        [array]$sourceassets,
        [PSCustomObject]$sourceassetlayout,
        [array]$allrelations,
        [PSCustomObject]$destLayout=$null,
        [bool]$PromptOnMatch=$false,
        [bool]$assetExists=$false,
        [array]$destassets=@()
    )


    $sourceDestDataType = @{}
    $addressMapsByDest    = @{} 
    $listMapsByDest    = @{} 

    $createdAssets = @()    
    $sourcedestlabels = @{}
    $sourcedestrequired = @{}        
    $sourcedestStripHTML = @{}        
    $CONSTANTS=@()
    $SMOOSHLABELS=@()
    $mapping=@()
    $inspectlayouts = $false    
    $desiredMapFilePath = $(join-path $ITGCUSTOMMAPPINGSDIR $desiredMapFileName)

    write-host "$(if ($allassets -and $null -ne $allassets) {'using existing asset cache'} else {'refreshing asset cache'})"
    $destlayout = $destLayout ?? $(Select-ObjectFromList -objects $(get-huduassetlayouts) -message "Which dest / target asset layout (migrating assets from $($sourceassetlayout.name)?" -allowNull $false -inspectObjects $true)
    $allassets = $allassets ?? $(get-huduassets -AssetLayoutId $destlayout.id)


    foreach ($layout in @($destlayout)){
        write-host "getting relinkable fields from layout $($layout.name)..."
        $layout | Add-Member -NotePropertyName linkables -NotePropertyValue $(Get-RelinkableAssetTagLayoutFields -fromLayoutId $layout.id) -Force
    }
    if ($(test-path "$desiredMapFilePath")) {
        write-host "backed up $desiredMapFilePath to $desiredMapFilePath.old"; Move-Item $desiredMapFilePath "$desiredMapFilePath.old" -Force
    }

    # get fields mapped and ready
    $srcfields=@()
    foreach ($field in $sourceassetlayout.fields | Where-Object {$_.field_type -ne "AssetTag"}) {
        $srcfields+=@{label = $field.label; type = $field.field_type; required = $($field.required ?? $false)}
    }
    $dstfields=@()
    foreach ($field in $destlayout.fields ) { #| Where-Object {$_.field_type -ne "ListSelect"}
        if ($field.field_type -eq "ListSelect" -and $field.list_id) {
            $list_items = $(get-hudulists -id 6).list_items.name
            $dstfields+=@{label = $field.label; field_type = $field.field_type; required = $($field.required ?? $false); list_items = @($list_items)}
        } else {
            $dstfields+=@{label = $field.label; field_type = $field.field_type; required = $($field.required ?? $false)}
        }
    }
    foreach ($fields in @(@{name="source"; value=$srcfields}, @{name="dest"; value=$dstfields})) {
        $fields.value | convertto-json -depth 66 | out-file $(join-path $ITGCUSTOMMAPPINGSDIR "$($fields.name)-fields.json")
    }
    build-templatemap -destfields $dstfields -desiredMapFilePath $desiredMapFilePath

    read-host "press enter if you filled in your mapfile, $desiredMapFilePath"

    while (-not $mapping -or $mapping.count -lt 1){
        $mapping=@()
        try {
            . $desiredMapFilePath
            if (-not $mapping -or $mapping.count -lt 1){
                Read-Host "Please adjust your mapping file, $($desiredMapFilePath), as it does not seem to have a usable or properly-formatted mapping definition. Please adjust and press ENTER when adjusted."
            }
        } catch {
            $mapping=@()
            Read-Host "Please adjust your mapping file, $($desiredMapFilePath), as it an error was encountered during import ($_). Please adjust and press ENTER when adjusted."
        }
        if (-not $(test-path "$desiredMapFilePath")) {
            Write-Host "Mapfile appears to have been deleted from $desiredMapFilePath? creating again, you will still need to fill it out, however."
            build-templatemap -destfields $dstfields -desiredMapFilePath $desiredMapFilePath
            . $desiredMapFilePath
        }            
    }

    if ($($destlayout.fields | Where-Object {$FieldTypesThatDisallowLayoutUpdate -contains $_.field_type}).count -lt 1){
        # ListSelect fields in target layout prevent us from updating layouts.
        # until bug gets solved, we can't update layouts with 'newer' field types.
        # if there are no 'special' dest fields, however, this does work fine
        # until this bug is fixed in hudu api, it is best to manually make sure that corresponding asset tag / itglue id fields exist
        # if target layout doesnt have either of the currently-known disallowed types, however, it's business as usual


        if ($true -eq $settings.IncludeITGlueID -and [bool]$($(($sourceassetlayout.fields | Where-Object {$_.label -eq "ITGlue ID"})).count -gt 0)) {
            Write-Host "Itglue ID set to be included, injecting into dest layout"
            $currentFields = $destlayout.fields | Where-Object {$_.field_type -ne "ListSelect"} ?? @()
            $sourceITGfield = $($sourceassetlayout.fields | Where-Object {$_.label -eq "ITGlue ID"} | Select-Object -First 1)
            if ($sourceITGfield) {$currentFields += $sourceITGfield}
            $null = Set-HuduAssetLayout -id $destlayout.id -fields $currentFields -name $destlayout.name
            Write-Host "added ITGLueID field, refreshing layouts"
            $destlayout = Get-HuduAssetLayouts -id $destlayout.id
            $mapping+=@{from="ITGlue ID"; to="ITGlue ID"; dest_type='Text'; required='False'}
        }

        foreach ($field in $sourceassetlayout.fields | Where-Object {$_.field_type -eq "AssetTag" -and -not @($null, 0) -contains $_.linkable_id}) {
            $matchingDestField = $($destlayout.fields | Where-Object {$_.field_type -eq "AssetTag" -and $field.linkable_id -eq $_.linkable_id} | Select-Object -First 1) ?? $null
            if ($null -ne $matchingDestField) {
                Write-Host "source tag field $($field.label) Destination layout has corresponding tag field: $($matchingDestField.label); adding to mapping."
                $mapping+=@{from="$($field.label)"; to="$($matchingDestField.label)"; dest_type='AssetTag'}
            } else {
                $linkableLayout=$(get-huduassetlayouts -id $field.linkable_id) ?? $null
                if ($null -ne $linkableLayout -and 'yes' -eq $(Select-ObjectFromList -message "Would you like to add corresponding assettag field $($field.label) from source layout $($sourceassetlayout.name) to your destination layout, $($destlayout.name)?")){
                    $currentFields = $destlayout.fields ?? @()
                    $MaxPosition = $($currentFields.position | Sort-Object -Descending | Select-Object -First) ?? 1
                    $currentFields += @{
                        position     = $($MaxPosition+1)
                        label        = $field.label
                        field_type   = 'AssetTag'
                        show_in_list = $($field.show_in_list ?? 'false').ToString().ToLower()
                        linkable_id  = $field.linkable_id
                    }
                    $null = Set-HuduAssetLayout -id $destlayout.id -fields $currentFields -name $destlayout.name
                    Write-Host "added assettag field, refreshing layouts"
                    $destlayout = Get-HuduAssetLayouts -id $destlayout.id
                    $mapping+=@{from="$($field.label)"; to="$($field.label)"; dest_type='AssetTag'}
                }
            }
        }
    }
    foreach ($entry in $mapping) {
        if ($entry.dest_type -eq 'AddressData') {
            $addressMapsByDest[$entry.to] = $entry.address
            $sourcedestrequired[$entry.from] = $false
            $sourceDestDataType[$entry.from] = 'AddressData'
            $sourcedestlabels[$entry.from] = 'Meta'
            continue
        }
        $sourcedestStripHTML[$entry.from] = [bool]$(@('t','true','yes','y') -contains "$($entry.striphtml ?? 'false')".ToLower())
        write-host "mapping $($entry.from) to $($entry.to) $(if ($true -eq $sourcedestStripHTML[$entry.from]) {"destination field of $($entry.to) will have HTML stripped."} else {'as-is'})"
        $sourcedestlabels[$entry.from] = $entry.to
        $sourcedestrequired[$entry.from] = $($entry.to ?? $false)
        $sourceDestDataType[$entry.from] = $($entry.dest_type ?? 'Text')
        if ($entry.dest_type -eq 'ListSelect' -and $entry.valid_listitems -and $entry.valid_listitems.count -gt 0){
            $listMapsByDest[$entry.to] = $entry.valid_listitems
        }        
    }
    Write-Host "$($($addressMapsByDest.GetEnumerator()).count) Location Types in Target press enter to proceed"

    # $sourceassets = $($allAssets | Where-Object {$_.asset_layout_id -eq $sourceassetlayout.id}) 
    # $destassets = $($allAssets | Where-Object {$_.asset_layout_id -eq $destlayout.id}) 
    $destassets = $allassets
    if ($sourceassets.count -lt 1) { write-host "NO SOURCE ASSETS!"; return}
    $mappingtosmooshed = [bool]$($SMOOSHLABELS.count -gt 0)
    if ($mappingtosmooshed) {
        $smooshmappingto = $($mapping | where-object {$_.from="SMOOSH"}).to
        write-host "Smooshing $SMOOSHLABELS => $mappingtosmooshed; $smooshmappingto"
    }
    if ($CONSTANTS) {
        foreach ($c in $CONSTANTS){
            write-host "Dest Labels containing $($c.to_label) will be given static value from literal $($c.literal) as literal value!"
        }
    } else {write-host "No constants mapped"}
    
    $totalcounts = @{
        fromablescreated=0
        toablescreated=0
        assetsarchived=0
        assetsmoved=0
        assetsskipped=0
        assetsmatched=0
        errored=0
        sourceassetcount=$sourceassets.count
    }
    $labelsNorm     = @{}
    $requiredNorm   = @{}
    $stripHTMLNorm  = @{}
    $destTypeNorm   = @{}
    $listMapsByDestNorm = @{}

    # make a normalized map of each source/dest key or lookup value in case of nonstandard chars
    if (-not $sourcedestlabels -eq @{}) {foreach ($k in $sourcedestlabels.Keys)    { $labelsNorm[   (Normalize-Key $k) ] = $sourcedestlabels[$k] }}
    if (-not $sourcedestrequired -eq @{}) {foreach ($k in $sourcedestrequired.Keys)  { $requiredNorm[ (Normalize-Key $k) ] = $sourcedestrequired[$k] }}
    if (-not $sourcedestStripHTML -eq @{}) {foreach ($k in $sourcedestStripHTML.Keys) { $stripHTMLNorm[(Normalize-Key $k) ] = $sourcedestStripHTML[$k] }}
    if (-not $sourceDestDataType -eq @{}) {foreach ($k in $sourceDestDataType.Keys)  { $destTypeNorm[ (Normalize-Key $k) ] = $sourceDestDataType[$k] }}
    if (-not $listMapsByDest -eq @{}) {foreach ($k in $listMapsByDest.Keys)      { $listMapsByDestNorm[ (Normalize-Key $k) ] = $listMapsByDest[$k] }}



    Write-Host "Smooshing $(if ($excludeHTMLinSMOOSH -and $true -eq $excludeHTMLinSMOOSH) {'using plaintext value-joining'} else {'using traditional HTML value joining'})"
    read-host "$($sourceassets.count) source assets and $($destassets.count) dest assets. press enter to proceed"
    $sourceassetsIDX=0
    foreach ($originalasset in $sourceassets) {
        $addMatch = $false
        $sourceassetsIDX=$sourceassetsIDX+1
        $linkableToAssetInfo = $null
        write-host "matching existing assets to asset $sourceassetsIDX of $($sourceassets.count) in destination layout assets ($($destassets.count) total) to determine if overlap"
        $match = $destassets | where-object {$_.company_id -eq $originalasset.ITGObject.HuduCompanyID -and $_.name -eq "$($originalasset.name)"} | Select-Object -First 1
        if ($match -and $null -ne $match) {
            $totalcounts.assetsmatched=$totalcounts.assetsmatched+1
            # if we are prompting user on match, allow them to select which version is kept.
            if ($true -eq $PromptOnMatch){
                write-host "match found in dest layout. (#$($totalcounts.assetsmatched)) thus far"
                write-host "original: $($($originalasset | ConvertTo-Json -depth 6).ToString())" -ForegroundColor Yellow
                write-host "match: $($($match | ConvertTo-Json -depth 6).ToString())" -ForegroundColor Blue
                $archiveChoice=$(select-objectfromlist -message "which action to take for match?" -objects @("archive match","move anyway, archive original","skip"))
                if ($archiveChoice -eq "archive match") {
                    Set-HuduAssetArchive -CompanyId $originalasset.ITGObject.HuduCompanyID -Id $originalasset.id -Archive $true
                    $totalcounts.assetsarchived=$totalcounts.assetsarchived+1
                } elseif ($archiveChoice -eq "skip") {
                    $totalcounts.assetsskipped=$totalcounts.assetsskipped+1
                    $addMatch = $true
                } else {continue; write-host "skipped"}
            } else {
                $addMatch = $true
            }
            # if we match on a dest layout item having same company and same / similar name, update the record to that of the match for later
            if ($true -eq $addMatch) {
                $totalcounts.assetsmatched=$totalcounts.assetsmatched+1
                $originalasset  | Add-Member -MemberType 'NoteProperty' -Name 'HuduObject' -Value $match -Force
                $originalasset  | Add-Member -MemberType 'NoteProperty' -Name 'AssetLayoutName' -Value $destlayout.name  -Force
                $originalasset  | Add-Member -MemberType 'NoteProperty' -Name 'AssetLayout' -Value $destlayout  -Force
                $originalasset  | Add-Member -MemberType 'NoteProperty' -Name 'AssetLayoutId' -Value $destlayout.Id  -Force
                $originalasset  | Add-Member -MemberType 'NoteProperty' -Name 'Preview' -Value $false  -Force
                $originalasset  | Add-Member -MemberType 'NoteProperty' -Name "matched" -Value $true -Force
                $originalasset  | Add-Member -MemberType 'NoteProperty' -Name "HuduID" -Value $match.id -Force
                $originalasset  | Add-Member -MemberType 'NoteProperty' -Name "Imported" -Value "Pre-Existing" -Force                
                $createdAssets+=$originalasset
                continue
            }
        }

        $transformedFields = @()
        if ($CONSTANTS -and $CONSTANTS.count -gt 0) {
            foreach ($c in $CONSTANTS){
                $transformedFields += @{$c.to_label = $c.literal}
            }
        }
        # foreach ($field in $originalasset.fields) {
        foreach ($kv in ($originalasset.fields | ForEach-Object GetEnumerator)) {
            $key        = $kv.Key
            $keyNorm    = Normalize-Key $key

            $field = @{
                label      = $key
                value      = $kv.Value
                required   = ([string]$requiredNorm[$keyNorm]).ToLower() -eq 'true'
                stripHTML  = [bool]$stripHTMLNorm[$keyNorm]
                dest_type  = $destTypeNorm[$keyNorm] ?? 'Text'
                list_items = $null
            }

            if ($field.dest_type -eq 'AddressData') { continue }

            $transformedLabel = $labelsNorm[$keyNorm]
            if (-not $transformedLabel) { continue }
            if ($dest_type -eq 'ListSelect' -and $null -ne $listMapsByDestNorm["$transformedLabel"]) {
                $validListItems = $listMapsByDestNorm["$transformedLabel"]
                # if listselect item not in valid range, default to first listitem if required otherwise skip as it's invalid
                if (-not $validListItems -contains $field.value){
                    if ($field.required){
                        $field.value = $validListItems | Select-Object -first 1
                    } else {write-host "skipping invalid value $($field.value)- not in range of list items $($($validListItems | ConvertTo-Json).ToString())"; continue}
                }
            }

            if ($null -eq $field.value -or $field.value -eq '') {
                Write-Host "no translate for $($field.label)"
                if ($field.required) {
                    Write-Host "no value for REQUIRED $($field.label) => $transformedLabel"
                    $field.value = (Read-Host "target field $($field.labexl) => $transformedLabel is required but null, enter value") ?? "None"
                } else {
                    Write-Host "no value for optional $($field.label) => $transformedLabel"
                    continue
                }
            }

            if ($field.stripHTML) {
                $field.value = "$(Remove-HtmlTags -InputString "$($field.value)")"
            }
            if ($field.dest_type -eq "Email" -or
                ($field.dest_type -eq "Text" -and $transformedLabel -like "*Email*")) {
                $field.value = "$(Get-CleansedEmailAddresses -InputString "$($field.value)")".Trim()
            }

            $transformedFields += @{ $transformedLabel = $field.value }
            Write-Host "$($field.label) => $transformedLabel for value $($field.value)"
        }
        foreach ($kv in $addressMapsByDest.GetEnumerator()) {
            $destLabel = $kv.Key
            $addrMap   = $kv.Value

            $addr1 = Get-FieldValueByLabel $originalasset.fields $addrMap.address_line_1.from
            $addr2 = Get-FieldValueByLabel $originalasset.fields $addrMap.address_line_2.from
            $city  = Get-FieldValueByLabel $originalasset.fields $addrMap.city.from
            $state = Get-FieldValueByLabel $originalasset.fields $addrMap.state.from
            $zip   = Get-FieldValueByLabel $originalasset.fields $addrMap.zip.from
            $cntry = Get-FieldValueByLabel $originalasset.fields $addrMap.country_name.from

            $state = Normalize-Region $state
            $zip   = Normalize-Zip    $zip
            $cntry = Normalize-CountryName $cntry

            if ($addr1 -or $addr2 -or $city -or $state -or $zip -or $cntry) {
                $NewAddress = [ordered]@{
                    address_line_1 = $addr1
                    city           = $city
                    state          = $state
                    zip            = $zip
                    country_name   = $cntry
                }
                if ($addr2) { $NewAddress['address_line_2'] = $addr2 }
                $transformedFields += @{ $destLabel = $NewAddress }
            }
        }

        if ($sourceassetlayout.linkables -and $sourceassetlayout.linkables.keys.count -gt 0){
            Write-host "Getting linkable items for asset $($originalasset.name) from $($sourceassetlayout.linkables.keys.count) potentially linkable"
            $linkableToAssetInfo = Get-RelinkableRelationsForAsset -sourceAsset $originalasset -labelLinkMap $sourceassetlayout.linkables
        }
        # map custom smooshed fields ( notes, richtext, whatever we smooshed to in map)
        if ($mappingtosmooshed) {
            $valueToAdd = Get-SmooshedValue `
                -SourceAsset $originalasset `
                -Labels $SMOOSHLABELS `
                -IncludeBlanks:$includeblanksduringsmoosh `
                -IncludeHeaders:$includeLabelInSmooshedValues `
                -PlainText:$excludeHTMLinSMOOSH

            if ($describeRelatedInSmoosh) {
                $describerelated = Get-SmooshedLinkableDescription -linkableObjects $linkableToAssetInfo
                $valueToAdd = if ($excludeHTMLinSMOOSH) { "$describerelated $valueToAdd" } else { "$describerelated<br>$valueToAdd" }
            }
            if ($true -eq $excludeHTMLinSMOOSH){$valueToAdd = Remove-HtmlTags -InputString $valueToAdd }
            if ($valueToAdd -ne "<br>" -and -not [string]::IsNullOrWhiteSpace($valueToAdd)){
                $transformedFields+=@{"$($sourcedestlabels["SMOOSH"])" = $valueToAdd}
            }
        }

        $newAssetRequest = @{
            Name            = $originalasset.name
            CompanyId       = $originalasset.ITGObject.HuduCompanyID ?? $originalasset.HuduObject.company_id ?? $originalasset.company_id
            AssetLayoutId   = $destlayout.id
        }
        if ($transformedFields -and $transformedFields.count -gt 0){
            $newAssetRequest["Fields"]=$transformedFields
            write-host $($($transformedFields | convertto-json -depth 5).ToString())
        }

        if ($originalAsset.primary_serial){
                    $newAssetRequest["PrimarySerial"]=$originalAsset.primary_serial
        }
        if ($originalAsset.primary_mail){
                    $newAssetRequest["PrimaryMail"]=$originalAsset.primary_mail
        }
        if ($originalAsset.primary_model){
                    $newAssetRequest["PrimaryModel"]=$originalAsset.primary_model
        }
        if ($originalAsset.primary_manufacturer){
                    $newAssetRequest["PrimaryManufacturer"]=$originalAsset.primary_manufacturer
        }

        try {
            write-host "$($($newAssetRequest | ConvertTo-Json -depth 66).ToString())"
            if ($false -eq $assetExists) {
                $newAsset = $(new-huduasset @newAssetRequest).asset
                $originalasset  | Add-Member -MemberType 'NoteProperty' -Name 'CreatedNew' -Value $true  -Force
            } else {
                $newAssetRequest["id"] = $originalAsset.HuduID ?? $originalasset.HuduObject.id
                $originalasset  | Add-Member -MemberType 'NoteProperty' -Name 'UpdatedAs' -Value $true  -Force
                $newAsset = $(set-huduasset @newAssetRequest).asset
            }
            write-host "Created asset $($newAsset.id)"
            
            if ($originalasset.archived -eq $true) {
                Set-HuduAssetArchive -CompanyId $newAsset.company_id -Id $newAsset.id -Archived $true
                $totalcounts.assetsarchived=$totalcounts.assetsarchived+1
            }

        } catch {
            Write-ErrorObjectsToFile -ErrorObject @{Err=$_; request=$newAssetRequest} -Name $newAssetRequest.name
        }
        if (-not $newAsset -or $null -eq $newAsset) {
            Write-ErrorObjectsToFile -ErrorObject $newAssetRequest -Name "NC-$($newAssetRequest.name)"
            $totalcounts.errored=$totalcounts.errored+1
            continue
        } else {
            $totalcounts.assetsmoved=$totalcounts.assetsmoved+1
            $originalasset  | Add-Member -MemberType 'NoteProperty' -Name 'HuduObject' -Value $newAsset -Force
            $originalasset  | Add-Member -MemberType 'NoteProperty' -Name 'AssetLayoutName' -Value $destlayout.name  -Force
            $originalasset  | Add-Member -MemberType 'NoteProperty' -Name 'AssetLayout' -Value $destlayout  -Force
            $originalasset  | Add-Member -MemberType 'NoteProperty' -Name 'AssetLayoutId' -Value $destlayout.Id  -Force
            $originalasset  | Add-Member -MemberType 'NoteProperty' -Name 'Preview' -Value $false  -Force
            $originalasset  | Add-Member -MemberType 'NoteProperty' -Name "matched" -Value $true -Force
            $originalasset  | Add-Member -MemberType 'NoteProperty' -Name "HuduID" -Value $newAsset.id -Force
            $originalasset  | Add-Member -MemberType 'NoteProperty' -Name "Imported" -Value "Created-By-Script (custom-mapped)" -Force
            $createdAssets+=$originalasset
            write-host "created asset $($newasset.id)"
        }

        # add relations
        $sourceToables  = $($($allrelations | where-object {$_.toable_type -eq 'Asset' -and $originalasset.id -eq $_.toable_id }) ?? @())
        write-host "$($sourceToables.count) toable relations"
        $sourceFromables  = $($($allrelations | where-object {$_.fromable_type -eq 'Asset' -and $originalasset.id -eq $_.fromable_id }) ?? @())
        write-host "$($sourceFromables.count) fromable relations"
        try {
            $relationsTo = $sourceToables | Where-Object { $_.toable_id -eq $sourceAsset.id }
            foreach ($rel in $relationsTo) {
                $newToable+=New-HuduRelation -FromableType $rel.fromable_type -FromableId $rel.fromable_id `
                                -ToableType "Asset" -ToableId $newAsset.id
                write-host "created toable rel $($newToable.id)"
                $totalcounts.toablescreated= if ($newToable) {$totalcounts.toablescreated+1} else {$totalcounts.toablescreated}
            }
            $relationsFrom = $sourceFromables | Where-Object { $_.fromable_id -eq $sourceAsset.id }
            foreach ($rel in $relationsFrom) {
                $newFromable=New-HuduRelation -FromableType "Asset" -FromableId $newAsset.id `
                                -ToableType $rel.toable_type -ToableId $rel.toable_id
                write-host "created fromable rel $($newFromable.id)"
                $totalcounts.fromablescreated= if ($newFromable) {$totalcounts.fromablescreated+1} else {$totalcounts.fromablescreated}
            }
        } catch {
            $totalcounts.errored=$totalcounts.errored+1
            Write-ErrorObjectsToFile -ErrorObject @{Err= $_; From = $relationsFrom; To=$relationsTo} -Name "NCREL-$($newasset.name)"
        }

        if ($linkableToAssetInfo -and $linkableToAssetInfo.count -gt 0){
            write-host "Asset has external asset links, relinking $($linkableToAssetInfo.count) for $($originalasset.name)"
            foreach ($linkableToAsset in $linkableToAssetInfo) {
                $linkedAsset=$linkableToAsset.LinkedAsset
                if (-not $linkableToAsset.LinkedAsset) {continue}
                try {
                    $newToable=New-HuduRelation -FromableType 'Asset' -ToableType "Asset" -FromableId $LinkedAsset.id -ToableID $newAsset.id
                    $totalcounts.toablescreated= if ($newToable) {$totalcounts.toablescreated+1} else {$totalcounts.toablescreated}
                    write-host "created asset-toable rel $($newToable.id)"
                } catch {
                    $totalcounts.errored=$totalcounts.errored+1
                    Write-ErrorObjectsToFile -ErrorObject @{Err = $_; From = $relationsFrom; To=$relationsTo} -Name "NCREL-AL-$($newasset.name)"
                }
            }
        }
    }
    $mappingInfo = @{
        CONSTANTS                       =$CONSTANTS
        SMOOSHLABELS                    =$SMOOSHLABELS
        mapping                         =$mapping
        includeLabelInSmooshedValues    =$includeLabelInSmooshedValues
        describeRelatedInSmoosh         =$describeRelatedInSmoosh
        excludeHTMLinSMOOSH             =$excludeHTMLinSMOOSH
        includeRelationsForArchived     =$includeRelationsForArchived
        includeblanksduringsmoosh       =$includeblanksduringsmoosh
        sourceDestDataType              = $sourceDestDataType
        addressMapsByDest               = $addressMapsByDest
    }

    return @{
        createdAssets   =$createdAssets
        destlayout      =$destlayout
        counts          =$totalcounts
        mappingInfo     =$mappingInfo
    }
}