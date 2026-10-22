function Invoke-FastHuduRequestBatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Requests,

        [ValidateRange(1, 32)]
        [int]$ThrottleLimit = 4,

        [ValidateRange(0, 5)]
        [int]$MaxRetries = 1,

        [hashtable]$CustomHeaders = @{}
    )

    if (-not $Requests -or $Requests.Count -lt 1) {
        return @()
    }

    $huduBaseUrl = (Get-HuduBaseURL).TrimEnd('/')
    $huduApiKey = (New-Object PSCredential 'user', (Get-HuduApiKey)).GetNetworkCredential().Password
    $ThrottleLimit = [math]::Max(1, $ThrottleLimit)
    $rateLimitGate = [System.Collections.Concurrent.ConcurrentDictionary[string, datetime]]::new()

    $Requests | ForEach-Object -Parallel {
        $request = $_
        $baseUrl = $using:huduBaseUrl
        $apiKey = $using:huduApiKey
        $maxRetries = $using:MaxRetries
        $customHeaders = $using:CustomHeaders
        $rateLimitGate = $using:rateLimitGate
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

        if (-not [string]::IsNullOrWhiteSpace([string]$request.ValidationError)) {
            $stopwatch.Stop()
            return [pscustomobject]@{
                Status         = 'failed'
                SourceRequest  = $request.SourceRequest
                Response       = $null
                Attempts       = 0
                SleptSeconds   = 0
                ElapsedSeconds = [math]::Round($stopwatch.Elapsed.TotalSeconds, 3)
                StatusCode     = $null
                Error          = [string]$request.ValidationError
            }
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
            Method      = [string]$request.Method
            Uri         = "$baseUrl$($request.Resource)"
            Headers     = $headers
            ContentType = [string]($request.ContentType ?? 'application/json; charset=utf-8')
        }
        if ($request.Body) {
            $restMethod.Body = $request.Body
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
                        $gateDescription = [string]($request.GateDescription ?? 'fast commit')
                        Write-Host "Hudu API rate-limit gate active; $gateDescription sleeping for $gateSleepSeconds seconds."
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
                    Status         = 'succeeded'
                    SourceRequest  = $request.SourceRequest
                    Response       = $response
                    Attempts       = $attempt
                    SleptSeconds   = $sleptSeconds
                    ElapsedSeconds = [math]::Round($stopwatch.Elapsed.TotalSeconds, 3)
                    StatusCode     = 200
                    Error          = $null
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

                    $commitName = [string]($request.CommitName ?? 'commit')
                    Write-Host "Hudu API Rate limited; pausing fast $commitName commits until $($waitUntil.ToString('HH:mm:ss'))."
                } else {
                    $sleepSeconds = 5
                    $transientDescription = [string]($request.TransientDescription ?? 'fast commit')
                    Write-Host "Hudu API transient error during $transientDescription; retrying in $sleepSeconds seconds. $lastError" -ForegroundColor Yellow
                }

                $sleptSeconds += $sleepSeconds
                Start-Sleep -Seconds $sleepSeconds
            }
        }

        $stopwatch.Stop()
        [pscustomobject]@{
            Status         = 'failed'
            SourceRequest  = $request.SourceRequest
            Response       = $null
            Attempts       = $attempt
            SleptSeconds   = $sleptSeconds
            ElapsedSeconds = [math]::Round($stopwatch.Elapsed.TotalSeconds, 3)
            StatusCode     = $lastStatusCode
            Error          = $lastError
        }
    } -ThrottleLimit $ThrottleLimit
}
