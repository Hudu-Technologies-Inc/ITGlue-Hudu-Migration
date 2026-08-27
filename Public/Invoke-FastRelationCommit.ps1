function Invoke-FastHuduRelationCommit {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Relations,

        [ValidateRange(1, 240)]
        [int]$ThrottleLimit = 4,

        [ValidateRange(0, 5)]
        [int]$MaxRetries = 4,

        [hashtable]$CustomHeaders = @{}
    )

    if (-not $Relations -or $Relations.Count -lt 1) {
        return @()
    }

    if (-not (Get-Command -Name Invoke-FastHuduRequestBatch -ErrorAction SilentlyContinue)) {
        . (Join-Path $PSScriptRoot 'Invoke-FastHuduRequestBatch.ps1')
    }

    Write-Host "Creating $($Relations.Count) Hudu relation(s) with $ThrottleLimit worker(s)." -ForegroundColor Cyan

    $fastRequests = foreach ($relation in $Relations) {
        $relationBody = [ordered]@{
            fromable_type = [string]$relation.FromableType
            fromable_id   = [int]$relation.FromableID
            toable_type   = [string]$relation.ToableType
            toable_id     = [int]$relation.ToableID
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$relation.Description)) {
            $relationBody.description = [string]$relation.Description
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$relation.IsInverse)) {
            $relationBody.is_inverse = [string]$relation.IsInverse
        }

        [pscustomobject]@{
            Method               = 'POST'
            Resource             = '/api/v1/relations'
            Body                 = (@{ relation = $relationBody } | ConvertTo-Json -Depth 20)
            ContentType          = 'application/json; charset=utf-8'
            SourceRequest        = $relation
            CommitName           = 'relation'
            GateDescription      = "relation $($relation.FromableType):$($relation.FromableID) -> $($relation.ToableType):$($relation.ToableID)"
            TransientDescription = "fast relation commit $($relation.FromableType):$($relation.FromableID) -> $($relation.ToableType):$($relation.ToableID)"
        }
    }

    $batchResults = Invoke-FastHuduRequestBatch -Requests $fastRequests -ThrottleLimit $ThrottleLimit -MaxRetries $MaxRetries -CustomHeaders $CustomHeaders

    foreach ($batchResult in @($batchResults)) {
        $relation = $batchResult.SourceRequest
        if ($batchResult.Status -eq 'succeeded') {
            [pscustomobject]@{
                Status         = 'created'
                Relation       = $batchResult.Response.relation ?? $batchResult.Response
                SourceRelation = $relation
                Attempts       = $batchResult.Attempts
                SleptSeconds   = $batchResult.SleptSeconds
                ElapsedSeconds = $batchResult.ElapsedSeconds
                StatusCode     = 200
            }
        } else {
            [pscustomobject]@{
                Status         = 'failed'
                Relation       = $null
                SourceRelation = $relation
                Attempts       = $batchResult.Attempts
                SleptSeconds   = $batchResult.SleptSeconds
                ElapsedSeconds = $batchResult.ElapsedSeconds
                StatusCode     = $batchResult.StatusCode
                Error          = $batchResult.Error
            }
        }
    }
}
