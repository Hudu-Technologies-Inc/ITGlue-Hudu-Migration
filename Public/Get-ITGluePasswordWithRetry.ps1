function New-ITGluePasswordRequestGate {
    # Eight request starts/second leaves headroom below IT Glue's 3000/5 minutes.
    param([ValidateRange(0, 60000)][int]$MinimumIntervalMilliseconds = 125)

    # A mutex and a tiny timestamp file also work across Start-Job processes.
    # No credentials or password data are stored in the gate.
    $gateId = [guid]::NewGuid().ToString('N')
    $statePath = Join-Path ([System.IO.Path]::GetTempPath()) "itglue-password-gate-$gateId.txt"
    [System.IO.File]::WriteAllText($statePath, '0,0')
    return @{
        StatePath = $statePath
        MutexName = "ITGluePasswordGate-$gateId"
        MinimumIntervalMilliseconds = $MinimumIntervalMilliseconds
    }
}

function Get-ITGluePasswordRequestGate {
    $existing = Get-Variable -Name ITGluePasswordRequestGate -Scope Script -ErrorAction SilentlyContinue
    if (-not $existing -or -not $existing.Value) {
        $script:ITGluePasswordRequestGate = New-ITGluePasswordRequestGate
    }
    return $script:ITGluePasswordRequestGate
}

