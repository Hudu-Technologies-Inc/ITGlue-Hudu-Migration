# Purpose: Move assets to new layout, mapping source and destination fields

<#
Use: invoke via dotsourcing
. .\transfer-assets.ps1

Select source Asset Layout
Select destination Asset Layout

files, named mapping.ps1 and source-fields.json will be generated
use labels in source fields to map to destination fields in mapping.ps1
It's best to match field_types to destination field_types when possivble
That said, list select, dropdown, checkbox, website, and other fields do translate nicely to text/richtext destinations

To combine source fields into a single destination field (concatenate them), you can designate which fields you would
like to 'Smoosh' into a pseudo-source field, labeled SMOOSH. SMOOSH field translates nicely into richtext or text fields.

Mapping.ps1 is generated with the target layout fields and you just need to fill in what source fields you want to place/combine into them
Here is an example filled mapping.ps1
# source 
$CONSTANTS=@(
    @{literal="Vonage";to_label="VOIP Service Provider"}
)
$SMOOSHLABELS=@(
"Manufacturer Name","Model ID","Hostname","Default Gateway","Asset Tag","Operating System Name",
"Installed By","Installed At",
"Purchased By","Purchased At","Contact Name","Operating System Notes",
"Notes","Configuration Status Name","Location Name","Contact Name"
)
$mapping=@(
@{from='Model Name';to='Model'; dest_type='Text'; required='True'},
@{from='Primary IP';to='IP Address'; dest_type='Website'; required='False'},
@{from='MAC Address';to='Mac Address'; dest_type='Text'; required='False'},
@{from='Serial Number';to='Serial Number / Service Tag'; dest_type='Text'; required='False'},
@{from='Warranty Expires At';to='Warranty Expiration'; dest_type='Date'; required='False'},
@{from='SMOOSH';to='Notes'; dest_type='RichText'; required='False'})# if fields are blank, exclude during smoosh procress?
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



There are a few variables in this mapping.ps1 file that you can set per-job. Here are their explanations:

### 
the $CONSTANTS variable provides an array of predefined psudo-source fields of your choosing.
All target assets will be pre-filled with the value, literal for field to_label for however many of these you want.
This is useful for filling required fields that dont have a source field which matches up. It's important to make sure 
values in the to_label correspond with a value in the target layout.

$CONSTANTS=@(
    ## @{literal="constval";to_label="constfield"}
)


###

$includeblanksduringsmoosh [default $false]: this excludes null/blank values if present in a source smoosh field. for instance, if you have:
Asset A: has serial number but no purchase date
Asset B: has purchase date but no serial number

and your smoosh definition is:
$SMOOSHLABELS=@("serial number","purchase date","Notes")
and you mapped SMOOSH psuedo-source field to "Notes", Notes for assest A in destination layout would be:
Serial Number:
9JD2NLAL4
Notes:
This is a good computer

Notes for asset B would be:
Purchase Date:
01/11/2023
Notes:
This is a pretty decent machine

###

$includeLabelInSmooshedValues [default: $true]: if you turn this off, you do not get smooshed labels, so asset A would be:
9JD2NLAL4
This is a good computer

If you are smooshing values together for a text field (not richtext), you will almost certainly want to set this to $false for that migration/job

###

$includeRelationsForArchived [default: $true]: if you leave this on, relations to archived assets are retained.  set this to $false to not carry over archived relationships.

###

$describeRelatedInSmoosh [default: $true]: if you leave this on, relations are described in addition to smooshed fields. 
This would mean asset A looks like:
Serial Number:
9JD2NLAL4
Notes:
This is a good computer
Related People:
John https://huduurl.huducloud.com/a/johnsslug
Related Location:
Johns House https://huduurl.huducloud.com/a/houseslug

###

