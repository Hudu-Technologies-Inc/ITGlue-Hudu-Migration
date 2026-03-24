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
'@ + @"
$PerJobSettings
"@
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

    [System.Windows.Forms.MessageBox]::Show(
        $Message,
        $Title,
        $buttons,
        $icon
    )
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
    $form.Size = New-Object System.Drawing.Size(420,190)
    $form.StartPosition = 'CenterScreen'
    $form.Topmost = $true
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false

    $label = New-Object System.Windows.Forms.Label
    $label.Location = New-Object System.Drawing.Point(15,15)
    $label.Size = New-Object System.Drawing.Size(370,20)
    $label.Text = $Prompt
    $form.Controls.Add($label)

    $inputControl = $null

    switch ($InputType) {
        'Text' {
            $textBox = New-Object System.Windows.Forms.TextBox
            $textBox.Location = New-Object System.Drawing.Point(15,45)
            $textBox.Size = New-Object System.Drawing.Size(370,23)
            $textBox.Text = $DefaultValue
            $form.Controls.Add($textBox)
            $inputControl = $textBox
        }

        'Password' {
            $textBox = New-Object System.Windows.Forms.TextBox
            $textBox.Location = New-Object System.Drawing.Point(15,45)
            $textBox.Size = New-Object System.Drawing.Size(370,23)
            $textBox.Text = $DefaultValue
            $textBox.UseSystemPasswordChar = $true
            $form.Controls.Add($textBox)
            $inputControl = $textBox
        }

        'ListSelect' {
            $comboBox = New-Object System.Windows.Forms.ComboBox
            $comboBox.Location = New-Object System.Drawing.Point(15,45)
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

    $okButton = New-Object System.Windows.Forms.Button
    $okButton.Location = New-Object System.Drawing.Point(220,90)
    $okButton.Size = New-Object System.Drawing.Size(75,28)
    $okButton.Text = 'OK'
    $okButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $form.Controls.Add($okButton)

    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Location = New-Object System.Drawing.Point(310,90)
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
    $mapfile = Join-Path $script:Root 'field_mapping.psd1'

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

    $mergeOptsResult = Show-InputPopup `
        -Prompt "If an asset from '$($sourceLayout.Name)' matches an asset in '$($destLayout.Name)', how should it be handled?`r`nMerge-Concat is generally best if you're unsure." `
        -Title 'Merge-Options' `
        -InputType 'ListSelect' `
        -Options @("Merge-FillBlanks','Merge-PreferSource','Merge-Concat","Skip")

    $preferredMergeOption = if ($mergeOptsResult.Success) { [string]$mergeOptsResult.Value } else { "Merge-Concat" }

    $sourceLayoutRenameResult = Show-InputPopup `
        -Prompt "Do you want to rename the source layout $($sourceLayout.name) during transfer? This can help differentiate it from the destination layout after transfer, but is optional." `
        -Title 'Source Layout Renaming - skip or cancel to keep the current name' `
        -InputType 'Text'

    $renameSourceLayoutto = if ($sourceLayoutRenameResult.Success -and -not [string]::IsNullOrWhiteSpace($sourceLayoutRenameResult.Value)) {
        [string]$sourceLayoutRenameResult.Value
    } else {
        $sourceLayout.Name
    }

    $ArchiveResult = Show-InputPopup `
        -Prompt "Do you want to archive assets in the source layout after transfer? Archiving can help prevent confusion and duplicates, but is optional and can be done manually later if desired." `
        -Title 'Archive Stale Source Assets After Migrating?' `
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

    foreach ($perjobQuestion in @(
        @{
            SettingName = 'Include blank values during SMOOSH'
            VariableName = 'includeblanksduringsmoosh'
            DefaultValue = $false
            Description = "If enabled, source fields that are blank/empty will still be included in the smooshing process. If disabled
            (blank values are excluded), then only source fields with actual content will be combined into the destination field. This can help reduce clutter in the destination field when many source fields are optional or frequently empty."
            },
        @{
            SettingName = 'Include relations for archived objects'
            VariableName = 'includeRelationsForArchived'
            DefaultValue = $true
            Description = "If enabled, archived objects will be related to the new asset/object during the smooshing process. If disabled, archived objects will be ignored."
            },
        @{
            SettingName = 'Exclude / Strip HTML in SMOOSH'
            VariableName = 'excludeHTMLinSMOOSH'
            DefaultValue = $false
            Description = "If enabled, HTML content will be stripped when smooshing to a plaintext field. If disabled, HTML content will be preserved in richtext fields."
            },
        @{
            SettingName = 'Include label in SMOOSHed values'
            VariableName = 'includeLabelInSmooshedValues'
            DefaultValue = $true
            Description = "If enabled, the label of each source field will be included in the SMOOSHed values. If disabled, only the values will be included."
            })){
            $settingResult = Show-InputPopup `
                -Prompt "$($perjobQuestion.Description) (default value is $($perjobQuestion.DefaultValue))" `
                -Title "$($perjobQuestion.SettingName)" `
                -InputType 'YesNo' 
            if (-not $settingResult.Success) {
                $settingResult.Value = $perjobQuestion.DefaultValue
            }
            $PerJobSettings += '$' + $perjobQuestion.VariableName + ' = ' + $settingResult.Value + "`r`n"
        }



        Write-GuiMappingFile `
            -MappingEntries $mappingEntries `
            -ConstantEntries $constantEntries `
            -SmooshSourceLabels $smooshSourceLabels `
            -Path $mapfile `
            -PerJobSettings $PerJobSettings

        $reviewedFieldCount = @($destLayout.Fields | Where-Object { ($_.field_type ?? $_.type) -ne 'AssetTag' }).Count
        $configuredFieldCount = $mappingEntries.Count + $constantEntries.Count
        $skippedFieldCount = [Math]::Max(0, $reviewedFieldCount - $configuredFieldCount)
        $smooshTargetLabel = if ($null -ne $smooshTargetEntry) { $smooshTargetEntry.to } else { 'None' }
        $directMappingCount = $mappingEntries.Count - $(if ($null -ne $smooshTargetEntry) { 1 } else { 0 })

        Show-TransferMessage `
            -Title 'Mapping Plan Ready' `
            -Kind Info `
            -Message ("Your mapping plan has been prepared for '{0}' -> '{1}'.`r`n`r`nDirect mappings: {2}`r`nConstants: {3}`r`nSMOOSH target: {4}`r`nSMOOSH source fields: {5}`r`nSkipped fields: {6}`r`n`r`nThis is a good checkpoint to pause and sanity-check the plan before any live transfer run." -f $sourceLayout.Name, $destLayout.Name, $directMappingCount, $constantEntries.Count, $smooshTargetLabel, $smooshSourceLabels.Count, $skippedFieldCount)
        

        $state.Job = [pscustomobject]@{
            BaseUrl      = $state.BaseUrl
            ApiKey       = $state.ApiKey
            SourceLayout = $sourceLayout
            DestLayout   = $destLayout
            mapfile      = $mapfile
            MergeOptions = $preferredMergeOption
            ArchiveSource = $archivePreference
            RenameSourceLayout = $renameSourceLayoutto ?? $sourceLayout.name
        }
    

        return $state.Job
    
}

function Invoke-Transfer {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Job
    )
    $jobFolder = Split-Path -Parent (resolve-path $job.mapfile).Path
    set-location $jobFolder
    try {
        $invokeParams = @{
            HuduBaseURL = $Job.BaseUrl
            HuduAPIKey = $job.APIkey
            SourceLayoutId = [int]$Job.sourceLayout.id
            DestLayoutId = [int]$Job.destLayout.id
            MergeMode = $job.preferredMergeOption ?? "Merge-Concat"
            SkipOnMatch = [bool]$($job.preferredMergeOption -eq 'Skip') ?? $false
            MapFile = $job.mapfile
            ArchiveSourceLayoutAssets = [bool]$Job.archivePreference
            newlayoutname = $job.RenameSourceLayout
            NonInteractiveTransfer = $true
        }
        write-verbose "Invoking transfer script with parameters: $($($invokeParams | convertto-json -depth 99).ToString())"

        & $script:UpstreamScriptPath @invokeParams
    }
    finally {
        Pop-Location
    }
}

write-verbose "starting GUI job creation with upstream script path: $script:UpstreamScriptPath"
$job = New-GuiJob
if ($null -ne $job) {
    write-verbose "GUI job creation completed. Job details: $($job | convertto-json -depth 99).ToString()"
    $invokeResult = Invoke-Transfer -Job $job
    write-verbose "Transfer invocation completed. Result: $($($invokeResult | convertto-json -depth 99).ToString()))"
}