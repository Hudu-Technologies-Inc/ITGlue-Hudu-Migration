[CmdletBinding()]
param(
    [string]$JobPath,
    [switch]$Gui
    )

$ErrorActionPreference = 'Stop'
$debug = $env:HUDU_LAYOUT_TRANSFER_DEBUG -in @('1','true','yes','on')
if ($debug) {
    $VerbosePreference = 'Continue'
    Write-Verbose 'Debug mode enabled.'
}

$scriptPath = if ($PSCommandPath) { $PSCommandPath } elseif ($MyInvocation.MyCommand.Path) { $MyInvocation.MyCommand.Path } else { '' }
$candidateRoots = @()
if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) { $candidateRoots += $PSScriptRoot }
if (-not [string]::IsNullOrWhiteSpace($scriptPath)) { $candidateRoots += (Split-Path -Parent $scriptPath) }
$candidateRoots += (Get-Location).Path
$candidateRoots += (Split-Path -Parent ([Environment]::GetCommandLineArgs()[0]))
$candidateRoots = @($candidateRoots | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)

$script:Root = $candidateRoots[0]
$script:UpstreamScriptPath = $null
foreach ($candidateRoot in $candidateRoots) {
    foreach ($candidateName in @('Move-AssetsToNewLayout.ps1')) {
        $scriptcandidate = Join-Path $candidateRoot $candidateName
        if (Test-Path $scriptcandidate) {
            $script:Root = $candidateRoot
            $script:UpstreamScriptPath = $scriptcandidate
            break
        }
    }

    if ($script:UpstreamScriptPath) {
        break
    }
}

function Get-HuduModule {
    param (
        [string]$HAPImodulePath = "C:\Users\$env:USERNAME\Documents\GitHub\HuduAPI\HuduAPI\HuduAPI.psm1",
        [bool]$use_hudu_fork = $true
        )

    if ($true -eq $use_hudu_fork) {
        if (-not $(Test-Path $HAPImodulePath)) {
            $dst = Split-Path -Path (Split-Path -Path $HAPImodulePath -Parent) -Parent
            $zip = "$env:TEMP\huduapi.zip"
            Invoke-WebRequest -Uri "https://github.com/Hudu-Technologies-Inc/HuduAPI/archive/refs/heads/master.zip" -OutFile $zip
            Expand-Archive -Path $zip -DestinationPath $env:TEMP -Force 
            $extracted = Join-Path $env:TEMP "HuduAPI-master" 
            if (Test-Path $dst) { Remove-Item $dst -Recurse -Force }
            Move-Item -Path $extracted -Destination $dst 
            Remove-Item $zip -Force
        }
    } 

    if (Test-Path $HAPImodulePath) {
        Import-Module $HAPImodulePath -Force
    } elseif ((Get-Module -ListAvailable -Name HuduAPI).Version -ge [version]'2.4.4') {
        Import-Module HuduAPI
    } else {
        Install-Module HuduAPI -MinimumVersion 2.4.5 -Scope CurrentUser -Force
        Import-Module HuduAPI
    }
}

function Set-HuduInstance {
    param ([string]$HuduBaseURL, [string]$HuduAPIKey)
    $HuduBaseURL = $HuduBaseURL ?? $((Read-Host -Prompt 'Set the base domain of your Hudu instance (e.g https://myinstance.huducloud.com)') -replace '[\\/]+$', '') -replace '^(?!https://)', 'https://'
    $HuduAPIKey = $HuduAPIKey ?? "$(read-host "Please Enter Hudu API Key")"
    while ($HuduAPIKey.Length -ne 24) {
        $HuduAPIKey = (Read-Host -Prompt "Get a Hudu API Key from $($settings.HuduBaseDomain)/admin/api_keys").Trim()
    }
    New-HuduAPIKey $HuduAPIKey
    New-HuduBaseURL $HuduBaseURL
}


function Get-GuiFieldMappings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [array]$DestFields,

        [array]$SourceFieldOptions = @()
    )

    $mapping = @()

    foreach ($field in $DestFields) {
        if (($field.field_type ?? $field.type) -eq 'AssetTag') {
            Write-Verbose "Skipping asset tag field '$($field.label)' because it will be relinked as a relation."
            continue
        }

        $result = Show-FieldMappingEditor -DestField $field -SourceFieldOptions $SourceFieldOptions -AllowMeta

        if (-not $result.Success) {
            throw "Field mapping was cancelled while editing '$($field.label)'."
        }

        if ($result.Skip) {
            continue
        }

        $mapping += $result.Value
    }

    return ,$mapping
}
function Write-GuiMappingFile {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [array]$MappingEntries,

        [Parameter()]
        [array]$ConstantEntries = @(),

        [Parameter()]
        [string[]]$SmooshSourceLabels = @(),

        [Parameter(Mandatory)]
        [string]$Path,

        [string]$PerJobSettings = ''
    )

    $constantText = @(
        foreach ($entry in $ConstantEntries) {
            $literalEsc = ([string]$entry.literal) -replace '"', '\"'
            $toEsc = ([string]$entry.to_label) -replace '"', '\"'
@"
    @{
        literal="$literalEsc"
        to_label="$toEsc"
    }
"@
        }
    )

    $mappingTextEntries = @(
        foreach ($entry in $MappingEntries) {
            Convert-MappingEntryToText -Entry $entry
        }
    )

    $smooshText = @(
        foreach ($entry in $SmooshSourceLabels) {
            $escaped = ([string]$entry) -replace "'", "''"
            "    '$escaped'"
        }
    )

    $smooshBlock = @"

`$SMOOSHLABELS=@(
$($smooshText -join ",`r`n")
)
"@

    $mappingText =
@'
# source 
$CONSTANTS=@(
'@ + ($constantText -join ",`r`n") + @'
)
'@ + "`n" +
$smooshBlock + @'