excludeHTMLinSMOOSH [default: $false]:
If you are setting your SMOOSH field to a Text field (not richtext), you'll want to  strip HTML tags by setting
$excludeHTMLinSMOOSH = $true in your generated mapping.ps1 file. This also sets it as a one line value with values delimited by semicolon.
This would mean asset A looks like [in conjunction with not including labels]:
9JD2NLAL4; This is a good computer; John https://huduurl.huducloud.com/a/johnsslug; Johns House https://huduurl.huducloud.com/a/houseslug



#>

function Set-SmooshAssetFieldsToField {
    param (
        [PSCustomObject]$sourceAsset,
        [array]$smooshsource,
        [bool]$includeBlanks=$false
    )
    if ($excludeHTMLinSMOOSH -and $true -eq $excludeHTMLinSMOOSH) {
        $lineDelmit = " "
    } else {
        $lineDelmit = "<br><hr>"
    }
    foreach ($sourcefieldsmoosh in $smooshsource) {
        if ($null -eq $($($sourceasset.fields | where-object {$_.label -eq $sourcefieldsmoosh}).value)){
            if ($false -eq $includeBlanks) {continue}
        }
        
    if ($includeLabelInSmooshedValues){
        $header = "$sourcefieldsmoosh -"
    } else {$header = ""}
    
    $smooshin=@"
$header
$($($sourceasset.fields | where-object {$_.label -eq $sourcefieldsmoosh}).value)
"@
$smoosh=@"
$smoosh
$lineDelmit
$smooshin
"@
}
    if ($excludeHTMLinSMOOSH -and $true -eq $excludeHTMLinSMOOSH) {
        Write-Host "Not using HTML for smoosh; Cleaning values to text-friendly single-line."
        $smoosh = $smoosh -replace "`r?`n", ' '
        $smoosh = $smoosh -replace '\s{2,}', ' '
        $smoosh = Remove-HtmlTags -InputString $smoosh
        $smoosh = $smoosh.Trim()
    }
    write-host "Smooshed: $smoosh"
    write-host "$($($smoosh | ConvertTo-Json -depth 66).ToString())"
    return $smoosh
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


function Remove-HtmlTags {
    param (
        [string]$InputString
    )
    $tags = @(
        "hr", "br", "tr", "td", "th", "table",
        "div", "span", "p", "ul", "ol", "li",
        "h[1-6]", "strong", "em", "b", "i"
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
    "@{from='';to='$toEsc'; dest_type='$desttype'; required='$req'; striphtml='False'}" 
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


function Set-ITGAssetsToExistingLayout {
    param (
        [string]$desiredMapFileName,
        [array]$sourceassets,
        [PSCustomObject]$sourceassetlayout,
        [array]$allrelations,
        [bool]$stagedMode=$false,
        [int]$justMap=$false,
        [hashtable]$userMapping=$null,
        [bool]$PromptOnMatch=$false
    )
    $createdAssets = @()    
    $sourcedestlabels = @{}
    $sourcedestrequired = @{}        
    $sourcedestStripHTML = @{}        
    $CONSTANTS=@()
    $SMOOSHLABELS=@()
    $mapping=@()
    $inspectlayouts = $false    
    $desiredMapFilePath = $(join-path $ITGCUSTOMMAPPINGSDIR $desiredMapFileName)
    if ($userMapping -and $null -ne $userMapping -and $stagedMode -and $true -eq $stagedMode) {
            $srcfields=$userMapping.srcfields
            $dstfields=$userMapping.dstfields
            $destassets=$userMapping.destassets
            $CONSTANTS=$userMapping.CONSTANTS
            $SMOOSHLABELS=$userMapping.SMOOSHLABELS
            $mapping=$userMapping.mapping        
            $includeblanksduringsmoosh=$userMapping.includeblanksduringsmoosh
            $includeRelationsForArchived=$userMapping.includeRelationsForArchived
            $includeLabelInSmooshedValues=$userMapping.includeLabelInSmooshedValues
            $excludeHTMLinSMOOSH=$userMapping.excludeHTMLinSMOOSH
            $describeRelatedInSmoosh=$userMapping.describeRelatedInSmoosh
            $destlayout=$userMapping.destassetlayout
            $sourcedestlabels=$userMapping.sourcedestlabels
            $sourcedestrequired=$userMapping.sourcedestrequired
    } else {
        write-host "$(if ($allassets -and $null -ne $allassets) {'using existing asset cache'} else {'refreshing asset cache'})"
        $destlayout   = Select-ObjectFromList -objects $(get-huduassetlayouts) -message "Which dest / target asset layout (migrating assets from $($sourceassetlayout.name)?" -allowNull $false -inspectObjects $true
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
            $dstfields+=@{label = $field.label; field_type = $field.field_type; required = $($field.required ?? $false)}
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
        # AddressData, ListSelect fields in target layout prevent us from updating layouts.
        # until bug gets solved, we can't update layouts with 'newer' field types.
        # if ($true -eq $settings.IncludeITGlueID -and [bool]$($(($sourceassetlayout.fields | Where-Object {$_.label -eq "ITGlue ID"})).count -gt 0)) {
        #     Write-Host "Itglue ID set to be included, injecting into dest layout"
        #     $currentFields = $destlayout.fields | Where-Object {$_.field_type -ne "ListSelect"} ?? @()
        #     $sourceITGfield = $($sourceassetlayout.fields | Where-Object {$_.label -eq "ITGlue ID"} | Select-Object -First 1)
        #     if ($sourceITGfield) {$currentFields += $sourceITGfield}
        #     $null = Set-HuduAssetLayout -id $destlayout.id -fields $currentFields -name $destlayout.name
        #     Write-Host "added ITGLueID field, refreshing layouts"
        #     $destlayout = Get-HuduAssetLayouts -id $destlayout.id
        #     $mapping+=@{from="ITGlue ID"; to="ITGlue ID"; dest_type='Text'; required='False'}
        # }

        # foreach ($field in $sourceassetlayout.fields | Where-Object {$_.field_type -eq "AssetTag" -and -not @($null, 0) -contains $_.linkable_id}) {
        #     $matchingDestField = $($destlayout.fields | Where-Object {$_.field_type -eq "AssetTag" -and $field.linkable_id -eq $_.linkable_id} | Select-Object -First 1) ?? $null
        #     if ($null -ne $matchingDestField) {
        #         Write-Host "source tag field $($field.label) Destination layout has corresponding tag field: $($matchingDestField.label); adding to mapping."
        #         $mapping+=@{from="$($field.label)"; to="$($matchingDestField.label)"; dest_type='AssetTag'}
        #     } else {
        #         $linkableLayout=$(get-huduassetlayouts -id $field.linkable_id) ?? $null
        #         if ($null -ne $linkableLayout -and 'yes' -eq $(Select-ObjectFromList -message "Would you like to add corresponding assettag field $($field.label) from source layout $($sourceassetlayout.name) to your destination layout, $($destlayout.name)?")){
        #             $currentFields = $destlayout.fields ?? @()
        #             $MaxPosition = $($currentFields.position | Sort-Object -Descending | Select-Object -First) ?? 1
        #             $currentFields += @{
        #                 position     = $($MaxPosition+1)
        #                 label        = $field.label
        #                 field_type   = 'AssetTag'
        #                 show_in_list = $($field.show_in_list ?? 'false').ToString().ToLower()
        #                 linkable_id  = $field.linkable_id
        #             }
        #             $null = Set-HuduAssetLayout -id $destlayout.id -fields $currentFields -name $destlayout.name
        #             Write-Host "added assettag field, refreshing layouts"
        #             $destlayout = Get-HuduAssetLayouts -id $destlayout.id
        #             $mapping+=@{from="$($field.label)"; to="$($field.label)"; dest_type='AssetTag'}
        #         }
        #     }
        # }
        foreach ($entry in $mapping) {
            write-host "mapping $($entry.from) to $($entry.to)"
            $sourcedestlabels[$entry.from] = $entry.to
            $sourcedestrequired[$entry.from] = $($entry.to ?? $false)
            $sourcedestStripHTML[$entry.from] = [bool]$(@('t','true','yes','y') -contains "$($entry.striphtml ?? 'false')".ToLower())
        }
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
    }
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
        foreach ($kv in $($originalasset.fields | ForEach-Object GetEnumerator)) {
            $field = @{label = $kv.Key; value = $kv.Value; 
                required=$($("$($sourcedestrequired[$kv.Key])".ToLower() -eq 'true') ?? $false)
                stripHTML=$($($sourcedestStripHTML[$kv.Key]) ?? $false)            
            }
            $transformedlabel = $($sourcedestlabels[$field.label] ?? $null)
            if (-not $transformedlabel -or $null -eq $transformedlabel) {continue}
                
            if (-not $field.value -or $null -eq $field.value) {
                    write-host "no translate for $($field.label)";
                    if ($true -eq $field.required) {
                        write-host "no value for REQUIRED $($field.label) => $transformedlabel"
                        $field.value = $($(read-host "target field $($field.label) => $transformedlabel is required but null, enter value") ?? "None")
                    } else {
                        write-host "no value for optional $($field.label) => $transformedlabel"
                        continue
                    }
                }
            if ($true -eq $field.StripHTML) {
                $field.value = "$(Remove-HtmlTags -InputString "$($field.value)")"
            }

            $transformedFields += @{$transformedlabel = $field.value}
            write-host "$($field.label) => $transformedlabel for value $($field.value)"
        }

        if ($sourceassetlayout.linkables -and $sourceassetlayout.linkables.keys.count -gt 0){
            Write-host "Getting linkable items for asset $($originalasset.name) from $($sourceassetlayout.linkables.keys.count) potentially linkable"
            $linkableToAssetInfo = Get-RelinkableRelationsForAsset -sourceAsset $originalasset -labelLinkMap $sourceassetlayout.linkables
        }
        # map custom smooshed fields ( notes, richtext, whatever we smooshed to in map)
        if ($true -eq $mappingtosmooshed) {
            $valueToAdd="$(Set-SmooshAssetFieldsToField -sourceAsset $originalasset -smooshsource $SMOOSHLABELS -includeBlanks $($includeblanksduringsmoosh ?? $false))"
            # if linkables, smoosh in too.
            if ($describeRelatedInSmoosh -and $true -eq $describeRelatedInSmoosh){
                $describerelated=Get-SmooshedLinkableDescription -linkableObjects $linkableToAssetInfo
                $valueToAdd="$describerelated<br>$valueToAdd"
                if ($valueToAdd -eq "<br>") {continue}
                if ($true -eq $excludeHTMLinSMOOSH){$valueToAdd = Remove-HtmlTags -InputString $valueToAdd }
            }        
            $transformedFields+=@{"$($sourcedestlabels["SMOOSH"])" = $valueToAdd}
        }

        $newAssetRequest = @{
            Name            = $originalasset.name
            CompanyId       = $originalasset.ITGObject.HuduCompanyID
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
            if ($false -eq $stagedMode) {
                $newAsset = $(new-huduasset @newAssetRequest).asset
                $originalasset  | Add-Member -MemberType 'NoteProperty' -Name 'CreatedNew' -Value $true  -Force
            } else {
                $newAssetRequest["id"] = $originalAsset.HuduObject.id
                $originalasset  | Add-Member -MemberType 'NoteProperty' -Name 'UpdatedAs' -Value $true  -Force
                $newAsset = $(set-huduasset @newAssetRequest).asset
            }
            write-host "Created asset $($newAsset.id)"
            # archive new asset if original was archived
            
            # if ($originalasset.archived -eq $true) {
            #     Set-HuduAssetArchive -CompanyId $newAsset.company_id -Id $newAsset.id -Archive $true
            #     $totalcounts.assetsarchived=$totalcounts.assetsarchived+1
            # }

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
        }

        return @{
            createdAssets   =$createdAssets
            destlayout      =$destlayout
            counts          =$totalcounts
            mappingInfo     =$mappingInfo
        }
}