function Get-ITGlueApiExceptionStatusCode {
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    foreach ($candidate in @(
        $ErrorRecord.Exception.Response.StatusCode
        $ErrorRecord.Exception.StatusCode
    )) {
        if ($null -eq $candidate) { continue }
        try { return [int]$candidate } catch {}
    }

    $errorText = @(
        $ErrorRecord.Exception.Message
        $ErrorRecord.Exception.InnerException.Message
        $ErrorRecord.ErrorDetails.Message
    ) -join ' '
    if ($errorText -match '\b429\b') { return 429 }

    return $null
}

function Get-ITGlueRetryAfterSeconds {
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $response = $ErrorRecord.Exception.Response
    if (-not $response) { return $null }

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
        $ErrorRecord.Exception.InnerException.Message
        $ErrorRecord.ErrorDetails.Message
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
        [int]$MaxDelaySeconds = 120
    )

    $attempt = 0
    $totalAttempts = $MaxRetries + 1

    while ($attempt -lt $totalAttempts) {
        $attempt++
        try {
            return & $Operation
        } catch {
            $statusCode = Get-ITGlueApiExceptionStatusCode -ErrorRecord $_
            $isTransient = Test-ITGlueTransientRequestError -ErrorRecord $_
            if (-not $isTransient -or $attempt -ge $totalAttempts) {
                throw
            }

            $retryAfterSeconds = Get-ITGlueRetryAfterSeconds -ErrorRecord $_
            $jitterSeconds = Get-Random -Minimum 1 -Maximum 5
            if ($retryAfterSeconds) {
                $sleepSeconds = [math]::Min($MaxDelaySeconds, [int]$retryAfterSeconds + $jitterSeconds)
            } else {
                $backoffSeconds = [math]::Min($MaxDelaySeconds, [int]($InitialDelaySeconds * [math]::Pow(2, [math]::Min($attempt - 1, 6))))
                $sleepSeconds = $backoffSeconds + $jitterSeconds
            }

            $statusText = if ($statusCode) { "HTTP $statusCode" } else { "transient error" }
            Write-Warning "$OperationName failed with $statusText. Retrying in $sleepSeconds second(s). Attempt $attempt of $totalAttempts."
            Start-Sleep -Seconds $sleepSeconds
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

        [int]$MaxRetries = 8
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
    if ($showPasswordRequested) { $passwordRequest.show_password = $true }

    $operationName = if ($PSBoundParameters.ContainsKey('Id')) {
        "Get-ITGluePasswords id $Id"
    } elseif ($PSBoundParameters.ContainsKey('PageNumber')) {
        "Get-ITGluePasswords page $PageNumber"
    } else {
        'Get-ITGluePasswords'
    }

    Invoke-ITGlueCommandWithRetry `
        -Operation { Get-ITGluePasswords @passwordRequest } `
        -OperationName $operationName `
        -MaxRetries $MaxRetries
}
