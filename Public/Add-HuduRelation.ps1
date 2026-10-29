function Add-HuduRelation {
    param(
        $relation
    )

    # Loading this helper during initialization must not read logs or mark the
    # module initialized. Only look for logs when a relation is actually requested.
    $targetSources = switch ($relation.relation_type) {
        "AssetPassword" {
            @{ Variable = 'MatchedPasswords'; File = 'Passwords.json' }
            @{ Variable = 'MatchedAssetPasswords'; File = 'AssetPasswords.json' }
        }
        "Article" {
            @{ Variable = 'MatchedArticles'; File = 'Articles.json' }
        }
        "Company" {
            @{ Variable = 'MatchedCompanies'; File = 'Companies.json' }
        }
        default { Write-Warning "No matching relationship type found" }
    }
    $HuduLinkedObject = $null
    foreach ($source in $targetSources) {
        $targets = Get-Variable -Name $source.Variable -ValueOnly -ErrorAction Ignore
        if (-not $targets) {
            $logsPath = Get-Variable -Name MigrationLogs -ValueOnly -ErrorAction Ignore
            if (-not [string]::IsNullOrWhiteSpace($logsPath)) {
                $path = Join-Path $logsPath $source.File
                if (Test-Path -LiteralPath $path -PathType Leaf) {
                    $targets = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -Depth 100
                }
            }
        }
        $HuduLinkedObject = $targets | Where-Object { $_.ITGID -eq $relation.itg_to_id }
        if ($HuduLinkedObject) { break }
    }

    if ($HuduLinkedObject) {
        return (New-HuduRelation -FromableType 'Asset' -FromableID $relation.hudu_from_id -ToableType $relation.relation_type -ToableID $HuduLinkedObject.HuduID).relation
    }
}
