function Find-FontAwesomeIcon {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Search,

        [string]$MetadataPath = (Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'icons.json')
    )

    # Download metadata only if it does not already exist
    if (-not (Test-Path -LiteralPath $MetadataPath)) {
        $metadataDirectory = Split-Path -Parent $MetadataPath

        if (-not (Test-Path -LiteralPath $metadataDirectory)) {
            New-Item -ItemType Directory -Path $metadataDirectory -Force | Out-Null
        }

        $metadataUrl = 'https://raw.githubusercontent.com/FortAwesome/Font-Awesome/7.x/metadata/icons.json'

        Write-Verbose "Downloading Font Awesome metadata from $metadataUrl"

        try {
            Invoke-WebRequest `
                -Uri $metadataUrl `
                -OutFile $MetadataPath `
                -UseBasicParsing `
                -ErrorAction Stop
        }
        catch {
            throw "Failed to download Font Awesome metadata: $($_.Exception.Message)"
        }
    }

    $icons = Get-Content -LiteralPath $MetadataPath -Raw | ConvertFrom-Json

    $searchTerms = @(
        $Search -split '[\s_-]+' |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { $_.Trim() }
    )

    $results = $icons.PSObject.Properties |
        Where-Object {
            $icon = $_

            if (-not $icon.Value.free -or $icon.Value.free.Count -eq 0) {
                return $false
            }

            $searchableText = @(
                $icon.Name
                $icon.Value.label
                $icon.Value.search.terms
            ) -join ' '

            foreach ($term in $searchTerms) {
                if ($searchableText.IndexOf(
                    $term,
                    [StringComparison]::OrdinalIgnoreCase
                ) -ge 0) {
                    return $true
                }
            }

            return $false
        } |
        ForEach-Object {

            $icon = $_

            foreach ($style in $icon.Value.free) {

                $prefix = switch ($style) {
                    'brands'  { 'fa-brands' }
                    'solid'   { 'fa-solid' }
                    'regular' { 'fa-regular' }
                    default   { "fa-$style" }
                }

                "$prefix fa-$($icon.Name)"
            }
        } 
        if ($null -eq $results -or @($results).Count -eq 0){
            if ([string]::IsNullOrWhiteSpace($Search) -or $searchTerms.Count -eq 0) {
                return "fas fa-circle"
            }

            $firstLetterOfSearch = $searchTerms[0].Substring(0, 1).ToLowerInvariant()
            return "fas fa-$firstLetterOfSearch"
        } else {
            $nonBrandResults = @($results | Where-Object { $_ -notlike 'fa-brands *' })

            if ($nonBrandResults.Count -gt 0) {
                return $($nonBrandResults | Get-Random -Count 1)
            }

            return $($results | Get-Random -Count 1)
        }
}
