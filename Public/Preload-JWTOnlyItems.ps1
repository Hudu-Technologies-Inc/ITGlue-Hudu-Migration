if ([string]::IsNullOrEmpty($ITglueJWT)) {
    Write-Host "No JWT token provided. Skipping Pre-Load of Certs, Passwordfolders, and Checklists."
    return
}

if (-not (Get-Command -Name Get-EnsuredPath -ErrorAction SilentlyContinue)) { . .\Public\Init-OptionsAndLogs.ps1 }
if (-not (Get-Command -Name Get-ITGlueJWTAuth -ErrorAction SilentlyContinue)) { . $PSScriptRoot\Public\JWT-Auth.ps1 }
if (-not (Get-Command -Name Get-ITGlueCheckLists -ErrorAction SilentlyContinue)) { . $PSScriptRoot\Public\Get-Checklists.ps1 }

# $ITglueSSLCerts = Get-ITGlueSslCertificates -JWTAuthToken $ITGlueJWT
$ITGAPIEndpoint = @($ITGBaseURI,$ITGAPIEndpoint, $settings.ITGAPIEndpoint) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1
if ([string]::IsNullOrWhiteSpace($ITGAPIEndpoint)) {
    $ITGAPIEndpoint = Select-ObjectFromList -objects @("https://api.itglue.com", "https://api.eu.itglue.com", "https://api.au.itglue.com") -message "Select ITGlue API Endpoint for your instance/region"
}
$ITGAPIEndpoint= ($ITGAPIEndpoint.Trim() -replace '[\\/]+$', '')

try {
    $ITGlueJWT = Get-ITGlueJWTAuth -ITglueJWT $ITglueJWT -ITGBaseURI $ITGAPIEndpoint
} catch {
    Write-Host "Error authenticating with ITGlue using provided JWT token. Please verify the token is correct and try again."
    throw $_
}

# Checklists Data
$MatchedChecklists = $MatchedChecklists ?? @(); $ITGlueRawChecklists = $ITGlueRawChecklists ?? @(); $ITglueChecklists = $ITglueChecklists ?? [System.Collections.ArrayList]@();
$PageSize = 1000
$PageNum = 0
while ($true) {
        $ITGlueRawChecklists = $(Get-ITGlueCheckLists -JWTAuthToken $ITGlueJWT -page_size $PageSize -page_number $PageNum  -ITGBaseURI $ITGAPIEndpoint).data
    foreach ($checklistEntry in $ITGlueRawChecklists) {
        $ITGChecklistItems=$null
        try {
            $checklistEntry | Add-Member -MemberType 'NoteProperty' -Name 'IsTemplate' -Value $false -Force
                $ITGChecklistItems=$(Get-ITGlueChecklistItems -JWTAuthToken $ITGlueJWT -filter_checklist_id $checklistEntry.id -ITGBaseURI $ITGAPIEndpoint)
            $checklistEntry | Add-Member -MemberType 'NoteProperty' -Name 'ITGChecklistItems' -Value $ITGChecklistItems -Force
        }catch{
            Write-host "Error getting checklist items $_"
        }
        $ITGLueChecklists.Add($checklistEntry)
    }
    $PageNum = $PageNum +1
    if (-not $ITGlueRawChecklists -or $ITGlueRawChecklists.count -lt $PageSize) {break}
}
$PageNum = 0
Write-Host "Retrieving all checklist templates from ITGlue"
while ($true) {
        $ITGlueRawChecklists = $(Get-ITGlueChecklistTemplates -JWTAuthToken $ITGlueJWT -page_size $PageSize -page_number $PageNum -ITGBaseURI $ITGAPIEndpoint).data
    foreach ($checklistTemplate in $ITGlueRawChecklists | Where-Object {$_}) {
        $ITGChecklistItems=$null
        try {
            $checklistTemplate | Add-Member -MemberType 'NoteProperty' -Name 'IsTemplate' -Value $true -Force
                $ITGChecklistItems=$(Get-ITGlueChecklistTemplateItems -JWTAuthToken $ITGlueJWT -filter_checklist_id $checklistTemplate.id -ITGBaseURI $ITGAPIEndpoint)
                $checklistTemplate | Add-Member -MemberType 'NoteProperty' -Name 'ITGChecklistItems' -Value $ITGChecklistItems -Force
        }catch{
            Write-host "Error getting checklist template items $_"
        }

        $ITGLueChecklists.Add($checklistTemplate)
    }
    $PageNum = $PageNum +1
    if (-not $ITGlueRawChecklists -or $ITGlueRawChecklists.count -lt $PageSize) {break}
}
Write-Host "Got $($($ITGLueChecklists | where-object {$_.IsTemplate -eq $false}).count) and $($($ITGLueChecklists | where-object {$_.IsTemplate -eq $true}).count) checklist templates with $($ITGlueRawChecklists.ITGChecklistItems.count) Checklist Items."
if ($ITGLueChecklists.Count -gt 0) {
    $ITGLueChecklists | convertto-json -depth 99 | Out-File "$MigrationLogs\RetrievedChecklists.json"
} else {
    Write-Host "No checklists retrieved from ITGlue, skipping saving to file."
}