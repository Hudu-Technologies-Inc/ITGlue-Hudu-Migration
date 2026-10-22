function Invoke-FastHuduAssetCommit {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$AssetRequests,

        [ValidateSet('Create', 'Update')]
        [string]$Operation = 'Update',

        [ValidateRange(1, 32)]
        [int]$ThrottleLimit = 4,

        [ValidateRange(0, 5)]
        [int]$MaxRetries = 1,

        [hashtable]$CustomHeaders = @{}
    )

    if (-not $AssetRequests -or $AssetRequests.Count -lt 1) {
        return @()
    }

    if (-not (Get-Command -Name Invoke-FastHuduRequestBatch -ErrorAction SilentlyContinue)) {
        . (Join-Path $PSScriptRoot 'Invoke-FastHuduRequestBatch.ps1')
    }

    Write-Host "$($Operation) committing $($AssetRequests.Count) Hudu asset(s) with $ThrottleLimit worker(s)." -ForegroundColor Cyan

    $fastRequests = foreach ($assetRequest in $AssetRequests) {
        $assetId = $assetRequest.AssetId
        $companyId = $assetRequest.CompanyId
        $assetLayoutId = $assetRequest.AssetLayoutId
        $validationError = if (-not $companyId -or -not $assetLayoutId -or ($Operation -eq 'Update' -and -not $assetId)) {
            'Asset request is missing CompanyId, AssetLayoutId, or AssetId.'
        } else {
            $null
        }

        $asset = [ordered]@{
            name            = [string]$assetRequest.Name
            asset_layout_id = [int]($assetLayoutId ?? 0)
        }

        $fields = @($assetRequest.Fields)
        if ($fields.Count -gt 0) {
            $asset.custom_fields = $fields
        }

        foreach ($optionalProperty in @('PrimarySerial', 'PrimaryMail', 'PrimaryModel', 'PrimaryManufacturer', 'Slug')) {
            if (-not [string]::IsNullOrWhiteSpace([string]$assetRequest.$optionalProperty)) {
                $wireName = switch ($optionalProperty) {
                    'PrimarySerial' { 'primary_serial' }
                    'PrimaryMail' { 'primary_mail' }
                    'PrimaryModel' { 'primary_model' }
                    'PrimaryManufacturer' { 'primary_manufacturer' }
                    'Slug' { 'slug' }
                }
                $asset[$wireName] = [string]$assetRequest.$optionalProperty
            }
        }

        $resource = if ($Operation -eq 'Create') {
            "/api/v1/companies/$companyId/assets"
        } else {
            "/api/v1/companies/$companyId/assets/$assetId"
        }

        [pscustomobject]@{
            Method               = if ($Operation -eq 'Create') { 'POST' } else { 'PUT' }
            Resource             = $resource
            Body                 = (@{ asset = $asset } | ConvertTo-Json -Depth 20)
            ContentType          = 'application/json; charset=utf-8'
            SourceRequest        = $assetRequest
            CommitName           = 'asset'
            GateDescription      = "asset '$($assetRequest.Name)'"
            TransientDescription = "fast asset commit for '$($assetRequest.Name)'"
            ValidationError      = $validationError
        }
    }

    $batchResults = Invoke-FastHuduRequestBatch -Requests $fastRequests -ThrottleLimit $ThrottleLimit -MaxRetries $MaxRetries -CustomHeaders $CustomHeaders

    foreach ($batchResult in @($batchResults)) {
        $assetRequest = $batchResult.SourceRequest
        if ($batchResult.Status -eq 'succeeded') {
            [pscustomobject]@{
                Status         = if ($Operation -eq 'Create') { 'created' } else { 'updated' }
                Operation      = $Operation
                Index          = $assetRequest.Index
                AssetId        = ($batchResult.Response.asset.id ?? $assetRequest.AssetId)
                AssetName      = $assetRequest.Name
                CompanyId      = $assetRequest.CompanyId
                Asset          = ($batchResult.Response.asset ?? $batchResult.Response)
                SourceRequest  = $assetRequest
                Attempts       = $batchResult.Attempts
                SleptSeconds   = $batchResult.SleptSeconds
                ElapsedSeconds = $batchResult.ElapsedSeconds
                StatusCode     = 200
            }
        } else {
            [pscustomobject]@{
                Status         = 'failed'
                Operation      = $Operation
                Index          = $assetRequest.Index
                AssetId        = $assetRequest.AssetId
                AssetName      = $assetRequest.Name
                CompanyId      = $assetRequest.CompanyId
                Asset          = $null
                SourceRequest  = $assetRequest
                Attempts       = $batchResult.Attempts
                SleptSeconds   = $batchResult.SleptSeconds
                ElapsedSeconds = $batchResult.ElapsedSeconds
                StatusCode     = $batchResult.StatusCode
                Error          = $batchResult.Error
            }
        }
    }
}
