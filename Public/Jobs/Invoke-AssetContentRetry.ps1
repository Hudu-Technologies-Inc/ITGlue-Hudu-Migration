# Retry saved flexible asset population payloads before attachments/link rewrites.
# Read this run's log so recovery also works after restarting the migration.
$assetContentResultsPath = Join-Path $MigrationLogs 'AssetContentCommitResults.json'
if ($ImportFlexibleAssets -eq $true -and (Test-Path -LiteralPath $assetContentResultsPath -PathType Leaf)) {
    $AssetUpdateResults = @(Get-Content -LiteralPath $assetContentResultsPath -Raw -ErrorAction Stop | ConvertFrom-Json -Depth 100 | Where-Object { $_ })
    $failedAssetContentResults = @($AssetUpdateResults | Where-Object { $_.Status -ne 'updated' -or -not $_.Asset })
    $assetContentSourcesById = @{}
    foreach ($assetContentSource in @($MatchedAssets)) {
        if ($assetContentSource.HuduID) { $assetContentSourcesById[[string]$assetContentSource.HuduID] = $assetContentSource }
    }

    if ($failedAssetContentResults.Count -gt 0) {
        Write-Host "Retrying $($failedAssetContentResults.Count) failed flexible asset content update(s) before wrap-up link replacement." -ForegroundColor Cyan
        $assetContentRetryRequests = @($failedAssetContentResults | Where-Object { $_.SourceRequest } | ForEach-Object { $_.SourceRequest })
        $assetContentRetryTransportResults = [System.Collections.ArrayList]@()
        $assetContentRetryBatchError = $null
        try {
            if ($assetContentRetryRequests.Count -gt 0 -and $UseFastAssetCommit) {
                if (-not (Get-Command -Name Invoke-FastHuduAssetCommit -ErrorAction SilentlyContinue)) {
                    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'Invoke-FastAssetCommit.ps1')
                }
                $assetContentRetryParams = @{
                    AssetRequests = $assetContentRetryRequests
                    Operation     = 'Update'
                    ThrottleLimit = $MigrationParallelismLimit
                }
                if ($HuduFastCommitHeaders -and $HuduFastCommitHeaders.Count -gt 0) {
                    $assetContentRetryParams.CustomHeaders = $HuduFastCommitHeaders
                }
                Invoke-FastHuduAssetCommit @assetContentRetryParams -ErrorAction Stop | ForEach-Object {
                    $null = $assetContentRetryTransportResults.Add($_)
                }
            } else {
                foreach ($assetContentRetryRequest in $assetContentRetryRequests) {
                    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
                    $retriedAsset = $null
                    $assetContentRetryError = $null
                    try {
                        $retriedAsset = (Set-HuduAsset -Id $assetContentRetryRequest.AssetId -Name $assetContentRetryRequest.Name -CompanyId $assetContentRetryRequest.CompanyId -AssetLayoutId $assetContentRetryRequest.AssetLayoutId -Fields $assetContentRetryRequest.Fields -ErrorAction Stop).asset
                        if (-not $retriedAsset) { throw 'Hudu returned no asset for the content update.' }
                    } catch {
                        $assetContentRetryError = $_.Exception.Message
                    }
                    $stopwatch.Stop()
                    $null = $assetContentRetryTransportResults.Add([pscustomobject]@{
                        Status         = if ($retriedAsset -and -not $assetContentRetryError) { 'updated' } else { 'failed' }
                        Operation      = 'Update'
                        Index          = $assetContentRetryRequest.Index
                        AssetId        = $assetContentRetryRequest.AssetId
                        AssetName      = $assetContentRetryRequest.Name
                        CompanyId      = $assetContentRetryRequest.CompanyId
                        Asset          = $retriedAsset
                        SourceRequest  = $assetContentRetryRequest
                        Attempts       = 1
                        SleptSeconds   = 0
                        ElapsedSeconds = [math]::Round($stopwatch.Elapsed.TotalSeconds, 3)
                        StatusCode     = $null
                        Error          = $assetContentRetryError
                    })
                }
            }
        } catch {
            $assetContentRetryBatchError = $_.Exception.Message
            Write-Warning "Flexible asset content retry batch failed: $assetContentRetryBatchError"
        }

        $assetContentRetryResultsByIndex = @{}
        foreach ($assetContentRetryResult in $assetContentRetryTransportResults) {
            $assetContentRetryResultsByIndex[[string]$assetContentRetryResult.Index] = $assetContentRetryResult
        }
        $AssetContentRetryResults = @(foreach ($initialAssetContentResult in $failedAssetContentResults) {
            $assetContentRetryResult = $assetContentRetryResultsByIndex[[string]$initialAssetContentResult.Index]
            if (-not $initialAssetContentResult.SourceRequest -or -not $assetContentRetryResult) {
                $retryError = if (-not $initialAssetContentResult.SourceRequest) {
                    'The saved content update has no SourceRequest payload to retry.'
                } elseif ($assetContentRetryBatchError) {
                    $assetContentRetryBatchError
                } else {
                    'No asset content retry result was returned.'
                }
                $assetContentRetryResult = [pscustomobject]@{
                    Status        = 'failed'
                    Operation     = 'Update'
                    Index         = $initialAssetContentResult.Index
                    AssetId       = $initialAssetContentResult.AssetId
                    AssetName     = $initialAssetContentResult.AssetName
                    CompanyId     = $initialAssetContentResult.CompanyId
                    Asset         = $null
                    SourceRequest = $initialAssetContentResult.SourceRequest
                    Attempts      = 0
                    StatusCode    = $null
                    Error         = $retryError
                }
            }
            if ($assetContentRetryResult.Status -eq 'updated' -and -not $assetContentRetryResult.Asset) {
                $assetContentRetryResult.Status = 'failed'
                $assetContentRetryResult | Add-Member -NotePropertyName Error -NotePropertyValue 'Hudu returned no asset for the content update.' -Force
            }
            $assetContentRetryResult | Add-Member -NotePropertyName InitialError -NotePropertyValue $initialAssetContentResult.Error -Force
            $assetContentRetryResult | Add-Member -NotePropertyName InitialStatusCode -NotePropertyValue $initialAssetContentResult.StatusCode -Force
            $assetContentRetryResultsByIndex[[string]$initialAssetContentResult.Index] = $assetContentRetryResult
            $assetContentSource = $assetContentSourcesById[[string]$initialAssetContentResult.AssetId]
            if ($assetContentSource) {
                if ($assetContentRetryResult.Status -eq 'updated' -and $assetContentRetryResult.Asset) {
                    $assetContentSource.HuduObject = $assetContentRetryResult.Asset
                    $assetContentSource.Imported = 'Created-By-Script'
                } else {
                    $assetContentSource.Imported = 'Update-Failed'
                }
            }
            $assetContentRetryResult
        })
        $AssetUpdateResults = @($AssetUpdateResults | ForEach-Object {
            if ($assetContentRetryResultsByIndex.ContainsKey([string]$_.Index)) { $assetContentRetryResultsByIndex[[string]$_.Index] } else { $_ }
        })
        ConvertTo-Json -InputObject $AssetContentRetryResults -Depth 75 | Out-File (Join-Path $MigrationLogs 'AssetContentCommitRetryResults.json') -Encoding utf8
        ConvertTo-Json -InputObject $AssetUpdateResults -Depth 75 | Out-File $assetContentResultsPath -Encoding utf8
        $MatchedAssets | ConvertTo-Json -Depth 100 | Out-File (Join-Path $MigrationLogs 'Assets.json') -Encoding utf8
        $assetContentRecovered = @($AssetContentRetryResults | Where-Object { $_.Status -eq 'updated' -and $_.Asset }).Count
        Write-Host "Flexible asset content retry complete: $assetContentRecovered recovered, $($failedAssetContentResults.Count - $assetContentRecovered) still failed." -ForegroundColor Cyan
    }

    # Replace only entries generated here, so another resume removes resolved
    # failures without duplicating persistent failures or unrelated field actions.
    $ManualActions = [System.Collections.ArrayList]@($ManualActions | Where-Object { $_ -and $_.ManualActionKey -notlike 'AssetContentCommit:*' })
    foreach ($assetContentFailure in @($AssetUpdateResults | Where-Object { $_.Status -ne 'updated' -or -not $_.Asset })) {
        $assetContentRequest = $assetContentFailure.SourceRequest
        $assetContentSource = $assetContentSourcesById[[string]$assetContentFailure.AssetId] ?? $assetContentRequest.SourceAsset
        $null = $ManualActions.Add([pscustomobject]@{
            ManualActionKey = "AssetContentCommit:$($assetContentFailure.AssetId)"
            Document_Name   = $assetContentFailure.AssetName ?? $assetContentRequest.Name ?? $assetContentSource.Name
            Type            = 'Flexible Asset - Content Update'
            Company_Name    = $assetContentSource.HuduObject.company_name ?? $assetContentSource.ITGObject.attributes.'organization-name' ?? [string]$assetContentFailure.CompanyId
            HuduID          = $assetContentFailure.AssetId
            Field_Name      = 'All prepared fields'
            Notes           = 'Flexible asset field population still failed after the wrap-up retry.'
            Action          = 'Review the error and apply the saved SourceRequest payload from AssetContentCommitResults.json.'
            Data            = "Error: $($assetContentFailure.Error)`nHTTP status: $($assetContentFailure.StatusCode)`nPayload: AssetContentCommitResults.json; asset ID $($assetContentFailure.AssetId); index $($assetContentFailure.Index)"
            Hudu_URL        = $assetContentSource.HuduObject.url
            ITG_URL         = $assetContentSource.ITGObject.attributes.'resource-url'
        })
    }
    $ManualActions | ConvertTo-Json -Depth 100 | Out-File (Join-Path $MigrationLogs 'ManualActions.json') -Encoding utf8
}
