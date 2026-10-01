function Find-FontAwesomeIcon {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Search,

        [string]$MetadataPath = "C:\Users\$env:USERNAME\Icons\fontawesome-free\metadata\icons.json"
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
        if ($null -eq $results){
            return "fa circle"
        } else {
            return $($results | get-random -count 1)
        }
}