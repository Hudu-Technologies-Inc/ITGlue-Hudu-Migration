function Invoke-FastHuduArchiveCommit {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$ArchiveRequests,

        [ValidateRange(1, 196)]
        [int]$ThrottleLimit = 4,

        [ValidateRange(0, 5)]
        [int]$MaxRetries = 2,

        [hashtable]$CustomHeaders = @{}
    )

    if (-not $ArchiveRequests -or $ArchiveRequests.Count -lt 1) {
        return @()
    }

    if (-not (Get-Command -Name Invoke-FastHuduRequestBatch -ErrorAction SilentlyContinue)) {
        . (Join-Path $PSScriptRoot 'Invoke-FastHuduRequestBatch.ps1')
    }

    Write-Host "Archiving $($ArchiveRequests.Count) Hudu item(s) with $ThrottleLimit worker(s)." -ForegroundColor Cyan

    $fastRequests = foreach ($archiveRequest in $ArchiveRequests) {
        $resource = switch ([string]$archiveRequest.Type) {
            'AssetPassword' { "/api/v1/asset_passwords/$($archiveRequest.Id)/archive" }
            'Asset' { "/api/v1/companies/$($archiveRequest.CompanyId)/assets/$($archiveRequest.Id)/archive" }
            'Article' { "/api/v1/articles/$($archiveRequest.Id)/archive" }
            default { $null }
        }

        [pscustomobject]@{
            Method               = 'PUT'
            Resource             = $resource
            ContentType          = 'application/json; charset=utf-8'
            SourceRequest        = $archiveRequest
            CommitName           = 'archive'
            GateDescription      = "$($archiveRequest.Type) $($archiveRequest.Id) archive"
            TransientDescription = "fast archive commit for $($archiveRequest.Type) $($archiveRequest.Id)"
            ValidationError      = if ([string]::IsNullOrWhiteSpace($resource)) { "Unsupported archive type '$($archiveRequest.Type)'." } else { $null }
        }
    }

    $batchResults = Invoke-FastHuduRequestBatch -Requests $fastRequests -ThrottleLimit $ThrottleLimit -MaxRetries $MaxRetries -CustomHeaders $CustomHeaders

    foreach ($batchResult in @($batchResults)) {
        $archiveRequest = $batchResult.SourceRequest
        if ($batchResult.Status -eq 'succeeded') {
            [pscustomobject]@{
                Status         = 'archived'
                ArchiveRequest = $archiveRequest
                ArchivedObject = $batchResult.Response
                Attempts       = $batchResult.Attempts
                SleptSeconds   = $batchResult.SleptSeconds
                ElapsedSeconds = $batchResult.ElapsedSeconds
                StatusCode     = 200
            }
        } else {
            [pscustomobject]@{
                Status         = 'failed'
                ArchiveRequest = $archiveRequest
                ArchivedObject = $null
                Attempts       = $batchResult.Attempts
                SleptSeconds   = $batchResult.SleptSeconds
                ElapsedSeconds = $batchResult.ElapsedSeconds
                StatusCode     = $batchResult.StatusCode
                Error          = $batchResult.Error
            }
        }
    }
}
