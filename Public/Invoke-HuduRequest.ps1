function Invoke-WithRetry {
    param (
        [Parameter(Mandatory = $true)]
        [scriptblock]$ScriptBlock,

        [scriptblock]$OnFail,

        [int]$MaxRetries = 3,
        [int]$DelaySeconds = 2,
        [switch]$VerboseOutput
    )

    $attempt = 0
    while ($attempt -lt $MaxRetries) {
        try {
            $attempt++
            if ($VerboseOutput) {
                Write-Host "Attempt $attempt..."
            }
            return & $ScriptBlock
        }
        catch {
            if ($OnFail) {
                & $OnFail.Invoke($_, $attempt)
            }

            if ($attempt -lt $MaxRetries) {
                Write-Warning "Attempt $attempt failed: $_. Retrying in $DelaySeconds second(s)..."
                Start-Sleep -Seconds $DelaySeconds
            }
            else {
                Write-Error "All $MaxRetries attempts failed. Last error: $_"
                return $null
            }
        }
    }
}

function Invoke-HuduRequest {
    <#
    .SYNOPSIS
    Main Hudu API function

    .DESCRIPTION
    Calls Hudu API with token

    .PARAMETER Method
    GET,POST,DELETE,PUT,etc

    .PARAMETER Path
    Path to API endpoint

    .PARAMETER Params
    Hashtable of parameters

    .PARAMETER Body
    JSON encoded body string

    .PARAMETER Form
    Multipart form data

    .EXAMPLE
    Invoke-HuduRequest -Resource '/api/v1/articles' -Method GET
    #>
    [CmdletBinding()]
    Param(
        [Parameter()]
        [string]$Method = 'GET',

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$Resource,

        [Parameter()]
        [hashtable]$Params = @{},

        [Parameter()]
        [string]$Body,

        [Parameter()]
        [hashtable]$Form
    )

    $HuduAPIKey = Get-HuduApiKey
    $HuduBaseURL = Get-HuduBaseURL

    # Assemble parameters
    $ParamCollection = [System.Web.HttpUtility]::ParseQueryString([String]::Empty)

    # Sort parameters
    foreach ($Item in ($Params.GetEnumerator() | Sort-Object -CaseSensitive -Property Key)) {
        $ParamCollection.Add($Item.Key, $Item.Value)
    }

    # Query string
    $Request = $ParamCollection.ToString()

    $Headers = @{
        'x-api-key' = (New-Object PSCredential 'user', $HuduAPIKey).GetNetworkCredential().Password;
    }

    if (($Script:Int_HuduCustomHeaders | Measure-Object).count -gt 0){
        
        foreach($Entry in $Int_HuduCustomHeaders.GetEnumerator()) {
            $Headers[$Entry.Name] = $Entry.Value
        }
    }

    $ContentType = 'application/json; charset=utf-8'

    $Uri = '{0}{1}' -f $HuduBaseURL, $Resource
    # Make API call URI
    if ($Request) {
        $UriBuilder = [System.UriBuilder]$Uri
        $UriBuilder.Query = $Request
        $Uri = $UriBuilder.Uri
    }
    Write-Verbose ( '{0} [{1}]' -f $Method, $Uri )

    $RestMethod = @{
        Method      = $Method
        Uri         = $Uri
        Headers     = $Headers
        ContentType = $ContentType
    }

    if ($Body) {
        $RestMethod.Body = $Body
        Write-Verbose $Body
    }

    if ($Form) {
        $RestMethod.Form = $Form
        Write-Verbose ( $Form | Out-String )
    }
    $Results = Invoke-WithRetry -ScriptBlock {
        $response = Invoke-RestMethod @RestMethod
        return $response
    } -OnFail {
        Write-Error $($Body | ConvertTo-Json -depth 32).ToString()
    } -MaxRetries 5 -DelaySeconds 2 -VerboseOutput
    $Results
}