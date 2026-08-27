function Invoke-FastHuduLabelCommit {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$LabelRequests,

        [ValidateRange(1, 240)]
        [int]$ThrottleLimit = 4,

        [ValidateRange(0, 5)]
        [int]$MaxRetries = 4,

        [hashtable]$CustomHeaders = @{}
    )

    if (-not $LabelRequests -or $LabelRequests.Count -lt 1) {
        return @()
    }

    if (-not (Get-Command -Name Invoke-FastHuduRequestBatch -ErrorAction SilentlyContinue)) {
        . (Join-Path $PSScriptRoot 'Invoke-FastHuduRequestBatch.ps1')
    }

    Write-Host "Creating $($LabelRequests.Count) Hudu label(s) with $ThrottleLimit worker(s)." -ForegroundColor Cyan

    $fastRequests = foreach ($labelRequest in $LabelRequests) {
        $body = @{
            label = @{
                label_type_id  = [int]$labelRequest.LabelTypeId
                labelable_type = [string]$labelRequest.RecordType
                labelable_id   = [int]$labelRequest.RecordId
            }
        } | ConvertTo-Json -Depth 20

        [pscustomobject]@{
            Method               = 'POST'
            Resource             = '/api/v1/labels'
            Body                 = $body
            ContentType          = 'application/json; charset=utf-8'
            SourceRequest        = $labelRequest
            CommitName           = 'label'
            GateDescription      = "label '$($labelRequest.LabelName)' on $($labelRequest.RecordType) $($labelRequest.RecordId)"
            TransientDescription = "fast label commit for '$($labelRequest.LabelName)' on $($labelRequest.RecordType) $($labelRequest.RecordId)"
        }
    }

    $batchResults = Invoke-FastHuduRequestBatch -Requests $fastRequests -ThrottleLimit $ThrottleLimit -MaxRetries $MaxRetries -CustomHeaders $CustomHeaders

    foreach ($batchResult in @($batchResults)) {
        $labelRequest = $batchResult.SourceRequest
        if ($batchResult.Status -eq 'succeeded') {
            [pscustomobject]@{
                Status         = 'Created'
                LabelRequest   = $labelRequest
                HuduLabel      = $batchResult.Response.label ?? $batchResult.Response
                Attempts       = $batchResult.Attempts
                SleptSeconds   = $batchResult.SleptSeconds
                ElapsedSeconds = $batchResult.ElapsedSeconds
                StatusCode     = 200
            }
        } else {
            [pscustomobject]@{
                Status         = 'Failed'
                LabelRequest   = $labelRequest
                HuduLabel      = $null
                Attempts       = $batchResult.Attempts
                SleptSeconds   = $batchResult.SleptSeconds
                ElapsedSeconds = $batchResult.ElapsedSeconds
                StatusCode     = $batchResult.StatusCode
                Error          = $batchResult.Error
            }
        }
    }
}
