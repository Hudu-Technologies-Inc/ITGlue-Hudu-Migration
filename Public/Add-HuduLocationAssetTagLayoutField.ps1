# Reads the current $LocationLayout and updates the caller's fields by reference.
function Add-HuduLocationAssetTagLayoutField {
    param(
        [Parameter(Mandatory)]
        [ref]$AssetLayoutFields,

        [Parameter(Mandatory)]
        [int]$Position,

        [Parameter(Mandatory)]
        [string]$LayoutName
    )

    if ($null -eq $LocationLayout -or [string]::IsNullOrWhiteSpace([string]$LocationLayout.ID)) {
        Write-Host "Skipping Location AssetTag field in $LayoutName because no Hudu location layout was found." -ForegroundColor Yellow
        return $false
    }

    $AssetLayoutFields.Value += @{
        label        = 'Location'
        field_type   = 'AssetTag'
        show_in_list = 'false'
        linkable_id  = $LocationLayout.ID
        position     = $Position
    }
    return $true
}