$mapping=@(
'@ + ($mappingTextEntries -join ",`r`n") + @'
)
'@ + "`n" + @"
$PerJobSettings
"@ + "`n"
Write-Verbose "Mapping count: $($mappingEntries.Count)"
Write-Verbose "Constant count: $($constantEntries.Count)"
Write-Verbose "Smoosh source label count: $($SmooshSourceLabels.Count)"
Write-Verbose "Map file path: $mapfile"
$mappingEntries | ConvertTo-Json -Depth 10 | Set-Content "$mapfile.debug.json"
    Set-Content -Path $Path -Value $mappingText -Encoding UTF8
}

function Convert-MappingEntryToText {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Entry
    )

    $toEsc = ([string]$Entry.to) -replace "'", "''"
    $destTypeEsc = ([string]$Entry.dest_type) -replace "'", "''"
    $requiredEsc = ([string]$Entry.required).ToLower()

    switch ($Entry.dest_type) {
        'ListSelect' {
            $fromEsc = ([string]$Entry.from) -replace "'", "''"
            $addListItemsEsc = ([string]$Entry.add_listitems).ToLower()

            $mappingLines = foreach ($k in $Entry.Mapping.Keys) {
                $kEsc = ([string]$k) -replace "'", "''"
                $vals = @($Entry.Mapping[$k].whenvalues)
                $valsText = ($vals | ForEach-Object { "'$($_ -replace "'", "''")'" }) -join ','

                "    '$kEsc'=@{whenvalues=@($valsText)}"
            }

@"
@{to='$toEsc'; from='$fromEsc'; add_listitems='$addListItemsEsc'; list_id=$($Entry.list_id); dest_type='ListSelect'; required='$requiredEsc'; Mapping=@{
$($mappingLines -join "`r`n")
}}
"@
        }

        'AddressData' {
            $addressLines = foreach ($part in @('address_line_1','address_line_2','city','state','zip','country_name')) {
                $fromVal = ''
                if ($Entry.address.ContainsKey($part) -and $Entry.address[$part].ContainsKey('from')) {
                    $fromVal = [string]$Entry.address[$part].from
                }
                $fromEsc = $fromVal -replace "'", "''"
                "    $part=@{from='$fromEsc'}"
            }

@"
@{to='$toEsc'; from='Meta'; dest_type='AddressData'; required='$requiredEsc'; address=@{
$($addressLines -join "`r`n")
}}
"@
        }

        default {
            $fromEsc = ([string]$Entry.from) -replace "'", "''"
            $stripHtmlEsc = ([string]$Entry.striphtml).ToLower()

"@{from='$fromEsc';to='$toEsc'; dest_type='$destTypeEsc'; required='$requiredEsc'; striphtml='$stripHtmlEsc'}"
        }
    }
}

function Convert-BoolToYesNo {
    param([object]$Value)

    if ([bool]$Value) { 'Yes' } else { 'No' }
}

function Get-PreviewText {
    param(
        [AllowNull()]
        [object]$Value,

        [int]$MaxLength = 90
    )

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return '[blank]'
    }

    $text = ($text -replace '\r?\n', ' ') -replace '\s{2,}', ' '
    if ($text.Length -le $MaxLength) {
        return $text
    }

    return '{0}...' -f $text.Substring(0, $MaxLength - 3)
}

function Get-MergeOptionSummaryLabel {
    param([string]$Value)

    switch ($Value) {
        'Merge-FillBlanks' { 'Merge-FillBlanks - only fill empty destination fields' }
        'Merge-PreferSource' { 'Merge-PreferSource - source values win on matches' }
        'Skip' { 'Skip - leave matching destination assets unchanged' }
        default { 'Merge-Concat - combine values where it makes sense' }
    }
}

function Convert-MappingEntryToSummaryLine {
    param(
        [Parameter(Mandatory)]
        [psobject]$Entry
    )

    switch ([string]$Entry.dest_type) {
        'AddressData' {
            $parts = foreach ($partName in @($Entry.address.Keys | Sort-Object)) {
                $partSource = [string]$Entry.address[$partName].from
                if (-not [string]::IsNullOrWhiteSpace($partSource)) {
                    '{0} <= {1}' -f $partName, $partSource
                }
            }

            if (-not $parts) {
                $parts = @('No address parts selected')
            }

            return '{0} [{1}] <= {2}' -f $Entry.to, $Entry.dest_type, ($parts -join '; ')
        }

        'ListSelect' {
            $ruleCount = @($Entry.Mapping.Keys).Count
            return '{0} [ListSelect] <= {1}; add missing list items: {2}; value rules: {3}' -f $Entry.to, $Entry.from, (Convert-BoolToYesNo $Entry.add_listitems), $ruleCount
        }

        default {
            $details = @()
            $details += '{0} [{1}] <= {2}' -f $Entry.to, $Entry.dest_type, $Entry.from
            if ($null -ne $Entry.striphtml -and [bool]$Entry.striphtml) {
                $details += 'strip HTML'
            }
            if ($null -ne $Entry.required -and [bool]$Entry.required) {
                $details += 'required'
            }

            return ($details -join '; ')
        }
    }
}

function New-TransferReviewSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$BaseUrl,

        [Parameter(Mandatory)]
        [string]$ApiKey,

        [Parameter(Mandatory)]
        [psobject]$SourceLayout,

        [Parameter(Mandatory)]
        [psobject]$DestLayout,

        [Parameter(Mandatory)]
        [string]$MergeOption,

        [Parameter(Mandatory)]
        [bool]$ArchivePreference,

        [Parameter(Mandatory)]
        [string]$RenameSourceLayoutTo,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [array]$MappingEntries,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [array]$ConstantEntries,

        [Parameter()]
        [string[]]$SmooshSourceLabels = @(),

        [Parameter()]
        [psobject]$SmooshTargetEntry,

        [Parameter()]
        [string[]]$SkippedFieldLabels = @(),

        [Parameter()]
        [array]$PerJobSettingSummaries = @(),

        [Parameter(Mandatory)]
        [string]$MapFilePath
    )

    $apiKeyPreview = if ([string]::IsNullOrWhiteSpace($ApiKey)) {
        '[not set]'
    } elseif ($ApiKey.Length -le 4) {
        ('*' * $ApiKey.Length)
    } else {
        ('*' * ($ApiKey.Length - 4)) + $ApiKey.Substring($ApiKey.Length - 4)
    }

    $lines = @(
        'Please review this transfer plan before anything runs.',
        '',
        'Transfer Overview',
        ('- Base URL: {0}' -f $BaseUrl),
        ('- API key: {0}' -f $apiKeyPreview),
        ('- Source layout: {0} [ID {1}]' -f $SourceLayout.Name, $SourceLayout.id),
        ('- Destination layout: {0} [ID {1}]' -f $DestLayout.Name, $DestLayout.id),
        ('- Merge behavior on matched assets: {0}' -f (Get-MergeOptionSummaryLabel -Value $MergeOption)),
        ('- Rename source layout to: {0}' -f $RenameSourceLayoutTo),
        ('- Archive remaining source assets after transfer: {0}' -f (Convert-BoolToYesNo $ArchivePreference)),
        ('- Mapping file: {0}' -f $MapFilePath),
        ''
    )

    $lines += 'Direct Field Mappings'
    if (@($MappingEntries | Where-Object { $_.from -ne 'SMOOSH' }).Count -gt 0) {
        foreach ($entry in ($MappingEntries | Where-Object { $_.from -ne 'SMOOSH' })) {
            $lines += '- ' + (Convert-MappingEntryToSummaryLine -Entry $entry)
        }
    } else {
        $lines += '- None'
    }
    $lines += ''

    $lines += 'Constant Values'
    if (@($ConstantEntries).Count -gt 0) {
        foreach ($entry in $ConstantEntries) {
            $lines += ('- {0} <= "{1}"' -f $entry.to_label, (Get-PreviewText -Value $entry.literal))
        }
    } else {
        $lines += '- None'
    }
    $lines += ''

    $lines += 'SMOOSH Configuration'
    if ($null -ne $SmooshTargetEntry) {
        $lines += ('- Target field: {0}' -f $SmooshTargetEntry.to)
        $lines += ('- Source fields: {0}' -f $(if (@($SmooshSourceLabels).Count -gt 0) { $SmooshSourceLabels -join ', ' } else { 'None' }))
    } else {
        $lines += '- Not used'
    }
    $lines += ''

    $lines += 'Skipped Destination Fields'
    if (@($SkippedFieldLabels).Count -gt 0) {
        foreach ($fieldLabel in $SkippedFieldLabels) {
            $lines += ('- {0}' -f $fieldLabel)
        }
    } else {
        $lines += '- None'
    }
    $lines += ''

    $lines += 'Per-Job Settings'
    if (@($PerJobSettingSummaries).Count -gt 0) {
        foreach ($setting in $PerJobSettingSummaries) {
            $lines += ('- {0}: {1}' -f $setting.Name, (Convert-BoolToYesNo $setting.Value))
        }
    } else {
        $lines += '- None'
    }

    return ($lines -join "`r`n")
}

function layout2layout{
param (
    [string]$sourceLayoutName = "",
    [string]$targetLayoutName = ""
)

    # usage- move assets between same-field layouts
    # particularly useful for un-splitting split-configurations from ITG

    if ([string]::isnullorempty($sourceLayoutName) -or [string]::isnullorempty($targetLayoutName)) {
        write-error "sourceLayoutName and targetLayoutName parameters are required"
        exit 1
    }
    write-verbose "starting layout to layout move from '$sourceLayoutName' to '$targetLayoutName'"
    
    $results = $results ?? @()
    $sourcelayout = Get-HuduASsetlayouts -name $sourceLayoutName | select-object -first 1
    $targetLayout = Get-HuduASsetlayouts -name $targetLayoutName | select-object -first 1
    $sourceLayout = $sourcelayout.asset_layout ?? $sourcelayout
    $targetLayout = $targetLayout.asset_layout ?? $targetLayout

    $sourceLayoutID= $sourceLayout.id
    $targetLayoutId = $targetLayout.id
    if (-not $sourceLayoutID -or -not $targetLayoutId) {
        write-error "source or target layout not found"
        exit 1
    }

    function Move-HuduAssetToNewLayout {
        Param ([Int]$targetLayoutId,[Int]$Id)
        $asset = Get-HuduAssets -id $Id; $asset = $asset.asset ?? $asset;
        if (-not $asset) {throw "Asset with id $Id not found"}
        try {$moved = $(Invoke-HuduRequest -Method put -Resource "/api/v1/companies/$($asset.company_id)/assets/$($asset.id)/move_layout" -Body $($([pscustomobject]@{asset_layout_id = $targetLayoutId}) | ConvertTo-Json -Depth 10))
            return $moved
        } catch {
            throw $_
        }
    }

    foreach ($l in $(get-huduassetlayouts -id $sourceLayoutID)){
        write-verbose "starting movements for $($l.name), obtaining assets"
        $allassets = Get-HuduAssets -AssetLayoutId $l.id
        write-verbose "$($allassets.count) assets found, moving to layout id $targetLayoutId"
        foreach ($a in $allassets){
            try {
            $result = $null
            $result = Move-HuduAssetToNewLayout -id $a.id -targetLayoutId $targetLayoutId
            } catch {
                $result = @{
                    assetId = $a.id
                    companyId = $a.company_id
                    status = "error"
                    message = $_.exception.message
                }
                write-verbose "error moving asset id $($a.id) for company id $($a.company_id): $($_.exception.message)" 
            } finally {
                $results += $result
            }

        }
    }
    return $results
}
function Show-TransferReviewDialog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SummaryText,

        [string]$Title = 'Review Transfer Plan'
    )

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $form = New-Object System.Windows.Forms.Form
    $form.Text = $Title
    $form.StartPosition = 'CenterScreen'
    $form.Size = New-Object System.Drawing.Size(920,700)
    $form.MinimumSize = New-Object System.Drawing.Size(760,560)
    $form.Topmost = $true

    $intro = New-Object System.Windows.Forms.Label
    $intro.Location = New-Object System.Drawing.Point(12,12)
    $intro.Size = New-Object System.Drawing.Size(880,36)
    $intro.Text = 'Review the full transfer plan below. Choose Run Transfer to continue, or Cancel to stop before any changes are made.'
    $form.Controls.Add($intro)

    $summaryBox = New-Object System.Windows.Forms.TextBox
    $summaryBox.Location = New-Object System.Drawing.Point(12,56)
    $summaryBox.Size = New-Object System.Drawing.Size(880,560)
    $summaryBox.Multiline = $true
    $summaryBox.ReadOnly = $true
    $summaryBox.ScrollBars = 'Both'
    $summaryBox.WordWrap = $false
    $summaryBox.Font = New-Object System.Drawing.Font('Consolas', 9)
    $summaryBox.Text = $SummaryText
    $form.Controls.Add($summaryBox)

    $runButton = New-Object System.Windows.Forms.Button
    $runButton.Location = New-Object System.Drawing.Point(692,625)
    $runButton.Size = New-Object System.Drawing.Size(95,30)
    $runButton.Text = 'Run Transfer'
    $runButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $form.Controls.Add($runButton)

    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Location = New-Object System.Drawing.Point(797,625)
    $cancelButton.Size = New-Object System.Drawing.Size(95,30)
    $cancelButton.Text = 'Cancel'
    $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.Controls.Add($cancelButton)

    $form.AcceptButton = $runButton
    $form.CancelButton = $cancelButton

    return ($form.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK)
}

function Show-TransferMessage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [string]$Title = 'Hudu Asset Layout Transfer',

        [ValidateSet('Info','Warning','Error','Question')]
        [string]$Kind = 'Info',

        [switch]$YesNo
    )

    Add-Type -AssemblyName System.Windows.Forms

    $icon = switch ($Kind) {
        'Warning'  { [System.Windows.Forms.MessageBoxIcon]::Warning }
        'Error'    { [System.Windows.Forms.MessageBoxIcon]::Error }
        'Question' { [System.Windows.Forms.MessageBoxIcon]::Question }
        default    { [System.Windows.Forms.MessageBoxIcon]::Information }
    }

    $buttons = if ($YesNo) {
        [System.Windows.Forms.MessageBoxButtons]::YesNo
    } else {
        [System.Windows.Forms.MessageBoxButtons]::OK
    }

    $dialogResult = [System.Windows.Forms.MessageBox]::Show(
        $Message,
        $Title,
        $buttons,
        $icon
    )

    if ($YesNo) {
        return $dialogResult
    }
}

function Normalize-HuduBaseUrl {
    [CmdletBinding()]
    param([string]$Value)

    $normalized = [string]$Value
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return $null
    }

    $normalized = $normalized.Trim() -replace '[\\/]+$', ''
    if ($normalized -notmatch '^(?i)https?://') {
        $normalized = "https://$normalized"
    }

    try {
        $uri = [System.Uri]$normalized
    }
    catch {
        return $null
    }

    if (-not $uri.IsAbsoluteUri -or [string]::IsNullOrWhiteSpace($uri.Host)) {
        return $null
    }

    $uri.GetLeftPart([System.UriPartial]::Authority)
}

function Test-HuduApiKeyFormat {
    [CmdletBinding()]
    param([string]$Value)

    -not [string]::IsNullOrWhiteSpace($Value) -and $Value.Trim().Length -eq 24
}

function Get-LayoutChoiceLabel {
    [CmdletBinding()]
    param([Parameter(Mandatory)][psobject]$Layout)

    $fieldCount = @($Layout.Fields).Count
    $requiredCount = @($Layout.Fields | Where-Object { $_.required -eq $true }).Count

    '{0} [ID {1}] - {2} fields, {3} required' -f $Layout.Name, $Layout.id, $fieldCount, $requiredCount
}

function Show-FieldMappingEditor {
    param(
        [Parameter(Mandatory)]
        [psobject]$DestField,
        [string]$summaryLabel,

        [array]$SourceFieldOptions = @(),

        [string[]]$ExistingSmooshLabels = @(),

        [switch]$AllowMeta
    )

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    function New-Label {
        param([string]$Text,[int]$X,[int]$Y,[int]$W=180,[int]$H=22)
        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text = $Text
        $lbl.Location = New-Object System.Drawing.Point($X,$Y)
        $lbl.Size = New-Object System.Drawing.Size($W,$H)
        $lbl
    }

    function New-TextBox {
        param([int]$X,[int]$Y,[int]$W=420,[string]$Text='')
        $tb = New-Object System.Windows.Forms.TextBox
        $tb.Location = New-Object System.Drawing.Point($X,$Y)
        $tb.Size = New-Object System.Drawing.Size($W,24)
        $tb.Text = $Text
        $tb
    }

    function New-Combo {
        param([int]$X,[int]$Y,[int]$W=420,[string[]]$Options=@(),[string]$Default='')
        $cb = New-Object System.Windows.Forms.ComboBox
        $cb.Location = New-Object System.Drawing.Point($X,$Y)
        $cb.Size = New-Object System.Drawing.Size($W,24)
        $cb.DropDownStyle = 'DropDownList'
        foreach ($o in $Options) { [void]$cb.Items.Add($o) }
        if ($Default -and $cb.Items.Contains($Default)) {
            $cb.SelectedItem = $Default
        } elseif ($cb.Items.Count -gt 0) {
            $cb.SelectedIndex = 0
        }
        $cb
    }

    function Add-SourceOption {
        param(
            [Parameter(Mandatory)]
            [string]$Label,

            [string]$FieldType = ''
        )

        if ([string]::IsNullOrWhiteSpace($Label)) {
            return
        }

        $display = if ([string]::IsNullOrWhiteSpace($FieldType)) {
            $Label
        } else {
            '{0} [{1}]' -f $Label, $FieldType
        }

        $baseDisplay = $display
        $suffix = 2
        while ($sourceOptionLookup.Contains($display)) {
            $display = '{0} ({1})' -f $baseDisplay, $suffix
            $suffix++
        }

        $sourceOptionLookup[$display] = $Label
        $sourceOptionDisplayValues.Add($display) | Out-Null
    }

    $destType  = [string]($DestField.field_type ?? $DestField.type)
    $destLabel = [string]$DestField.label
    $required  = [bool]($DestField.required ?? $false)
    $listId    = $DestField.list_id

    $canSmoosh = $destType -in @('Text','RichText','Heading')
    $smooshTakenByOtherField = @($ExistingSmooshLabels | Where-Object { $_ -ne $destLabel }).Count -gt 0

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Review Destination Field Mapping'
    $form.Size = New-Object System.Drawing.Size(700, 640)
    $form.StartPosition = 'CenterScreen'
    $form.Topmost = $true
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $form.BackColor = [System.Drawing.Color]::WhiteSmoke
    $form.Tag = $null
    $titleLabel = New-Label -Text $destLabel -X 20 -Y 12 -W 640 -H 28
    $titleLabel.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 12)
    $form.Controls.Add($titleLabel)

    $summaryText = if ([string]::IsNullOrWhiteSpace($summaryLabel)) {
        "Choose how to fill this $destType field."
    } else {
        $summaryLabel
    }
    $summaryControl = New-Label -Text $summaryText -X 20 -Y 42 -W 640 -H 36
    $summaryControl.ForeColor = [System.Drawing.Color]::DimGray
    $form.Controls.Add($summaryControl)

    $tipLabel = New-Label -Text 'Tip: Use Source Field for a direct match, Constant Value for required defaults, and Skip only when the destination field is truly optional.' -X 20 -Y 80 -W 640 -H 36
    $tipLabel.ForeColor = [System.Drawing.Color]::FromArgb(60, 90, 120)
    $form.Controls.Add($tipLabel)

    $y = 125

    $form.Controls.Add((New-Label -Text "Mapping Mode:" -X 20 -Y $y))
    $modeOptions = @('Source Field','Constant Value','Skip')
    if ($canSmoosh -and -not $smooshTakenByOtherField) {
        $modeOptions = @('Source Field','Constant Value','SMOOSH','Skip')
    }

    $cbMode = New-Combo -X 210 -Y $y -Options $modeOptions
    $form.Controls.Add($cbMode)
    $y += 32

    $form.Controls.Add((New-Label -Text "Destination Label:" -X 20 -Y $y))
    $tbDest = New-TextBox -X 210 -Y $y -Text $destLabel
    $tbDest.ReadOnly = $true
    $form.Controls.Add($tbDest)
    $y += 32

    $form.Controls.Add((New-Label -Text "Destination Type:" -X 20 -Y $y))
    $tbType = New-TextBox -X 210 -Y $y -Text $destType
    $tbType.ReadOnly = $true
    $form.Controls.Add($tbType)
    $y += 32

    $form.Controls.Add((New-Label -Text "Required:" -X 20 -Y $y))
    $chkRequired = New-Object System.Windows.Forms.CheckBox
    $chkRequired.Location = New-Object System.Drawing.Point(210,$y)
    $chkRequired.Size = New-Object System.Drawing.Size(120,24)
    $chkRequired.Checked = $required
    $chkRequired.Enabled = $false
    $form.Controls.Add($chkRequired)
    $y += 36

    $pnlStandard = New-Object System.Windows.Forms.Panel
    $pnlStandard.Location = New-Object System.Drawing.Point(15,$y)
    $pnlStandard.Size = New-Object System.Drawing.Size(650,120)

    $pnlAddress = New-Object System.Windows.Forms.Panel
    $pnlAddress.Location = New-Object System.Drawing.Point(15,$y)
    $pnlAddress.Size = New-Object System.Drawing.Size(650,220)
    $pnlAddress.Visible = $false

    $pnlList = New-Object System.Windows.Forms.Panel
    $pnlList.Location = New-Object System.Drawing.Point(15,$y)
    $pnlList.Size = New-Object System.Drawing.Size(650,260)
    $pnlList.Visible = $false

    $pnlConstant = New-Object System.Windows.Forms.Panel
    $pnlConstant.Location = New-Object System.Drawing.Point(15,$y)
    $pnlConstant.Size = New-Object System.Drawing.Size(650,80)
    $pnlConstant.Visible = $false

    $pnlSmoosh = New-Object System.Windows.Forms.Panel
    $pnlSmoosh.Location = New-Object System.Drawing.Point(15,$y)
    $pnlSmoosh.Size = New-Object System.Drawing.Size(650,260)
    $pnlSmoosh.Visible = $false

    $sourceOptionLookup = [ordered]@{}
    $sourceOptionDisplayValues = New-Object System.Collections.Generic.List[string]
    foreach ($sourceOption in $SourceFieldOptions) {
        if ($sourceOption -is [string]) {
            Add-SourceOption -Label ([string]$sourceOption)
            continue
        }

        $optionLabel = [string]($sourceOption.label ?? $sourceOption.Label ?? $sourceOption.name ?? $sourceOption.Name)
        $optionType = [string]($sourceOption.field_type ?? $sourceOption.type ?? $sourceOption.FieldType)
        Add-SourceOption -Label $optionLabel -FieldType $optionType
    }
    if ($AllowMeta -and -not ($sourceOptionLookup.Values -contains 'Meta')) {
        Add-SourceOption -Label 'Meta' -FieldType 'Pseudo'
    }
    $sourceOptions = @($sourceOptionDisplayValues)

    $pnlStandard.Controls.Add((New-Label -Text "Source Field:" -X 5 -Y 5))
    $cbFrom = New-Combo -X 195 -Y 5 -Options (@('') + $sourceOptions)
    $pnlStandard.Controls.Add($cbFrom)

    $chkStripHtml = New-Object System.Windows.Forms.CheckBox
    $chkStripHtml.Location = New-Object System.Drawing.Point(195,40)
    $chkStripHtml.Size = New-Object System.Drawing.Size(200,24)
    $chkStripHtml.Text = 'Strip HTML'
    $pnlStandard.Controls.Add($chkStripHtml)

    $pnlConstant.Controls.Add((New-Label -Text "Constant Value:" -X 5 -Y 5))
    $tbConstant = New-TextBox -X 195 -Y 5 -W 420
    $pnlConstant.Controls.Add($tbConstant)

    $pnlSmoosh.Controls.Add((New-Label -Text "Source Fields To Combine:" -X 5 -Y 5 -W 180))
    $smooshHint = New-Label -Text 'Choose the source fields that should be concatenated into the single destination SMOOSH field.' -X 195 -Y 5 -W 430 -H 36
    $smooshHint.ForeColor = [System.Drawing.Color]::DimGray
    $pnlSmoosh.Controls.Add($smooshHint)

    $smooshSourceOptions = @(
        $sourceOptions |
        Where-Object {
            ([string]($sourceOptionLookup[[string]$_] ?? [string]$_)) -notin @('SMOOSH','Meta')
        }
    )

    $smooshSelectionState = [pscustomobject]@{
        Fields = @()
    }

    $lblSmooshSelection = New-Label -Text 'No source fields selected yet.' -X 195 -Y 55 -W 420 -H 70
    $lblSmooshSelection.ForeColor = [System.Drawing.Color]::FromArgb(60, 90, 120)
    $pnlSmoosh.Controls.Add($lblSmooshSelection)

    $btnChooseSmooshFields = New-Object System.Windows.Forms.Button
    $btnChooseSmooshFields.Location = New-Object System.Drawing.Point(195,140)
    $btnChooseSmooshFields.Size = New-Object System.Drawing.Size(160,30)
    $btnChooseSmooshFields.Text = 'Choose Source Fields'
    $pnlSmoosh.Controls.Add($btnChooseSmooshFields)

    $updateSmooshSummary = {
        if ($smooshSelectionState.Fields.Count -eq 0) {
            $lblSmooshSelection.Text = 'No source fields selected yet.'
            return
        }

        $previewItems = @($smooshSelectionState.Fields | Select-Object -First 5)
        $previewText = $previewItems -join ', '
        if ($smooshSelectionState.Fields.Count -gt 5) {
            $previewText = '{0}, +{1} more' -f $previewText, ($smooshSelectionState.Fields.Count - 5)
        }

        $lblSmooshSelection.Text = 'Selected source fields: ' + $previewText
    }

    $openSmooshPicker = {
        $picker = New-Object System.Windows.Forms.Form
        $picker.Text = "Choose SMOOSH Source Fields"
        $picker.Size = New-Object System.Drawing.Size(560, 500)
        $picker.StartPosition = 'CenterParent'
        $picker.TopMost = $true
        $picker.FormBorderStyle = 'FixedDialog'
        $picker.MaximizeBox = $false
        $picker.MinimizeBox = $false
        $picker.Font = New-Object System.Drawing.Font('Segoe UI', 9)

        $pickerIntro = New-Object System.Windows.Forms.Label
        $pickerIntro.Location = New-Object System.Drawing.Point(15,15)
        $pickerIntro.Size = New-Object System.Drawing.Size(510,40)
        $pickerIntro.Text = "Select one or more source fields to concatenate into '$destLabel'."
        $picker.Controls.Add($pickerIntro)

        $pickerList = New-Object System.Windows.Forms.CheckedListBox
        $pickerList.Location = New-Object System.Drawing.Point(15,65)
        $pickerList.Size = New-Object System.Drawing.Size(510,320)
        $pickerList.CheckOnClick = $true
        foreach ($option in $smooshSourceOptions) {
            $index = $pickerList.Items.Add($option)
            $rawLabel = [string]($sourceOptionLookup[[string]$option] ?? [string]$option)
            if ($rawLabel -in $smooshSelectionState.Fields) {
                $pickerList.SetItemChecked($index, $true)
            }
        }
        $picker.Controls.Add($pickerList)

        $pickerOk = New-Object System.Windows.Forms.Button
        $pickerOk.Location = New-Object System.Drawing.Point(360,400)
        $pickerOk.Size = New-Object System.Drawing.Size(75,28)
        $pickerOk.Text = 'OK'
        $pickerOk.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $picker.Controls.Add($pickerOk)

        $pickerCancel = New-Object System.Windows.Forms.Button
        $pickerCancel.Location = New-Object System.Drawing.Point(450,400)
        $pickerCancel.Size = New-Object System.Drawing.Size(75,28)
        $pickerCancel.Text = 'Cancel'
        $pickerCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $picker.Controls.Add($pickerCancel)

        $picker.AcceptButton = $pickerOk
        $picker.CancelButton = $pickerCancel

        if ($picker.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
            $smooshSelectionState.Fields = @(
                $pickerList.CheckedItems |
                ForEach-Object { [string]($sourceOptionLookup[[string]$_] ?? [string]$_) } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            )
            & $updateSmooshSummary
        }
    }

    $btnChooseSmooshFields.Add_Click({ & $openSmooshPicker })
    & $updateSmooshSummary

    $buildSmooshValue = {
        if ($smooshSelectionState.Fields.Count -eq 0) {
            & $openSmooshPicker
        }

        if ($smooshSelectionState.Fields.Count -eq 0) {
            Show-TransferMessage `
                -Title 'SMOOSH Needs Source Fields' `
                -Kind Warning `
                -Message "Choose one or more source fields to combine into '$destLabel'."
            return $null
        }

        @{
            kind               = 'smoosh'
            smooshSourceLabels = @($smooshSelectionState.Fields)
            smooshTarget       = @{
                kind      = 'mapping'
                from      = 'SMOOSH'
                to        = $destLabel
                dest_type = $destType
                required  = $required
                striphtml = $false
            }
        }
    }

    $addressParts = @(
        @{ Key='address_line_1'; Label='Address Line 1' },
        @{ Key='address_line_2'; Label='Address Line 2' },
        @{ Key='city';           Label='City' },
        @{ Key='state';          Label='State' },
        @{ Key='zip';            Label='Zip' },
        @{ Key='country_name';   Label='Country' }
    )

    $addressCombos = @{}
    $ay = 5
    foreach ($part in $addressParts) {
        $pnlAddress.Controls.Add((New-Label -Text "$($part.Label):" -X 5 -Y $ay))
        $combo = New-Combo -X 195 -Y $ay -Options (@('') + $sourceOptions)
        $pnlAddress.Controls.Add($combo)
        $addressCombos[$part.Key] = $combo
        $ay += 30
    }

    $pnlList.Controls.Add((New-Label -Text "Source Field:" -X 5 -Y 5))
    $cbListFrom = New-Combo -X 195 -Y 5 -Options (@('') + $sourceOptions)
    $pnlList.Controls.Add($cbListFrom)

    $chkAddListItems = New-Object System.Windows.Forms.CheckBox
    $chkAddListItems.Location = New-Object System.Drawing.Point(195,40)
    $chkAddListItems.Size = New-Object System.Drawing.Size(220,24)
    $chkAddListItems.Text = 'Add missing list items'
    $pnlList.Controls.Add($chkAddListItems)

    $pnlList.Controls.Add((New-Label -Text "List Value Mapping:" -X 5 -Y 75 -W 180))

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Location = New-Object System.Drawing.Point(5,100)
    $grid.Size = New-Object System.Drawing.Size(620,145)
    $grid.AllowUserToAddRows = $false
    $grid.AllowUserToDeleteRows = $false
    $grid.RowHeadersVisible = $false
    $grid.AutoSizeColumnsMode = 'Fill'
    [void]$grid.Columns.Add('ListItem','Destination List Item')
    [void]$grid.Columns.Add('WhenValues','Source values (comma-separated)')
    $pnlList.Controls.Add($grid)

    if ($destType -eq 'ListSelect' -and $listId) {
        try {
            $listItems = (Get-HuduLists -id $listId).list_items.name
            foreach ($item in $listItems) {
                [void]$grid.Rows.Add($item, '')
            }
        } catch {}
    }

    $form.Controls.Add($pnlStandard)
    $form.Controls.Add($pnlAddress)
    $form.Controls.Add($pnlList)
    $form.Controls.Add($pnlConstant)
    $form.Controls.Add($pnlSmoosh)

    $updateModeUi = {
        $mode = [string]$cbMode.SelectedItem

        $pnlStandard.Visible = $false
        $pnlAddress.Visible  = $false
        $pnlList.Visible     = $false
        $pnlConstant.Visible = $false
        $pnlSmoosh.Visible   = $false

        switch ($mode) {
            'Constant Value' {
                $pnlConstant.Visible = $true
            }
            'Source Field' {
                switch ($destType) {
                    'AddressData' { $pnlAddress.Visible = $true }
                    'ListSelect'  { $pnlList.Visible = $true }
                    default       { $pnlStandard.Visible = $true }
                }
            }
            'SMOOSH' { $pnlSmoosh.Visible = $true }
            'Skip'   { }
        }
    }

    $cbMode.Add_SelectedIndexChanged($updateModeUi)
    $cbMode.Add_SelectedIndexChanged({
        if ([string]$cbMode.SelectedItem -eq 'SMOOSH' -and $smooshSelectionState.Fields.Count -eq 0) {
            & $openSmooshPicker
        }
    })
    $cbFrom.Add_SelectedIndexChanged({
        $selectedSourceLabel = [string]($sourceOptionLookup[[string]$cbFrom.SelectedItem] ?? [string]$cbFrom.SelectedItem)
        if ($selectedSourceLabel -eq 'SMOOSH' -and $canSmoosh) {
            $cbMode.SelectedItem = 'SMOOSH'
            if ($smooshSelectionState.Fields.Count -eq 0) {
                & $openSmooshPicker
            }
        }
    })
    & $updateModeUi

    $okButton = New-Object System.Windows.Forms.Button
    $okButton.Location = New-Object System.Drawing.Point(490,545)
    $okButton.Size = New-Object System.Drawing.Size(75,28)
    $okButton.Text = 'OK'
    $form.Controls.Add($okButton)

    $skipButton = New-Object System.Windows.Forms.Button
    $skipButton.Location = New-Object System.Drawing.Point(400,545)
    $skipButton.Size = New-Object System.Drawing.Size(75,28)
    $skipButton.Text = 'Skip'
    $form.Controls.Add($skipButton)

    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Location = New-Object System.Drawing.Point(580,545)
    $cancelButton.Size = New-Object System.Drawing.Size(75,28)
    $cancelButton.Text = 'Cancel'
    $form.Controls.Add($cancelButton)

    $skipButton.Add_Click({
        if ($required) {
            $result = Show-TransferMessage `
                -Title 'Required Field' `
                -Kind Question `
                -YesNo `
                -Message "The destination field '$destLabel' is marked required. Skipping it may cause the transfer to fail or require a manual fix later.`r`n`r`nDo you still want to skip it?"

            if ($result -ne [System.Windows.Forms.DialogResult]::Yes) {
                return
            }
        }

        $form.Tag = [pscustomobject]@{
            Success = $true
            Skip    = $true
            Value   = $null
        }
        $form.Close()
    })

    $cancelButton.Add_Click({ $form.Close() })

    $okButton.Add_Click({
        $mode = [string]$cbMode.SelectedItem

        switch ($mode) {
            'Skip' {
                if ($required) {
                    $result = Show-TransferMessage `
                        -Title 'Required Field' `
                        -Kind Question `
                        -YesNo `
                        -Message "The destination field '$destLabel' is marked required. Skipping it may cause the transfer to fail or require a manual fix later.`r`n`r`nDo you still want to skip it?"

                    if ($result -ne [System.Windows.Forms.DialogResult]::Yes) {
                        return
                    }
                }

                $form.Tag = [pscustomobject]@{
                    Success = $true
                    Skip    = $true
                    Value   = $null
                }
                $form.Close()
                return
            }

            'Constant Value' {
                if ($required -and [string]::IsNullOrWhiteSpace($tbConstant.Text)) {
                    Show-TransferMessage `
                        -Title 'Constant Required' `
                        -Kind Warning `
                        -Message "The destination field '$destLabel' is required. Enter a constant value, or switch this field to Source Field or Skip."
                    return
                }

                $form.Tag = [pscustomobject]@{
                    Success = $true
                    Skip    = $false
                    Value   = @{
                        kind     = 'constant'
                        to_label = $destLabel
                        literal  = $tbConstant.Text
                    }
                }
                $form.Close()
                return
            }

            'SMOOSH' {
                $smooshValue = & $buildSmooshValue
                if ($null -eq $smooshValue) { return }

                $form.Tag = [pscustomobject]@{
                    Success = $true
                    Skip    = $false
                    Value   = $smooshValue
                }
                $form.Close()
                return
            }

            'Source Field' {
                switch ($destType) {
                    'AddressData' {
                        $addressSelections = @(
                            foreach ($part in $addressParts) {
                                [string]$addressCombos[$part.Key].SelectedItem
                            }
                        )

                        if (@($addressSelections | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count -eq 0) {
                            Show-TransferMessage `
                                -Title 'Address Mapping Needed' `
                                -Kind Warning `
                                -Message "Choose at least one source field for the address mapping, or skip '$destLabel' if you do not want to populate it."
                            return
                        }
                    }
                    'ListSelect' {
                        if ([string]::IsNullOrWhiteSpace([string]$cbListFrom.SelectedItem)) {
                            Show-TransferMessage `
                                -Title 'Source Field Required' `
                                -Kind Warning `
                                -Message "Choose a source field for '$destLabel', or switch the mapping mode to Constant Value or Skip."
                            return
                        }
                    }
                    default {
                        $selectedStandardSource = [string]($sourceOptionLookup[[string]$cbFrom.SelectedItem] ?? [string]$cbFrom.SelectedItem)
                        if ([string]::IsNullOrWhiteSpace([string]$cbFrom.SelectedItem)) {
                            Show-TransferMessage `
                                -Title 'Source Field Required' `
                                -Kind Warning `
                                -Message "Choose a source field for '$destLabel', or switch the mapping mode to Constant Value or Skip."
                            return
                        }
                        if ($selectedStandardSource -eq 'SMOOSH') {
                            if ($canSmoosh) {
                                $cbMode.SelectedItem = 'SMOOSH'
                                $smooshValue = & $buildSmooshValue
                                if ($null -eq $smooshValue) {
                                    return
                                }

                                $form.Tag = [pscustomobject]@{
                                    Success = $true
                                    Skip    = $false
                                    Value   = $smooshValue
                                }
                                $form.Close()
                            } else {
                                Show-TransferMessage `
                                    -Title 'SMOOSH Not Supported Here' `
                                    -Kind Warning `
                                    -Message "SMOOSH can only be used for Text, RichText, or Heading destination fields."
                            }
                            return
                        }
                    }
                }

                $result = switch ($destType) {
                    'AddressData' {
                        $addressMap = @{}
                        foreach ($part in $addressParts) {
                            $addressMap[$part.Key] = @{
                                from = [string]($sourceOptionLookup[[string]$addressCombos[$part.Key].SelectedItem] ?? [string]$addressCombos[$part.Key].SelectedItem)
                            }
                        }
                        @{
                            kind      = 'mapping'
                            to        = $destLabel
                            from      = 'Meta'
                            dest_type = 'AddressData'
                            required  = $required
                            address   = $addressMap
                        }
                    }

                    'ListSelect' {
                        $listMap = @{}
                        foreach ($row in $grid.Rows) {
                            $itemName = [string]$row.Cells['ListItem'].Value
                            $whenRaw = [string]$row.Cells['WhenValues'].Value
                            $whenValues = @()

                            if (-not [string]::IsNullOrWhiteSpace($whenRaw)) {
                                $whenValues = @(
                                    $whenRaw -split ',' |
                                    ForEach-Object { $_.Trim() } |
                                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
                                )
                            }

                            $listMap[$itemName] = @{
                                whenvalues = $whenValues
                            }
                        }

                        @{
                            kind          = 'mapping'
                            to            = $destLabel
                            from          = [string]($sourceOptionLookup[[string]$cbListFrom.SelectedItem] ?? [string]$cbListFrom.SelectedItem)
                            add_listitems = [bool]$chkAddListItems.Checked
                            list_id       = $listId
                            dest_type     = 'ListSelect'
                            required      = $required
                            Mapping       = $listMap
                        }
                    }

                    default {
                        @{
                            kind      = 'mapping'
                            from      = [string]($sourceOptionLookup[[string]$cbFrom.SelectedItem] ?? [string]$cbFrom.SelectedItem)
                            to        = $destLabel
                            dest_type = $destType
                            required  = $required
                            striphtml = [bool]$chkStripHtml.Checked
                        }
                    }
                }

                $form.Tag = [pscustomobject]@{
                    Success = $true
                    Skip    = $false
                    Value   = $result
                }
                $form.Close()
            }
        }
    })

    [void]$form.ShowDialog()

    if ($null -ne $form.Tag) {
        return $form.Tag
    }

    [pscustomobject]@{
        Success = $false
        Skip    = $false
        Value   = $null
    }
}

function Show-InputPopup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Prompt,

        [string]$Title = "Input Required",

        [Parameter(Mandatory)]
        [ValidateSet("Text","Password","ListSelect","YesNo")]
        [string]$InputType,

        [string[]]$Options = @(),

        [string]$DefaultValue = ""
    )

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    if ($InputType -eq 'YesNo') {
        $result = [System.Windows.Forms.MessageBox]::Show(
            $Prompt,
            $Title,
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question
        )

        return [pscustomobject]@{
            Success = $true
            Type    = 'YesNo'
            Value   = ($result -eq [System.Windows.Forms.DialogResult]::Yes)
            Raw     = $result.ToString()
        }
    }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = $Title
    $form.Size = New-Object System.Drawing.Size(420,210)
    $form.StartPosition = 'CenterScreen'
    $form.Topmost = $true
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false

    $label = New-Object System.Windows.Forms.Label
    $label.Location = New-Object System.Drawing.Point(15,15)
    $label.MaximumSize = New-Object System.Drawing.Size(370,0)
    $label.AutoSize = $true
    $label.Text = $Prompt
    $form.Controls.Add($label)

    $inputTop = $label.Bottom + 10
    $inputControl = $null

    switch ($InputType) {
        'Text' {
            $textBox = New-Object System.Windows.Forms.TextBox
            $textBox.Location = New-Object System.Drawing.Point(15,$inputTop)
            $textBox.Size = New-Object System.Drawing.Size(370,23)
            $textBox.Text = $DefaultValue
            $form.Controls.Add($textBox)
            $inputControl = $textBox
        }

        'Password' {
            $textBox = New-Object System.Windows.Forms.TextBox
            $textBox.Location = New-Object System.Drawing.Point(15,$inputTop)
            $textBox.Size = New-Object System.Drawing.Size(370,23)
            $textBox.Text = $DefaultValue
            $textBox.UseSystemPasswordChar = $true
            $form.Controls.Add($textBox)
            $inputControl = $textBox
        }

        'ListSelect' {
            $comboBox = New-Object System.Windows.Forms.ComboBox
            $comboBox.Location = New-Object System.Drawing.Point(15,$inputTop)
            $comboBox.Size = New-Object System.Drawing.Size(370,23)
            $comboBox.DropDownStyle = 'DropDownList'

            if ($Options.Count -gt 0) {
                [void]$comboBox.Items.AddRange($Options)
            }

            if ($DefaultValue -and $comboBox.Items.Contains($DefaultValue)) {
                $comboBox.SelectedItem = $DefaultValue
            }
            elseif ($comboBox.Items.Count -gt 0) {
                $comboBox.SelectedIndex = 0
            }

            $form.Controls.Add($comboBox)
            $inputControl = $comboBox
        }
    }

    $buttonTop = $inputTop + 45
    $form.ClientSize = New-Object System.Drawing.Size(400,($buttonTop + 45))

    $okButton = New-Object System.Windows.Forms.Button
    $okButton.Location = New-Object System.Drawing.Point(220,$buttonTop)
    $okButton.Size = New-Object System.Drawing.Size(75,28)
    $okButton.Text = 'OK'
    $okButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $form.Controls.Add($okButton)

    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Location = New-Object System.Drawing.Point(310,$buttonTop)
    $cancelButton.Size = New-Object System.Drawing.Size(75,28)
    $cancelButton.Text = 'Cancel'
    $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.Controls.Add($cancelButton)

    $form.AcceptButton = $okButton
    $form.CancelButton = $cancelButton

    $result = $form.ShowDialog()

    if ($result -ne [System.Windows.Forms.DialogResult]::OK) {
        return [pscustomobject]@{
            Success = $false
            Type    = $InputType
            Value   = $null
            Raw     = 'Cancel'
        }
    }

    $value = switch ($InputType) {
        'Text'       { $inputControl.Text }
        'Password'   { $inputControl.Text }
        'ListSelect' { $inputControl.SelectedItem }
    }

    return [pscustomobject]@{
        Success = $true
        Type    = $InputType
        Value   = $value
        Raw     = $result.ToString()
    }
}

function New-GuiJob {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $state = [ordered]@{
        AssetLayouts = @()
        Job          = $null
        ApiKey       = ''
        BaseUrl      = ''
    }
    $mapfile = Join-Path $script:Root 'mapping.ps1'

    $Mainform = New-Object System.Windows.Forms.Form
    $Mainform.Text = 'Hudu Asset Layout Transfer'
    $Mainform.Size = New-Object System.Drawing.Size(1100, 760)
    $Mainform.StartPosition = 'CenterScreen'
    $font = New-Object System.Drawing.Font('Segoe UI', 9)
    $Mainform.Font = $font

    Show-TransferMessage `
        -Title 'Welcome' `
        -Kind Info `
        -Message "This wizard will help you connect to Hudu, choose a source and destination layout, and build a reusable mapping plan.`r`n`r`nNothing changes in Hudu until the final transfer step."

    $authenticated = $false

    while (-not $authenticated) {
        $urlInputResult = Show-InputPopup `
            -Prompt 'Enter the Hudu Base URL for the target environment:' `
            -Title 'Hudu Asset Layout Transfer' `
            -InputType 'Text' `
            -DefaultValue 'https://'

        if (-not $urlInputResult.Success -or [string]::IsNullOrWhiteSpace($urlInputResult.Value)) {
            throw 'Base URL is required to proceed.'
        }

        $normalizedBaseUrl = Normalize-HuduBaseUrl -Value $urlInputResult.Value
        if (-not $normalizedBaseUrl) {
            Show-TransferMessage `
                -Title 'Check The URL' `
                -Kind Warning `
                -Message 'Enter a valid Hudu URL such as https://example.huducloud.com.'
            continue
        }

        $apiKeyInputResult = Show-InputPopup `
            -Prompt 'Enter your Hudu API Key:' `
            -Title 'Hudu Asset Layout Transfer' `
            -InputType 'Password'

        if (-not $apiKeyInputResult.Success -or [string]::IsNullOrWhiteSpace($apiKeyInputResult.Value)) {
            throw 'API Key is required to proceed.'
        }

        if (-not (Test-HuduApiKeyFormat -Value $apiKeyInputResult.Value)) {
            Show-TransferMessage `
                -Title 'Check The API Key' `
                -Kind Warning `
                -Message 'Hudu API keys should be 24 characters long. Double-check the key and try again.'
            continue
        }

        try {
            Get-HuduModule
            Set-HuduInstance -HuduBaseURL $normalizedBaseUrl -HuduAPIKey $apiKeyInputResult.Value

            $state.BaseUrl = $normalizedBaseUrl
            $state.ApiKey  = $apiKeyInputResult.Value
            $authenticated = $true
        }
        catch {
            Show-TransferMessage `
                -Title 'Authentication Failed' `
                -Kind Error `
                -Message "Authentication failed. Please try again.`r`n`r`n$($_.Exception.Message)" | Out-Null
        }
    }

    $state.AssetLayouts = @(Get-HuduAssetLayouts)
    if (-not $state.AssetLayouts -or $state.AssetLayouts.Count -eq 0) {
        throw 'No asset layouts were found.'
    }

    $layoutChoiceValid = $false
    $sourceLayout = $null
    $destLayout = $null

    while (-not $layoutChoiceValid) {
        $sourceLookup = [ordered]@{}
        $sourceOptions = foreach ($layout in $state.AssetLayouts) {
            $label = Get-LayoutChoiceLabel -Layout $layout
            $sourceLookup[$label] = $layout
            $label
        }

        $sourceSelection = Show-InputPopup `
            -Prompt 'Select the source asset layout to transfer from:' `
            -Title 'Hudu Asset Layout Transfer' `
            -InputType 'ListSelect' `
            -Options $sourceOptions

        if (-not $sourceSelection.Success -or [string]::IsNullOrWhiteSpace($sourceSelection.Value)) {
            throw 'Source layout selection is required.'
        }

        $sourceLayout = $sourceLookup[[string]$sourceSelection.Value]

        $destLookup = [ordered]@{}
        $destOptions = foreach ($layout in ($state.AssetLayouts | Where-Object { $_.id -ne $sourceLayout.id })) {
            $label = Get-LayoutChoiceLabel -Layout $layout
            $destLookup[$label] = $layout
            $label
        }

        if (-not $destOptions -or $destOptions.Count -eq 0) {
            throw 'No valid destination layouts are available.'
        }

        $destSelection = Show-InputPopup `
            -Prompt 'Select the destination asset layout to transfer to:' `
            -Title 'Hudu Asset Layout Transfer' `
            -InputType 'ListSelect' `
            -Options $destOptions

        if (-not $destSelection.Success -or [string]::IsNullOrWhiteSpace($destSelection.Value)) {
            throw 'Destination layout selection is required.'
        }

        $destLayout = $destLookup[[string]$destSelection.Value]

        $layoutChoiceValid = ($null -ne $sourceLayout -and $null -ne $destLayout)

        if (-not $layoutChoiceValid) {
            Show-TransferMessage `
                -Title 'Invalid Selection' `
                -Kind Warning `
                -Message 'Invalid layout selection. Please try again.' | Out-Null
            continue
        }

        $selectionResult = Show-TransferMessage `
            -Title 'Confirm Layout Pair' `
            -Kind Question `
            -YesNo `
            -Message ("Source:`r`n{0}`r`n`r`nDestination:`r`n{1}`r`n`r`nNext, you'll review each destination field and choose how it should be filled. Continue with this layout pair?" -f (Get-LayoutChoiceLabel -Layout $sourceLayout), (Get-LayoutChoiceLabel -Layout $destLayout))

        if ($selectionResult -ne [System.Windows.Forms.DialogResult]::Yes) {
            $layoutChoiceValid = $false
        }
    }

    $layoutToLayoutDirectPossible = $true
    $DirectTransferWanted = $false
    foreach ($field in $sourceLayout.fields) {
        $directMatch = $destLayout.fields | Where-Object {
            $_.label -eq $field.label -and $_.field_type -eq $field.field_type
        } | Select-Object -First 1

        if (-not $directMatch) {
            $layoutToLayoutDirectPossible = $false
            break
        }
    }

    if ($layoutToLayoutDirectPossible) {
        $directTransferResult = Show-InputPopup `
            -Title 'Direct Transfer Possible Without Custom Mapping' `
            -inputType 'YesNo' `
            -Prompt "The source and destination layouts have matching fields that would allow for a direct transfer without field-by-field mapping.`r`nDo you want to proceed with a direct transfer?`r`nFor cases like this, it is reccomended."
        $DirectTransferWanted = if ($directTransferResult.Success) { [bool]($directTransferResult.Value) } else { $false }
    }
    if ($DirectTransferWanted) {
        $confirmed = Show-TransferReviewDialog -SummaryText "Transferring $($sourceLayout.name) to $($destLayout.name) with direct field mapping. Start Now?"
        if ($confirmed) {
            $L2Lresults = layout2layout -sourceLayoutName $sourceLayout.name -targetLayoutName $destLayout.name
            $L2Lresults | convertto-json -depth 99 | Out-File -FilePath (Join-Path $script:Root "layout2layout_$(Get-Date -Format 'yyyyMMdd_HHmmss').json") -Encoding utf8
            exit 0
        } else {
            Write-Verbose "Proceeding to custom-mapping workflow per user choice, even though a direct layout-to-layout transfer is possible."
        }
    }


    $mergeOptsResult = Show-InputPopup `
        -Prompt ("If an asset from '{0}' matches an asset in '{1}', choose what should happen.`r`n`r`nMerge-Concat (recommended): keep both values where it makes sense.`r`nMerge-FillBlanks: only fill empty destination fields.`r`nMerge-PreferSource: let the source values win.`r`nSkip: leave matching assets unchanged." -f $sourceLayout.Name, $destLayout.Name) `
        -Title 'Merge Options' `
        -InputType 'ListSelect' `
        -Options @('Merge-Concat','Merge-FillBlanks','Merge-PreferSource','Skip') `
        -DefaultValue 'Merge-Concat'

    $preferredMergeOption = if ($mergeOptsResult.Success) { [string]$mergeOptsResult.Value } else { "Merge-Concat" }

    $sourceLayoutRenameResult = Show-InputPopup `
        -Prompt "Optional: enter a new name for the source layout before transfer. Leave this blank, or cancel, to keep '$($sourceLayout.Name)'." `
        -Title 'Rename Source Layout (Optional)' `
        -InputType 'Text'

    $renameSourceLayoutto = if ($sourceLayoutRenameResult.Success -and -not [string]::IsNullOrWhiteSpace($sourceLayoutRenameResult.Value)) {
        [string]$sourceLayoutRenameResult.Value
    } else {
        $sourceLayout.Name
    }

    $ArchiveResult = Show-InputPopup `
        -Prompt "After the transfer finishes, should assets left in the source layout be archived? This is usually helpful when the old layout will no longer be used." `
        -Title 'Archive Source Layout Assets?' `
        -InputType 'YesNo'

    $archivePreference = if ($ArchiveResult.Success) { [bool]($ArchiveResult.Value) } else { $false }

    


    Show-TransferMessage `
        -Title 'Field Review' `
        -Kind Info `
        -Message ("You are about to review {0} destination fields for '{1}'.`r`n`r`nFriendly reminder:`r`n- Required fields should map to a source field or a constant value.`r`n- Skip is best reserved for optional fields.`r`n- SMOOSH is ideal for notes-style destination fields." -f @($destLayout.Fields | Where-Object { ($_.field_type ?? $_.type) -ne 'AssetTag' }).Count, $destLayout.Name)

    $mappingEntries = @()
    $constantEntries = @()
    $smooshSourceLabels = @()
    $smooshTargetEntry = $null
    $skippedFieldLabels = @()

    $sourceFieldOptions = @(
        $sourceLayout.Fields |
        Where-Object { $_.label -and ($_.field_type -ne 'AssetTag') } |
        ForEach-Object {
            [pscustomobject]@{
                label      = [string]$_.label
                field_type = [string]($_.field_type)
            }
        }
    ) + [PSCustomObject]@{
        label = "SMOOSH"
        field_type = "Pseudo [multiple source fields]"
    }
    foreach ($field in $destLayout.Fields) {
        if (($field.field_type) -ieq 'AssetTag') {
            continue
        }

        $fieldResult = Show-FieldMappingEditor `
            -DestField $field `
            -SourceFieldOptions $sourceFieldOptions `
            -ExistingSmooshLabels $(if ($null -ne $smooshTargetEntry) { @($smooshTargetEntry.to) } else { @() }) `
            -summaryLabel "Mapping for '$($field.label)' $($field.field_type) from $($sourceLayout.Name) to $($destLayout.Name)"

        if (-not $fieldResult.Success) {
            throw "User cancelled mapping."
        }

        if ($fieldResult.Skip) {
            $skippedFieldLabels += [string]$field.label
            continue
        }

        switch ($fieldResult.Value.kind) {
            'constant' {
                $constantEntries += ,$fieldResult.Value
            }
            'smoosh' {
                if ($null -ne $smooshTargetEntry -and $smooshTargetEntry.to -ne $fieldResult.Value.smooshTarget.to) {
                    throw "Only one destination field can be assigned SMOOSH."
                }
                $smooshSourceLabels = @($fieldResult.Value.smooshSourceLabels)
                $smooshTargetEntry = $fieldResult.Value.smooshTarget
            }
            default {
                $mappingEntries += ,$fieldResult.Value
            }
        }
    }

    if ($null -ne $smooshTargetEntry) {
        $mappingEntries += ,$smooshTargetEntry
    }



    $PerJobSettings = ""
    $PerJobSettingSummaries = @()

    foreach ($perjobQuestion in @(
        @{
            SettingName = 'Include Blank Values In SMOOSH?'
            VariableName = 'includeblanksduringsmoosh'
            DefaultValue = $false
            Description = "Include empty source fields when building the SMOOSH output. Leaving this off usually keeps the combined value cleaner."
            },
        @{
            SettingName = 'Include Relations For Archived Objects?'
            VariableName = 'includeRelationsForArchived'
            DefaultValue = $true
            Description = "Allow archived objects to stay related to the new asset, even if related item is Archived. Turn this off to only relate to active items."
            },
        @{
            SettingName = 'Strip HTML In SMOOSH Output?'
            VariableName = 'excludeHTMLinSMOOSH'
            DefaultValue = $false
            Description = "Remove HTML formatting when SMOOSHing into plain-text destinations. Leave this off to preserve formatting for rich-text fields."
            },
        @{
            SettingName = 'Include Field Labels In SMOOSH Values?'
            VariableName = 'includeLabelInSmooshedValues'
            DefaultValue = $true
            Description = "Prefix each SMOOSHed value with its source field label. Turn this off if you only want the raw combined values."
            })){
            if ($null -eq $smooshTargetEntry -and $perjobQuestion.SettingName -ilike '*SMOOSH*') {
                    $settingResult = [pscustomobject]@{
                        Success = $true
                        Type    = 'YesNo'
                        Value   = $perjobQuestion.DefaultValue
                        Raw     = $perjobQuestion.DefaultValue.ToString()
                    }
            } else {
                $settingResult = Show-InputPopup `
                    -Prompt ("{0}`r`n`r`nRecommended default: {1}" -f $perjobQuestion.Description, $(if ($perjobQuestion.DefaultValue) { 'Yes' } else { 'No' })) `
                    -Title "$($perjobQuestion.SettingName)" `
                    -InputType 'YesNo' 
            }
            if (-not $settingResult.Success) {
                $settingResult.Value = $perjobQuestion.DefaultValue
            }
            $PerJobSettings += '$' + $perjobQuestion.VariableName + ' = $' + $settingResult.Value + "`r`n"
            $PerJobSettingSummaries += [pscustomobject]@{
                Name  = $perjobQuestion.SettingName.TrimEnd('?')
                Value = [bool]$settingResult.Value
            }
        }



        Write-GuiMappingFile `
            -MappingEntries $mappingEntries `
            -ConstantEntries $constantEntries `
            -SmooshSourceLabels $smooshSourceLabels `
            -Path $mapfile `
            -PerJobSettings $PerJobSettings

        $reviewedFieldCount = @($destLayout.Fields | Where-Object { ($_.field_type ?? $_.type) -ne 'AssetTag' }).Count
        $configuredFieldCount = $mappingEntries.Count + $constantEntries.Count
        $skippedFieldCount = $skippedFieldLabels.Count
        $smooshTargetLabel = if ($null -ne $smooshTargetEntry) { $smooshTargetEntry.to } else { 'None' }
        $directMappingCount = $mappingEntries.Count - $(if ($null -ne $smooshTargetEntry) { 1 } else { 0 })

        Show-TransferMessage `
            -Title 'Mapping Plan Ready' `
            -Kind Info `
            -Message ("Your mapping plan has been prepared for '{0}' -> '{1}'.`r`n`r`nDirect mappings: {2}`r`nConstants: {3}`r`nSMOOSH target: {4}`r`nSMOOSH source fields: {5}`r`nSkipped fields: {6}`r`n`r`nThis is a good checkpoint to pause and sanity-check the plan before any live transfer run." -f $sourceLayout.Name, $destLayout.Name, $directMappingCount, $constantEntries.Count, $smooshTargetLabel, $smooshSourceLabels.Count, $skippedFieldCount)

        $reviewSummaryText = New-TransferReviewSummary `
            -BaseUrl $state.BaseUrl `
            -ApiKey $state.ApiKey `
            -SourceLayout $sourceLayout `
            -DestLayout $destLayout `
            -MergeOption $preferredMergeOption `
            -ArchivePreference $archivePreference `
            -RenameSourceLayoutTo $renameSourceLayoutto `
            -MappingEntries $mappingEntries `
            -ConstantEntries $constantEntries `
            -SmooshSourceLabels $smooshSourceLabels `
            -SmooshTargetEntry $smooshTargetEntry `
            -SkippedFieldLabels $skippedFieldLabels `
            -PerJobSettingSummaries $PerJobSettingSummaries `
            -MapFilePath $mapfile

        $confirmed = Show-TransferReviewDialog -SummaryText $reviewSummaryText
        if (-not $confirmed) {
            Show-TransferMessage `
                -Title 'Transfer Cancelled' `
                -Kind Warning `
                -Message 'The transfer was cancelled during final review. No changes were made.'
            return $null
        }

        return @{
            BaseUrl      = $state.BaseUrl
            ApiKey       = $state.ApiKey
            SourceLayout = $sourceLayout
            DestLayout   = $destLayout
            mapfile      = $mapfile
            preferredMergeOption = $preferredMergeOption
            MergeOptions = $preferredMergeOption
            archivePreference = $archivePreference
            ArchiveSource = $archivePreference
            RenameSourceLayout = $renameSourceLayoutto ?? $sourceLayout.name
            ReviewSummary = $reviewSummaryText
        }
}

function Invoke-Transfer {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Job
    )

    $jobFolder = Split-Path -Parent (Resolve-Path $job.mapfile).Path
    Push-Location $jobFolder
    try {
    .\Move-AssetsToNewLayout.ps1 `
        -HuduBaseURL 'YOUR_BASE_URL' `
        -HuduAPIKey 'YOUR_API_KEY' `
        -SourceLayoutId 4 `
        -DestLayoutId 2 `
        -MergeOnMatch:$true `
        -SkipOnMatch:$false `
        -MergeMode 'Merge-PreferSource' `
        -MapFile 'C:\Users\Administrator\Documents\GitHub\ITGlue-Hudu-Migration\mapping.ps1' `
        -RenameSourceLayoutTo 'lh\,' `
        -setsourceassetsarchived:$true `
        -NonInteractiveTransfer:$true `
        -ErrorAction Stop
    }
    catch {
    $_ | Format-List * -Force
    $_.Exception | Format-List * -Force
    $_.ScriptStackTrace
    read-host
    }
    
}


write-verbose "starting GUI job creation with upstream script path: $script:UpstreamScriptPath"
$job = New-GuiJob
if ($null -ne $job) {
    Invoke-Transfer -Job $job
}

read-host