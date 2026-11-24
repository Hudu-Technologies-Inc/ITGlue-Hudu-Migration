#requires -Version 7.2
# Offline saved-payload recovery, final manual actions, and transport failures.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
. "$repoRoot/Public/Invoke-FastAssetCommit.ps1"
. "$repoRoot/Public/Normalize-String.ps1"
$checks = 0
function Assert-AssetRetry {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    $script:checks++
}
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) "itglue-asset-retry-$([guid]::NewGuid().ToString('N'))"
try {
    $MigrationLogs = $fixtureRoot
    $null = [IO.Directory]::CreateDirectory($MigrationLogs)
    $resultPath = Join-Path $MigrationLogs 'AssetContentCommitResults.json'
    $retryPath = Join-Path $MigrationLogs 'AssetContentCommitRetryResults.json'
    $manualPath = Join-Path $MigrationLogs 'ManualActions.json'
    $UseFastAssetCommit = $true
    $ImportFlexibleAssets = $true
    $MigrationParallelismLimit = 7
    $HuduFastCommitHeaders = @{ 'X-Test' = 'offline' }
    $HuduBaseDomain = 'https://hudu.invalid'
    $wireCalls = [Collections.Generic.List[object]]::new()
    $slowCalls = [Collections.Generic.List[object]]::new()
    $mode = 'mixed'
    function New-RetryAsset {
        param($Id, $Fields = @())
        [pscustomobject]@{ id = $Id; name = "Asset $Id"; company_id = 44; asset_layout_id = 55; company_name = 'Offline company'; fields = $Fields; url = "/assets/$Id" }
    }
    function Invoke-FastHuduRequestBatch {
        [CmdletBinding()]
        param($Requests, $ThrottleLimit, $MaxRetries, $CustomHeaders)
        Assert-AssetRetry ($ThrottleLimit -eq 7 -and $CustomHeaders['X-Test'] -eq 'offline') 'Retry lost concurrency or custom headers.'
        foreach ($request in $Requests) { $wireCalls.Add($request) }
        if ($mode -eq 'batch-error') { throw 'Simulated batch transport failure' }
        # Deliberately return out of order; index identity must remain intact.
        foreach ($request in @($Requests | Sort-Object { $_.SourceRequest.Index } -Descending)) {
            $id = $request.SourceRequest.AssetId
            if ($mode -eq 'mixed' -and $id -eq 405) { continue }
            $failed = $mode -eq 'mixed' -and $id -eq 403
            $response = if ($mode -eq 'mixed' -and $id -eq 404) { $null } else { @{ asset = (New-RetryAsset $id @(@{ label = 'notes'; value = '<p>Recovered field</p>' })) } }
            [pscustomobject]@{
                Status = if ($failed) { 'failed' } else { 'succeeded' }
                SourceRequest = $request.SourceRequest; Response = $response
                Attempts = 2; SleptSeconds = 5; ElapsedSeconds = 0.1
                StatusCode = if ($failed) { 422 } else { 200 }
                Error = if ($failed) { 'Invalid field <value> & value' } else { $null }
            }
        }
    }
    function Set-HuduAsset {
        [CmdletBinding()]
        param($Id, $Name, $CompanyId, $AssetLayoutId, $Fields)
        $slowCalls.Add(@{ Id = $Id; Name = $Name; CompanyId = $CompanyId; AssetLayoutId = $AssetLayoutId; Fields = $Fields })
        if ($Id -eq 403) { Write-Error 'Simulated nonterminating module error'; return }
        if ($Id -eq 404) { return @{} }
        @{ asset = (New-RetryAsset $Id) }
    }
    $MatchedAssets = @(foreach ($id in 401..406) {
        [pscustomobject]@{
            HuduID = $id; ITGID = $id + 1000; Name = "Asset $id"
            HuduObject = New-RetryAsset $id
            ITGObject = @{ attributes = @{ 'resource-url' = "https://itglue.invalid/44/assets/$($id + 1000)"; 'organization-name' = 'Offline company' } }
            Imported = if ($id -eq 401) { 'Created-By-Script' } else { 'Update-Failed' }
        }
    })
    $initialResults = @(foreach ($asset in $MatchedAssets) {
        $request = if ($asset.HuduID -ne 406) {
            [pscustomobject]@{
                Index = $asset.HuduID - 401; AssetId = $asset.HuduID; Name = $asset.Name
                CompanyId = 44; AssetLayoutId = 55; SourceAsset = $asset
                Fields = @(@{ notes = '<p>Original 文档 &amp; <a href="/44/docs/1">link</a></p>' }, @{ exact_number = '0.123456789012345678901234567890' }, @{ tags = @('one', 'two') })
            }
        }
        [pscustomobject]@{
            Status = if ($asset.HuduID -eq 401) { 'updated' } else { 'failed' }
            Operation = 'Update'; Index = $asset.HuduID - 401; AssetId = $asset.HuduID; AssetName = $asset.Name; CompanyId = 44
            Asset = if ($asset.HuduID -eq 401) { $asset.HuduObject } else { $null }
            SourceRequest = $request; Attempts = 2; StatusCode = if ($asset.HuduID -eq 401) { 200 } else { 503 }
            Error = if ($asset.HuduID -eq 401) { $null } else { 'Initial failure' }
        }
    })
    ConvertTo-Json -InputObject $initialResults -Depth 75 | Set-Content -LiteralPath $resultPath
    $ManualActions = [Collections.ArrayList]@(
        [pscustomobject]@{ Type = 'Number field'; HuduID = 402; Document_Name = 'Preserve unrelated action'; Company_Name = 'Offline company'; Field_Name = 'seats'; Notes = 'Invalid number'; Action = 'Review'; Data = 'original'; Hudu_URL = '/assets/402'; ITG_URL = '' },
        [pscustomobject]@{ ManualActionKey = 'AssetContentCommit:402'; Type = 'Flexible Asset - Content Update' },
        [pscustomobject]@{ ManualActionKey = 'AssetContentCommit:403'; Type = 'Flexible Asset - Content Update' }
    )
    # Run in the migration's normal (non-strict) caller context.
    try { Set-StrictMode -Off; . "$repoRoot/Public/Jobs/Invoke-AssetContentRetry.ps1" 6>$null }
    finally { Set-StrictMode -Version Latest }
    Assert-AssetRetry (($wireCalls.SourceRequest.AssetId | Sort-Object) -join ',' -eq '402,403,404,405') 'Retry replayed successes or lost failed payloads.'
    foreach ($call in $wireCalls) {
        $body = $call.Body | ConvertFrom-Json
        Assert-AssetRetry ($call.Method -eq 'PUT' -and $call.Resource -eq "/api/v1/companies/44/assets/$($call.SourceRequest.AssetId)") 'Recovery attempted to create an asset or targeted the wrong company/asset.'
        Assert-AssetRetry ($body.asset.custom_fields[0].notes -ceq $initialResults[1].SourceRequest.Fields[0].notes -and $body.asset.custom_fields[1].exact_number -ceq '0.123456789012345678901234567890' -and ($body.asset.custom_fields[2].tags -join ',') -eq 'one,two') 'A saved update payload changed during retry.'
    }
    Assert-AssetRetry ($MatchedAssets[1].Imported -eq 'Created-By-Script' -and $MatchedAssets[1].HuduObject.fields[0].value -eq '<p>Recovered field</p>') 'Recovered fields did not reach the live asset used by later wrap-up phases.'
    Assert-AssetRetry ($MatchedAssets[0].HuduObject.fields.Count -eq 0 -and $MatchedAssets[0].Imported -eq 'Created-By-Script') 'Recovery changed an initially successful asset.'
    $saved = @(Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json)
    $retried = @(Get-Content -LiteralPath $retryPath -Raw | ConvertFrom-Json)
    Assert-AssetRetry ($saved.Count -eq 6 -and @($saved | Where-Object Status -eq 'updated').Count -eq 2 -and $retried.Count -eq 5) 'Retry/final result snapshots lost outcomes.'
    Assert-AssetRetry ($retried[0].InitialError -eq 'Initial failure' -and $retried[0].InitialStatusCode -eq 503) 'Retry audit lost the previous failure.'
    Assert-AssetRetry ($saved[3].Status -eq 'failed' -and $saved[3].Error -like '*no asset*' -and $saved[4].Error -like '*No asset content retry result*' -and $saved[5].Error -like '*no SourceRequest*') 'Empty responses, missing results, or missing payloads were accepted.'
    $actions = @($ManualActions | Where-Object Type -eq 'Flexible Asset - Content Update')
    Assert-AssetRetry (($actions.HuduID -join ',') -eq '403,404,405,406' -and $ManualActions.Count -eq 5) 'Final manual actions duplicated failures, included recovered assets, or removed unrelated actions.'
    Assert-AssetRetry ($actions[0].Data -like '*Invalid field <value> & value*' -and $actions[0].Data -like '*HTTP status: 422*' -and $actions[0].Data -like '*AssetContentCommitResults.json*' -and $actions[0].Hudu_URL -eq '/assets/403' -and $actions[0].ITG_URL -eq 'https://itglue.invalid/44/assets/1403') 'Manual actions lost the error, payload reference, or source/destination links.'
    Assert-AssetRetry (@(Get-Content -LiteralPath $manualPath -Raw | ConvertFrom-Json).Count -eq 5) 'Final manual actions were not persisted.'
    $reportPath = Join-Path $MigrationLogs 'ManualActions.html'
    try { Set-StrictMode -Off; Format-ManualActionsReport -ManualActions $ManualActions -OutputPath $reportPath -Summary 'Offline retry verification' 6>$null }
    finally { Set-StrictMode -Version Latest }
    $report = Get-Content -LiteralPath $reportPath -Raw
    Assert-AssetRetry ($report -like '*Flexible Asset - Content Update*' -and $report -like '*Invalid field &lt;value&gt; &amp; value*') 'Persistent failures did not appear safely in the actual manual-actions HTML.'

    # Restart from persisted state, with more failures now recoverable.
    $MatchedAssets = @(Get-Content -LiteralPath (Join-Path $MigrationLogs 'Assets.json') -Raw | ConvertFrom-Json)
    $ManualActions = [Collections.ArrayList]@(Get-Content -LiteralPath $manualPath -Raw | ConvertFrom-Json)
    $mode = 'recover'
    $wireCalls.Clear()
    try { Set-StrictMode -Off; . "$repoRoot/Public/Jobs/Invoke-AssetContentRetry.ps1" 6>$null }
    finally { Set-StrictMode -Version Latest }
    Assert-AssetRetry (($wireCalls.SourceRequest.AssetId | Sort-Object) -join ',' -eq '403,404,405') 'A resumed retry replayed successful assets or needed in-memory payloads.'
    Assert-AssetRetry ($ManualActions.Count -eq 2 -and $ManualActions[0].Type -eq 'Number field' -and $ManualActions[1].HuduID -eq 406) 'Resume left stale manual actions after successful recovery.'
    Assert-AssetRetry (@($MatchedAssets | Where-Object Imported -eq 'Created-By-Script').Count -eq 5) 'Recovered states were not persisted across a restart.'

    # Complete, disabled, and absent-log runs must not make any API requests.
    ConvertTo-Json -InputObject @($initialResults[0]) -Depth 75 | Set-Content -LiteralPath $resultPath
    $wireCalls.Clear()
    try { Set-StrictMode -Off; . "$repoRoot/Public/Jobs/Invoke-AssetContentRetry.ps1" 6>$null }
    finally { Set-StrictMode -Version Latest }
    Assert-AssetRetry ($wireCalls.Count -eq 0 -and $ManualActions.Count -eq 1) 'An all-success run retried assets or kept obsolete failure actions.'
    ConvertTo-Json -InputObject @($initialResults[1]) -Depth 75 | Set-Content -LiteralPath $resultPath
    $ImportFlexibleAssets = $false
    try { Set-StrictMode -Off; . "$repoRoot/Public/Jobs/Invoke-AssetContentRetry.ps1" 6>$null }
    finally { Set-StrictMode -Version Latest }
    [IO.File]::Delete($resultPath)
    $ImportFlexibleAssets = $true
    try { Set-StrictMode -Off; . "$repoRoot/Public/Jobs/Invoke-AssetContentRetry.ps1" 6>$null }
    finally { Set-StrictMode -Version Latest }
    Assert-AssetRetry ($wireCalls.Count -eq 0 -and $ManualActions.Count -eq 1) 'Disabled or absent-log recovery made API calls or changed unrelated actions.'

    # A batch exception must become a tracked failure for every pending payload.
    ConvertTo-Json -InputObject @($initialResults[1], $initialResults[2]) -Depth 75 | Set-Content -LiteralPath $resultPath
    $mode = 'batch-error'
    try { Set-StrictMode -Off; . "$repoRoot/Public/Jobs/Invoke-AssetContentRetry.ps1" 3>$null 6>$null }
    finally { Set-StrictMode -Version Latest }
    $saved = @(Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json)
    Assert-AssetRetry ($saved.Count -eq 2 -and @($saved | Where-Object Error -eq 'Simulated batch transport failure').Count -eq 2 -and $ManualActions.Count -eq 3) 'A batch exception lost failed payloads or manual actions.'

    # Honor the module fallback, including nonterminating errors and no asset.
    ConvertTo-Json -InputObject @($initialResults[1], $initialResults[2], $initialResults[3]) -Depth 75 | Set-Content -LiteralPath $resultPath
    $UseFastAssetCommit = $false
    $wireCalls.Clear()
    $ErrorActionPreference = 'Continue'
    try { Set-StrictMode -Off; . "$repoRoot/Public/Jobs/Invoke-AssetContentRetry.ps1" 6>$null }
    finally { Set-StrictMode -Version Latest; $ErrorActionPreference = 'Stop' }
    Assert-AssetRetry ($wireCalls.Count -eq 0 -and ($slowCalls.Id -join ',') -eq '402,403,404') 'Module fallback ignored failed payloads or used the fast transport.'
    Assert-AssetRetry ($slowCalls[0].CompanyId -eq 44 -and $slowCalls[0].AssetLayoutId -eq 55 -and $slowCalls[0].Fields[1].exact_number -ceq '0.123456789012345678901234567890') 'Module fallback changed the saved update payload.'
    $saved = @(Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json)
    Assert-AssetRetry ($saved[0].Status -eq 'updated' -and $saved[1].Error -eq 'Simulated nonterminating module error' -and $saved[2].Error -like '*no asset*' -and $ManualActions.Count -eq 3) 'Module fallback did not isolate failures and update final manual actions.'
    Write-Output "Passed $checks asset content retry checks (offline; saved payloads, resume, final manual actions, and fast/module failures)."
} finally {
    $resolvedFixtureRoot = [IO.Path]::GetFullPath($fixtureRoot)
    $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $resolvedFixtureRoot.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolvedFixtureRoot) -notmatch '^itglue-asset-retry-[a-f0-9]{32}$') {
        throw "Refusing fixture cleanup outside the expected temp directory: $resolvedFixtureRoot"
    }
    if ([IO.Directory]::Exists($resolvedFixtureRoot)) { [IO.Directory]::Delete($resolvedFixtureRoot, $true) }
}
