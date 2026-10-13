write-host "wrapup 9/10... archiving items..."  -ForegroundColor DarkCyan; $null = Start-MigrationJob -Name "Wrap-Up - Archiving Items";
$DocsCsv = import-csv "$ITGlueExportPath\documents.csv"
$ArchivedPasswords = $MatchedPasswords | Where-Object {$_.itgobject.attributes.archived -eq $true}
$ArchivedConfigurations = $MatchedConfigurations | Where-Object {$_.ITGObject.attributes.archived -eq $true}
$ArchivedAssets = $MatchedAssets | Where-Object {$_.ITGObject.attributes.archived -eq $true}
$documentsForArchive =  $($matchedarticles | Where-Object {@($($($DocsCsv) | Where-Object {$_.archived -ne "No"}) | ForEach-Object {"$($_.id)"}) -contains [string]($_.ITGID)})
$standaloneImageArticlesForArchive = @($matchedarticles | Where-Object { $true -eq $_.StandaloneImageArticleArchiveOriginal })

$UseFastArchiveCommit = $UseFastArchiveCommit ?? $true
if ($UseFastArchiveCommit -and -not (Get-Command -Name Invoke-FastHuduArchiveCommit -ErrorAction SilentlyContinue)) {
    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'Invoke-FastArchiveCommit.ps1')
}

$documentsForArchiveByHuduId = [ordered]@{}
foreach ($documentForArchive in @($standaloneImageArticlesForArchive)) {
    if ($documentForArchive.huduid -and $documentForArchive.huduid -gt 0) {
        $documentsForArchiveByHuduId[[string]$documentForArchive.huduid] = [pscustomobject]@{
            Source = $documentForArchive
            Reason = 'StandaloneImagePhoto'
        }
    }
}
foreach ($documentForArchive in @($documentsForArchive)) {
    if ($documentForArchive.huduid -and $documentForArchive.huduid -gt 0 -and -not $documentsForArchiveByHuduId.Contains([string]$documentForArchive.huduid)) {
        $documentsForArchiveByHuduId[[string]$documentForArchive.huduid] = [pscustomobject]@{
            Source = $documentForArchive
            Reason = 'ITGlueArchivedDocument'
        }
    }
}

$archiveRequests = @(
    $ArchivedPasswords | Where-Object { $_.huduid -and $_.huduid -gt 0 } | ForEach-Object {
        [pscustomobject]@{ Group = 'passwords'; Type = 'AssetPassword'; Id = [int]$_.huduid; Source = $_ }
    }
    $ArchivedConfigurations | Where-Object { $_.huduid -and $_.huduid -gt 0 -and $_.huduobject.company_id } | ForEach-Object {
        [pscustomobject]@{ Group = 'configs'; Type = 'Asset'; Id = [int]$_.huduid; CompanyId = [int]$_.huduobject.company_id; Source = $_ }
    }
    $ArchivedAssets | Where-Object { $_.huduid -and $_.huduid -gt 0 -and $_.huduobject.company_id } | ForEach-Object {
        [pscustomobject]@{ Group = 'assets'; Type = 'Asset'; Id = [int]$_.huduid; CompanyId = [int]$_.huduobject.company_id; Source = $_ }
    }
    $documentsForArchiveByHuduId.Values | ForEach-Object {
        [pscustomobject]@{ Group = 'docs'; Type = 'Article'; Id = [int]$_.Source.huduid; Source = $_.Source; Reason = $_.Reason }
    }
)

$archiveCommitResults = if ($UseFastArchiveCommit) {
    $fastArchiveCommitParams = @{
        ArchiveRequests = @($archiveRequests)
        ThrottleLimit   = $MigrationParallelismLimit
    }
    if ($HuduFastCommitHeaders -and $HuduFastCommitHeaders.Count -gt 0) {
        $fastArchiveCommitParams.CustomHeaders = $HuduFastCommitHeaders
    }
    Invoke-FastHuduArchiveCommit @fastArchiveCommitParams
} else {
    foreach ($archiveRequest in @($archiveRequests)) {
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $archivedObject = switch ($archiveRequest.Type) {
                'AssetPassword' { Set-HuduPasswordArchive -id $archiveRequest.Id -Archive $true }
                'Asset' { Set-HuduAssetArchive -Id $archiveRequest.Id -CompanyId $archiveRequest.CompanyId -Archive $true }
                'Article' { Set-HuduArticleArchive -id $archiveRequest.Id -Archive $true -confirm:$false }
            }
            $stopwatch.Stop()
            [pscustomobject]@{
                Status         = if ($archivedObject) { 'archived' } else { 'skipped' }
                ArchiveRequest = $archiveRequest
                ArchivedObject = $archivedObject
                Attempts       = 1
                SleptSeconds   = 0
                ElapsedSeconds = [math]::Round($stopwatch.Elapsed.TotalSeconds, 3)
                StatusCode     = $null
            }
        } catch {
            $stopwatch.Stop()
            [pscustomobject]@{
                Status         = 'failed'
                ArchiveRequest = $archiveRequest
                ArchivedObject = $null
                Attempts       = 1
                SleptSeconds   = 0
                ElapsedSeconds = [math]::Round($stopwatch.Elapsed.TotalSeconds, 3)
                StatusCode     = $null
                Error          = $_.Exception.Message
            }
        }
    }
}

$ptaresults = @($archiveCommitResults | Where-Object { $_.ArchiveRequest.Group -eq 'passwords' -and $_.ArchivedObject } | ForEach-Object { $_.ArchivedObject })
$ctaresults = @($archiveCommitResults | Where-Object { $_.ArchiveRequest.Group -eq 'configs' -and $_.ArchivedObject } | ForEach-Object { $_.ArchivedObject })
$ataresults = @($archiveCommitResults | Where-Object { $_.ArchiveRequest.Group -eq 'assets' -and $_.ArchivedObject } | ForEach-Object { $_.ArchivedObject })
$documentArchiveResults = @($archiveCommitResults | Where-Object { $_.ArchiveRequest.Group -eq 'docs' -and $_.ArchivedObject } | ForEach-Object { $_.ArchivedObject })
$standaloneImageArticleArchiveResults = @($archiveCommitResults | Where-Object { $_.ArchiveRequest.Group -eq 'docs' -and $_.ArchiveRequest.Reason -eq 'StandaloneImagePhoto' -and $_.ArchivedObject } | ForEach-Object { $_.ArchivedObject })
$archiveCommitResults | ConvertTo-Json -Depth 75 | Out-File $(join-path $settings.MigrationLogs "archive-commit-results.json")
foreach ($obj in @(
    @{Name = "passwords";       Archived = $ptaresults ?? @() },
    @{Name = "configs";         Archived = $ctaresults ?? @() },
    @{Name = "assets";          Archived = $ataresults ?? @() },
    @{Name = "docs";            Archived = $documentArchiveResults ?? @() })) {
    $obj.Archived | ConvertTo-Json -depth 75 | Out-File $(join-path $settings.MigrationLogs "archived-$($obj.Name).json")
}
