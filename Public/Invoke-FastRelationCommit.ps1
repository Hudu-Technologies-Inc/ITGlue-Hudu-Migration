function Invoke-FastHuduRelationCommit {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Relations,

        [ValidateRange(1, 32)]
        [int]$ThrottleLimit = 4,

        [ValidateRange(0, 5)]
        [int]$MaxRetries = 1,

        [hashtable]$CustomHeaders = @{}
    )

    if (-not $Relations -or $Relations.Count -lt 1) {
        return @()
    }

    $huduBaseUrl = (Get-HuduBaseURL).TrimEnd('/')
    $huduApiKey = (New-Object PSCredential 'user', (Get-HuduApiKey)).GetNetworkCredential().Password
    $ThrottleLimit = [math]::Max(1, $ThrottleLimit)
    $rateLimitGate = [System.Collections.Concurrent.ConcurrentDictionary[string, datetime]]::new()

    Write-Host "Creating $($Relations.Count) Hudu relation(s) with $ThrottleLimit worker(s)." -ForegroundColor Cyan

    $Relations | ForEach-Object -Parallel {
        $relation = $_
        $baseUrl = $using:huduBaseUrl
        $apiKey = $using:huduApiKey
        $maxRetries = $using:MaxRetries
        $customHeaders = $using:CustomHeaders
        $rateLimitGate = $using:rateLimitGate
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

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

        $body = @{ relation = $relationBody } | ConvertTo-Json -Depth 20
        $headers = @{
            'x-api-key' = $apiKey
        }
        if ($customHeaders) {
            foreach ($customHeaderKey in $customHeaders.Keys) {
                $headers[$customHeaderKey] = $customHeaders[$customHeaderKey]
            }
        }
        $restMethod = @{
            Method      = 'POST'
            Uri         = "$baseUrl/api/v1/relations"
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
                        Write-Host "Hudu API rate-limit gate active; relation $($relation.FromableType):$($relation.FromableID) -> $($relation.ToableType):$($relation.ToableID) sleeping for $gateSleepSeconds seconds."
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
                    Status         = 'created'
                    Relation       = $response.relation ?? $response
                    SourceRelation = $relation
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

                    Write-Host "Hudu API Rate limited; pausing fast relation commits until $($waitUntil.ToString('HH:mm:ss'))."
                } else {
                    $sleepSeconds = 5
                    Write-Host "Hudu API transient error during fast relation commit $($relation.FromableType):$($relation.FromableID) -> $($relation.ToableType):$($relation.ToableID); retrying in $sleepSeconds seconds. $lastError" -ForegroundColor Yellow
                }

                $sleptSeconds += $sleepSeconds
                Start-Sleep -Seconds $sleepSeconds
            }
        }

        $stopwatch.Stop()
        [pscustomobject]@{
            Status         = 'failed'
            Relation       = $null
            SourceRelation = $relation
            Attempts       = $attempt
            SleptSeconds   = $sleptSeconds
            ElapsedSeconds = [math]::Round($stopwatch.Elapsed.TotalSeconds, 3)
            StatusCode     = $lastStatusCode
            Error          = $lastError
        }
    } -ThrottleLimit $ThrottleLimit
}