function Invoke-ITGlueRequestGateLock {
    param([hashtable]$RequestGate, [scriptblock]$Operation)
    $mutex = [System.Threading.Mutex]::new($false, $RequestGate.MutexName)
    $acquired = $false
    try {
        try { $acquired = $mutex.WaitOne() }
        catch [System.Threading.AbandonedMutexException] { $acquired = $true }
        & $Operation
    } finally {
        if ($acquired) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Wait-ITGluePasswordRequestGate {
    param([hashtable]$RequestGate)
    while ($true) {
        $sleepMilliseconds = Invoke-ITGlueRequestGateLock -RequestGate $RequestGate -Operation {
            $state = [System.IO.File]::ReadAllText($RequestGate.StatePath).Split(',')
            $now = [datetime]::UtcNow
            $notBeforeTicks = [math]::Max([long]$state[0], [long]$state[1])
            if ($notBeforeTicks -gt $now.Ticks) {
                return [math]::Ceiling(($notBeforeTicks - $now.Ticks) / [timespan]::TicksPerMillisecond)
            }
            $nextTicks = $now.AddMilliseconds($RequestGate.MinimumIntervalMilliseconds).Ticks
            [System.IO.File]::WriteAllText($RequestGate.StatePath, "$($state[0]),$nextTicks")
            return 0
        }
        if ($sleepMilliseconds -le 0) { return }
        # Recheck the shared deadline: another 429 can extend it while we wait.
        Start-Sleep -Milliseconds ([int][math]::Min(1000, $sleepMilliseconds))
    }
}

function Set-ITGluePasswordRequestCooldown {
    param([hashtable]$RequestGate, [double]$DelaySeconds)
    Invoke-ITGlueRequestGateLock -RequestGate $RequestGate -Operation {
        $state = [System.IO.File]::ReadAllText($RequestGate.StatePath).Split(',')
        $untilTicks = [datetime]::UtcNow.AddSeconds($DelaySeconds).Ticks
        $untilTicks = [math]::Max([long]$state[0], $untilTicks)
        [System.IO.File]::WriteAllText($RequestGate.StatePath, "$untilTicks,$($state[1])")
    }
}

function Get-ITGlueApiErrorResponses {
    param([System.Management.Automation.ErrorRecord]$ErrorRecord)
    $exception = $ErrorRecord.Exception
    while ($null -ne $exception) {
        $responseProperty = $exception.PSObject.Properties['Response']
        if ($null -ne $responseProperty -and $null -ne $responseProperty.Value) { $responseProperty.Value }
        $exception = $exception.InnerException
    }
}

function Get-ITGlueApiExceptionStatusCode {
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    foreach ($response in @(Get-ITGlueApiErrorResponses -ErrorRecord $ErrorRecord)) {
        try { if ($null -ne $response.StatusCode) { return [int]$response.StatusCode } } catch {}
    }

    try { if ($null -ne $ErrorRecord.Exception.StatusCode) { return [int]$ErrorRecord.Exception.StatusCode } } catch {}

    $errorText = @(
        $ErrorRecord.Exception.Message
        $(if ($ErrorRecord.Exception.InnerException) { $ErrorRecord.Exception.InnerException.Message })
        $(if ($ErrorRecord.ErrorDetails) { $ErrorRecord.ErrorDetails.Message })
    ) -join ' '
    if ($errorText -match '\b429\b') { return 429 }

    return $null
}

function Get-ITGlueRetryAfterSeconds {
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    foreach ($response in @(Get-ITGlueApiErrorResponses -ErrorRecord $ErrorRecord)) {
        try {
            if ($response.Headers.RetryAfter.Delta) {
                return [math]::Max(1, [math]::Ceiling($response.Headers.RetryAfter.Delta.TotalSeconds))
            }
            if ($response.Headers.RetryAfter.Date) {
                return [math]::Max(1, [math]::Ceiling(($response.Headers.RetryAfter.Date - [datetimeoffset]::Now).TotalSeconds))
            }
        } catch {}

        $retryAfterValues = @()
        try {
            if ($response.Headers['Retry-After']) {
                $retryAfterValues += $response.Headers['Retry-After']
            }
        } catch {}
        try {
            $retryAfterValues += $response.Headers.GetValues('Retry-After')
        } catch {}

        foreach ($retryAfterValue in @($retryAfterValues | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })) {
            $retryAfterText = [string]$retryAfterValue
            $retryAfterSeconds = 0
            if ([int]::TryParse($retryAfterText, [ref]$retryAfterSeconds)) {
                return [math]::Max(1, $retryAfterSeconds)
            }

            $retryAfterDate = [datetimeoffset]::MinValue
            if ([datetimeoffset]::TryParse($retryAfterText, [ref]$retryAfterDate)) {
                return [math]::Max(1, [math]::Ceiling(($retryAfterDate - [datetimeoffset]::Now).TotalSeconds))
            }
        }
    }
    return $null
}

function Test-ITGlueTransientRequestError {
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $statusCode = Get-ITGlueApiExceptionStatusCode -ErrorRecord $ErrorRecord
    if ($statusCode -eq 429) { return $true }
    if ($statusCode -in @(408, 500, 502, 503, 504)) { return $true }

    $errorText = @(
        $ErrorRecord.Exception.Message
        $(if ($ErrorRecord.Exception.InnerException) { $ErrorRecord.Exception.InnerException.Message })
        $(if ($ErrorRecord.ErrorDetails) { $ErrorRecord.ErrorDetails.Message })
    ) -join ' '

    return (
        $errorText -ilike '*Too Many Requests*' -or
        $errorText -ilike '*Retry later*' -or
        $errorText -ilike '*rate limit*' -or
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
}

function Invoke-ITGlueCommandWithRetry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [scriptblock]$Operation,

        [string]$OperationName = 'IT Glue request',

        [ValidateRange(0, 20)]
        [int]$MaxRetries = 8,

        [ValidateRange(1, 300)]
        [int]$InitialDelaySeconds = 2,

        [ValidateRange(1, 600)]
        [int]$MaxDelaySeconds = 120,

        [hashtable]$RequestGate
    )

    $attempt = 0
    $totalAttempts = $MaxRetries + 1
    $ErrorActionPreference = 'Stop'

    while ($attempt -lt $totalAttempts) {
        if ($RequestGate) { Wait-ITGluePasswordRequestGate -RequestGate $RequestGate }
        $attempt++
        try {
            $response = & $Operation
            return $response
        } catch {
            $statusCode = Get-ITGlueApiExceptionStatusCode -ErrorRecord $_
            $isTransient = Test-ITGlueTransientRequestError -ErrorRecord $_
            $retryAfterSeconds = Get-ITGlueRetryAfterSeconds -ErrorRecord $_
            $jitterSeconds = Get-Random -Minimum 1 -Maximum 5
            $rateLimited = $statusCode -eq 429 -or $_.Exception.Message -match '(?i)Too Many Requests|rate limit|Retry later'
            if ($rateLimited) {
                # IT Glue documents a five-minute window, not a wall-clock reset.
                # Never shorten a server-supplied Retry-After to MaxDelaySeconds.
                $sleepSeconds = $(if ($null -ne $retryAfterSeconds) { $retryAfterSeconds } else { 300 }) + $jitterSeconds
                if ($RequestGate) { Set-ITGluePasswordRequestCooldown -RequestGate $RequestGate -DelaySeconds $sleepSeconds }
            } elseif ($null -ne $retryAfterSeconds) {
                $sleepSeconds = $retryAfterSeconds + $jitterSeconds
            } else {
                $backoffSeconds = [math]::Min($MaxDelaySeconds, [int]($InitialDelaySeconds * [math]::Pow(2, [math]::Min($attempt - 1, 6))))
                $sleepSeconds = [math]::Min($MaxDelaySeconds, $backoffSeconds + $jitterSeconds)
            }

            # Publish a 429 even on the final attempt so other workers also stop.
            if (-not $isTransient -or $attempt -ge $totalAttempts) { throw }

            $statusText = if ($statusCode) { "HTTP $statusCode" } else { "transient error" }
            $gateText = if ($rateLimited -and $RequestGate) { ' All password workers share this cooldown.' } else { '' }
            Write-Warning "$OperationName failed with $statusText. Retrying in $sleepSeconds second(s). Attempt $attempt of $totalAttempts.$gateText"
            if (-not ($rateLimited -and $RequestGate)) { Start-Sleep -Seconds $sleepSeconds }
        }
    }
}

