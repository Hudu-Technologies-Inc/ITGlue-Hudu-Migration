# Reads $ITGLocationsHashTable at call time, after location mappings are populated.
function Get-HuduLocationAssetTagValue {
    param(
        [AllowNull()]
        $ITGLocationId
    )

    if ([string]::IsNullOrWhiteSpace([string]$ITGLocationId)) {
        return $null
    }

    $matchedLocation = $ITGLocationsHashTable["$ITGLocationId"]
    if ($null -eq $matchedLocation) {
        return $null
    }

    $huduLocationId = $matchedLocation.HuduID ?? $matchedLocation.id
    if ([string]::IsNullOrWhiteSpace([string]$huduLocationId)) {
        return $null
    }

    $locationName = $matchedLocation.Name ?? $matchedLocation.name
    return @([pscustomobject]@{
        id   = $huduLocationId
        name = $locationName
    }) | ConvertTo-Json -AsArray -Compress | Out-String
}
