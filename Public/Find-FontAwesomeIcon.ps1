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

    if (-not $script:FontAwesomeIconMetadataCache) {
        $script:FontAwesomeIconMetadataCache = @{}
    }

    $resolvedMetadataPath = [System.IO.Path]::GetFullPath($MetadataPath)
    $metadataCacheKey = "$resolvedMetadataPath|ranked-v2"

    if (-not $script:FontAwesomeIconMetadataCache.ContainsKey($metadataCacheKey)) {
        $icons = Get-Content -LiteralPath $MetadataPath -Raw | ConvertFrom-Json

        $script:FontAwesomeIconMetadataCache[$metadataCacheKey] = @(
            foreach ($icon in $icons.PSObject.Properties) {
                $freeStyles = @($icon.Value.free)

                if (-not $icon.Value.free -or $freeStyles.Count -eq 0) {
                    continue
                }

                $iconName = [string]$icon.Name
                $iconLabel = [string]$icon.Value.label
                $metadataTerms = @(
                    $icon.Value.search.terms |
                        Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
                        ForEach-Object { [string]$_ }
                )

                $tokens = [System.Collections.Generic.List[string]]::new()

                foreach ($value in @($iconName, $iconLabel) + $metadataTerms) {
                    if ([string]::IsNullOrWhiteSpace($value)) {
                        continue
                    }

                    $valueLower = $value.ToLowerInvariant()
                    $tokens.Add($valueLower)

                    foreach ($token in ($valueLower -split '[-_\s/]+')) {
                        if (-not [string]::IsNullOrWhiteSpace($token)) {
                            $tokens.Add($token)
                        }
                    }
                }

                $searchText = (@($iconName, $iconLabel) + $metadataTerms) -join ' '

                $styles = foreach ($style in $freeStyles) {
                    $prefix = switch ($style) {
                        'brands'  { 'fa-brands' }
                        'solid'   { 'fa-solid' }
                        'regular' { 'fa-regular' }
                        default   { "fa-$style" }
                    }

                    [PSCustomObject]@{
                        Icon    = "$prefix fa-$iconName"
                        IsBrand = $style -eq 'brands'
                    }
                }

                [PSCustomObject]@{
                    NameLower  = $iconName.ToLowerInvariant()
                    LabelLower = $iconLabel.ToLowerInvariant()
                    TermsLower = @($metadataTerms | ForEach-Object { $_.ToLowerInvariant() })
                    Tokens     = [string[]]$tokens
                    SearchText = $searchText.ToLowerInvariant()
                    Styles     = @($styles)
                }
            }
        )
    }

    $searchTerms = @(
        $Search -split '[\s_/-]+' |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { $_.Trim().ToLowerInvariant() }
    )

    if ($searchTerms.Count -eq 0) {
        return "fas fa-circle"
    }

    $iconRecords = $script:FontAwesomeIconMetadataCache[$metadataCacheKey]
    $searchPhrase = $searchTerms -join ' '
    $searchSlug = $searchTerms -join '-'
    $firstTerm = $searchTerms[0]

    $results = foreach ($icon in $iconRecords) {
        $rank = $null

        if (
            $icon.NameLower -eq $searchSlug -or
            $icon.LabelLower -eq $searchPhrase -or
            $icon.TermsLower -contains $searchPhrase -or
            $icon.TermsLower -contains $searchSlug
        ) {
            $rank = 0
        }
        elseif ($icon.Tokens -contains $firstTerm) {
            $rank = 1
        }
        elseif ($firstTerm.Length -ge 4) {
            foreach ($token in $icon.Tokens) {
                if ($token.StartsWith($firstTerm)) {
                    $rank = 2
                    break
                }
            }
        }

        if ($null -eq $rank) {
            for ($termIndex = 1; $termIndex -lt $searchTerms.Count; $termIndex++) {
                if ($icon.Tokens -contains $searchTerms[$termIndex]) {
                    $rank = 3
                    break
                }
            }
        }

        if ($null -eq $rank) {
            foreach ($term in $searchTerms) {
                if ($term.Length -lt 4) {
                    continue
                }

                foreach ($token in $icon.Tokens) {
                    if ($token.StartsWith($term)) {
                        $rank = 4
                        break
                    }
                }

                if ($null -ne $rank) {
                    break
                }
            }
        }

        if ($null -eq $rank) {
            $searchText = [string]$icon.SearchText

            if ([string]::IsNullOrWhiteSpace($searchText)) {
                continue
            }

            foreach ($term in $searchTerms) {
                if ($term.Length -ge 4 -and $searchText.IndexOf($term, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                    $rank = 5
                    break
                }
            }
        }

        if ($null -eq $rank) {
            continue
        }

        foreach ($style in $icon.Styles) {
            [PSCustomObject]@{
                Icon    = $style.Icon
                IsBrand = $style.IsBrand
                Rank    = $rank
            }
        }
    }

    if ($null -eq $results -or @($results).Count -eq 0) {
        $firstLetterOfSearch = $searchTerms[0].Substring(0, 1)
        return "fas fa-$firstLetterOfSearch"
    }

    $nonBrandResults = @($results | Where-Object { -not $_.IsBrand })

    if ($nonBrandResults.Count -gt 0) {
        $results = $nonBrandResults
    }

    $bestRank = ($results | Measure-Object -Property Rank -Minimum).Minimum
    $bestResults = @($results | Where-Object { $_.Rank -eq $bestRank } | Select-Object -ExpandProperty Icon)

    return $($bestResults | Get-Random -Count 1)
}