function Get-ITGluePasswordsWithRetry {
    [CmdletBinding(DefaultParameterSetName = 'List')]
    param(
        [Parameter(ParameterSetName = 'ById', Mandatory)]
        [Alias('PasswordId')]
        [object]$Id,

        [Parameter(ParameterSetName = 'List')]
        [Alias('page_size')]
        [int]$PageSize,

        [Parameter(ParameterSetName = 'List')]
        [Alias('page_number')]
        [int]$PageNumber,

        [string]$Include,

        [Alias('show_password')]
        [switch]$ShowPassword,

        [Parameter(ValueFromRemainingArguments = $true)]
        [object[]]$RemainingArguments = @(),

        [ValidateRange(0, 20)]
        [int]$MaxRetries = 8,

        [hashtable]$RequestGate
    )

    $passwordRequest = @{}
    if ($PSBoundParameters.ContainsKey('Id')) { $passwordRequest.id = $Id }
    if ($PSBoundParameters.ContainsKey('PageSize')) { $passwordRequest.page_size = $PageSize }
    if ($PSBoundParameters.ContainsKey('PageNumber')) { $passwordRequest.page_number = $PageNumber }
    if (-not [string]::IsNullOrWhiteSpace($Include)) { $passwordRequest.include = $Include }
    $showPasswordRequested = [bool]$ShowPassword
    if ($RemainingArguments.Count -gt 0 -and $RemainingArguments[0] -is [bool]) {
        $showPasswordRequested = [bool]$RemainingArguments[0]
    }
    if ($PSBoundParameters.ContainsKey('ShowPassword') -or $RemainingArguments.Count -gt 0) {
        $passwordRequest.show_password = $showPasswordRequested
    }
    if (-not $RequestGate) { $RequestGate = Get-ITGluePasswordRequestGate }

    $operationName = if ($PSBoundParameters.ContainsKey('Id')) {
        "Get-ITGluePasswords id $Id"
    } elseif ($PSBoundParameters.ContainsKey('PageNumber')) {
        "Get-ITGluePasswords page $PageNumber"
    } else {
        'Get-ITGluePasswords'
    }

    Invoke-ITGlueCommandWithRetry `
        -Operation { Get-ITGluePasswords @passwordRequest -ErrorAction Stop } `
        -OperationName $operationName `
        -MaxRetries $MaxRetries `
        -RequestGate $RequestGate
}
