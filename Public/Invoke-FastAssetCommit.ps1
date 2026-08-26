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

    $huduBaseUrl = (Get-HuduBaseURL).TrimEnd('/')
    $huduApiKey = (New-Object PSCredential 'user', (Get-HuduApiKey)).GetNetworkCredential().Password
    $ThrottleLimit = [math]::Max(1, $ThrottleLimit)
    $rateLimitGate = [System.Collections.Concurrent.ConcurrentDictionary[string, datetime]]::new()

    Write-Host "$($Operation) committing $($AssetRequests.Count) Hudu asset(s) with $ThrottleLimit worker(s)." -ForegroundColor Cyan

    $AssetRequests | ForEach-Object -Parallel {
        $assetRequest = $_
        $baseUrl = $using:huduBaseUrl
        $apiKey = $using:huduApiKey
        $operation = $using:Operation
        $maxRetries = $using:MaxRetries
        $customHeaders = $using:CustomHeaders
        $rateLimitGate = $using:rateLimitGate
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

        $assetId = $assetRequest.AssetId
        $companyId = $assetRequest.CompanyId
        $assetLayoutId = $assetRequest.AssetLayoutId

        if (-not $companyId -or -not $assetLayoutId -or ($operation -eq 'Update' -and -not $assetId)) {
            $stopwatch.Stop()
            return [pscustomobject]@{
                Status         = 'failed'
                Operation      = $operation
                Index          = $assetRequest.Index
                AssetId        = $assetId
                AssetName      = $assetRequest.Name
                CompanyId      = $companyId
                Asset          = $null
                SourceRequest  = $assetRequest
                Attempts       = 0
                SleptSeconds   = 0
                ElapsedSeconds = [math]::Round($stopwatch.Elapsed.TotalSeconds, 3)
                StatusCode     = $null
                Error          = 'Asset request is missing CompanyId, AssetLayoutId, or AssetId.'
            }
        }

        $asset = [ordered]@{
            name            = [string]$assetRequest.Name
            asset_layout_id = [int]$assetLayoutId
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

        $body = @{ asset = $asset } | ConvertTo-Json -Depth 20
        $resource = if ($operation -eq 'Create') {
            "/api/v1/companies/$companyId/assets"
        } else {
            "/api/v1/companies/$companyId/assets/$assetId"
        }

        $headers = @{
            'x-api-key' = $apiKey
        }
        if ($customHeaders) {
            foreach ($customHeaderKey in $customHeaders.Keys) {
                $headers[$customHeaderKey] = $customHeaders[$customHeaderKey]
            }
        }
        $restMethod = @{
            Method      = if ($operation -eq 'Create') { 'POST' } else { 'PUT' }
            Uri         = "$baseUrl$resource"
            Headers     = $headers
            ContentType = 'application/json; charset=utf-8'
            Body        = $body
        }

        $attempt = 0
        $lastError = $null
        $lastStatusCode = $null
        $sleptSeconds = 0

        while ($attempt -le $maxRetries) {
            $gateUntil = [datetime]::MinValue
            if ($rateLimitGate.TryGetValue('WaitUntil', [ref]$gateUntil)) {
                $now = Get-Date
                if ($gateUntil -gt $now) {
                    $gateSleepSeconds = [math]::Ceiling(($gateUntil - $now).TotalSeconds)
                    if ($gateSleepSeconds -gt 0) {
                        Write-Host "Hudu API rate-limit gate active; asset '$($assetRequest.Name)' sleeping for $gateSleepSeconds seconds."
                        $sleptSeconds += $gateSleepSeconds
                        Start-Sleep -Seconds $gateSleepSeconds
                    }
                }
            }

            $attempt++
            try {
                $response = Invoke-RestMethod @restMethod -ErrorAction Stop
                $stopwatch.Stop()

                return [pscustomobject]@{
                    Status         = if ($operation -eq 'Create') { 'created' } else { 'updated' }
                    Operation      = $operation
                    Index          = $assetRequest.Index
                    AssetId        = ($response.asset.id ?? $assetId)
                    AssetName      = $assetRequest.Name
                    CompanyId      = $companyId
                    Asset          = ($response.asset ?? $response)
                    SourceRequest  = $assetRequest
                    Attempts       = $attempt
                    SleptSeconds   = $sleptSeconds
                    ElapsedSeconds = [math]::Round($stopwatch.Elapsed.TotalSeconds, 3)
                    StatusCode     = 200
                }
            }
            catch {
                $lastError = $_.Exception.Message
                $lastStatusCode = $null
                try {
                    if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
                        $lastStatusCode = [int]$_.Exception.Response.StatusCode
                    }
                } catch {}

                $errorText = @($lastError, $_.Exception.InnerException.Message, $_.ErrorDetails.Message) -join ' '
                $transientStatusCodes = @(408, 500, 502, 503, 504)
                $rateLimited = ($lastStatusCode -eq 429 -or $lastError -ilike '*Retry later*' -or $lastError -ilike '*Too Many Requests*')
                $transientFailure = (
                    $transientStatusCodes -contains $lastStatusCode -or
                    $errorText -ilike '*timed out*' -or
                    $errorText -ilike '*timeout*' -or
                    $errorText -ilike '*connection attempt failed*' -or
                    $errorText -ilike '*connection refused*' -or
                    $errorText -ilike '*actively refused*' -or
                    $errorText -ilike '*unable to connect*' -or
                    $errorText -ilike '*failed to respond*' -or
                    $errorText -ilike '*connection was closed*' -or
                    $errorText -ilike '*request was aborted*' -or
                    $errorText -ilike '*temporarily unavailable*'
                )
                if (-not $rateLimited -and -not $transientFailure) {
                    break
                }

                if ($attempt -gt $maxRetries) {
                    break
                }

                if ($rateLimited) {
                    $now = Get-Date
                    $windowLength = 5 * 60
                    $secondsIntoWindow = (($now.Minute % 5) * 60) + $now.Second
                    $sleepSeconds = [math]::Max(1, $windowLength - $secondsIntoWindow + (Get-Random -Minimum 1 -Maximum 5))
                    $waitUntil = $now.AddSeconds($sleepSeconds)
                    $gateUpdated = $false
                    do {
                        $existingWaitUntil = [datetime]::MinValue
                        $hasExistingWaitUntil = $rateLimitGate.TryGetValue('WaitUntil', [ref]$existingWaitUntil)
                        if ($hasExistingWaitUntil -and $existingWaitUntil -ge $waitUntil) {
                            $gateUpdated = $true
                            break
                        }
                        if ($hasExistingWaitUntil) {
                            $gateUpdated = $rateLimitGate.TryUpdate('WaitUntil', $waitUntil, $existingWaitUntil)
                        } else {
                            $gateUpdated = $rateLimitGate.TryAdd('WaitUntil', $waitUntil)
                        }
                    } until ($gateUpdated)

                    Write-Host "Hudu API Rate limited; pausing fast asset commits until $($waitUntil.ToString('HH:mm:ss'))."
                } else {
                    $sleepSeconds = 5
                    Write-Host "Hudu API transient error during fast asset commit for '$($assetRequest.Name)'; retrying in $sleepSeconds seconds. $lastError" -ForegroundColor Yellow
                }

                $sleptSeconds += $sleepSeconds
                Start-Sleep -Seconds $sleepSeconds
            }
        }

        $stopwatch.Stop()
        [pscustomobject]@{
            Status         = 'failed'
            Operation      = $operation
            Index          = $assetRequest.Index
            AssetId        = $assetId
            AssetName      = $assetRequest.Name
            CompanyId      = $companyId
            Asset          = $null
            SourceRequest  = $assetRequest
            Attempts       = $attempt
            SleptSeconds   = $sleptSeconds
            ElapsedSeconds = [math]::Round($stopwatch.Elapsed.TotalSeconds, 3)
            StatusCode     = $lastStatusCode
            Error          = $lastError
        }
    } -ThrottleLimit $ThrottleLimit
}
