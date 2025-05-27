

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

    [void]Reset([string]$withDescriptor, [int]$objectCount) {
        $this.numerator = 0
        $this.denominator = $objectCount
        $this.descriptor = $withDescriptor
    }

}

function Show-AllProgress {
    param (
        [Parameter(Mandatory)]
        [System.Collections.Generic.List[ProgressItem]]$ProgressItems
    )

    foreach ($item in $ProgressItems) {
        $completed_percent=$(Get-PercentDone -Current $item.numerator -Total $item.denominator)
        Write-Progress `
            -Id $item.indicator_index `
            -Activity $(($item.descriptor).Substring(0, [Math]::Min(30, $item.descriptor.Length)).PadRight(30)) `
            -Status "$($item.numerator) of $($item.denominator) ($completed_percent%)" `
            -PercentComplete $completed_percent
    }
}