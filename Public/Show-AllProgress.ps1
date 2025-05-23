

function Get-PercentDone {
    param (
        [int]$Current,
        [int]$Total
    )
    if ($Total -eq 0) {
        return 100}
    $percentDone = ($Current / $Total) * 100
    if ($percentDone -gt 100){
        return 100
    }
    $rounded = [Math]::Round($percentDone, 2)
    return $rounded
}
class ProgressItem {
    [string]$descriptor
    [int]$numerator
    [int]$denominator
    [int]$indicator_index

    ProgressItem([string]$descriptor, [int]$numerator, [int]$denominator, [int]$indicator_index) {
        $this.descriptor = $descriptor
        $this.numerator = $numerator
        $this.denominator = $denominator
        $this.indicator_index = $indicator_index
    }
}

function Show-AllProgress {
    param (
        [Parameter(Mandatory)]
        [System.Collections.Generic.List[ProgressItem]]$ProgressItems
    )

    foreach ($item in $ProgressItems) {
        Write-Progress `
            -Id $item.indicator_index `
            -Activity $item.descriptor `
            -Status "$($item.numerator) of $($item.denominator)" `
            -PercentComplete $(Get-PercentDone -Current $item.numerator -Total $item.denominator)
    }
}