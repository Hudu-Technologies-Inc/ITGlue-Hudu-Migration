if ([string]::IsNullOrEmpty($ITglueJWT)) {
    Write-Host "No JWT token provided. Skipping Pre-Load of Certs, Passwordfolders, and Checklists."
    return
}

$checklistCommands = @(
    'Get-ITGlueCheckLists',
    'Get-ITGlueChecklistItems',
    'Get-ITGlueChecklistTemplates',
    'Get-ITGlueChecklistTemplateItems'
)
if ($checklistCommands | Where-Object { -not (Get-Command -Name $_ -ErrorAction SilentlyContinue) }) { . (Join-Path $PSScriptRoot "Get-Checklists.ps1") }
if (-not (Get-Command -Name Get-ITGlueJWTAuth -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot "JWT-Auth.ps1") }
if (-not (Get-Command -Name Get-EnsuredPath -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot "Init-OptionsAndLogs.ps1") }
$ITGAPIEndpoint = Resolve-ITGlueAPIEndpoint -ITGBaseURI $ITGAPIEndpoint
$ITGlueJWT = $ITGlueJWT ?? (Read-Host "Please enter your ITGlue JWT as retrieved from browser.")
$ITGlueJWT = Get-ITGlueJWTAuth -ITglueJWT $ITglueJWT -ITGBaseURI $ITGAPIEndpoint



# Checklists Data
$MatchedChecklists = $MatchedChecklists ?? @(); $ITGlueRawChecklists = $ITGlueRawChecklists ?? @(); $ITglueChecklists = $ITglueChecklists ?? [System.Collections.ArrayList]@();
$PageSize = 1000
$PageNum = 0
while ($true) {
    $ITGlueRawChecklists = $(Get-ITGlueCheckLists -JWTAuthToken $ITGlueJWT -page_size $PageSize -page_number $PageNum -ITGBaseURI $ITGAPIEndpoint).data
    foreach ($checklistEntry in $ITGlueRawChecklists) {
        $ITGChecklistItems=$null
        try {
            $checklistEntry | Add-Member -MemberType 'NoteProperty' -Name 'IsTemplate' -Value $false -Force
            $ITGChecklistItems=$(Get-ITGlueChecklistItems -JWTAuthToken $ITGlueJWT -filter_checklist_id $checklistEntry.id -ITGBaseURI $ITGAPIEndpoint)
            $checklistEntry | Add-Member -MemberType 'NoteProperty' -Name 'ITGChecklistItems' -Value $ITGChecklistItems -Force
        }catch{
            Write-host "Error getting checklist items $_"
        }
        [void]$ITGLueChecklists.Add($checklistEntry)
    }
    $PageNum = $PageNum +1
    if (-not $ITGlueRawChecklists -or $ITGlueRawChecklists.count -lt $PageSize) {break}
}
$PageNum = 0
Write-Host "Retrieving all checklist templates from ITGlue"
while ($true) {
    $ITGlueRawChecklists = $(Get-ITGlueChecklistTemplates -JWTAuthToken $ITGlueJWT -page_size $PageSize -page_number $PageNum -ITGBaseURI $ITGAPIEndpoint)
    foreach ($checklistTemplate in $ITGlueRawChecklists | Where-Object {$_}) {
        $ITGChecklistItems=$null
        try {
            $checklistTemplate | Add-Member -MemberType 'NoteProperty' -Name 'IsTemplate' -Value $true -Force
            $ITGChecklistItems=$(Get-ITGlueChecklistTemplateItems -JWTAuthToken $ITGlueJWT -filter_checklist_id $checklistTemplate.id -ITGBaseURI $ITGAPIEndpoint)
            $checklistTemplate | Add-Member -MemberType 'NoteProperty' -Name 'ITGChecklistItems' -Value $ITGChecklistItems -Force
        }catch{
            Write-host "Error getting checklist template items $_"
        }

        [void]$ITGLueChecklists.Add($checklistTemplate)
    }
    $PageNum = $PageNum +1
    if (-not $ITGlueRawChecklists -or $ITGlueRawChecklists.count -lt $PageSize) {break}
}
if ($ITGLueChecklists.Count -gt 0) {
    $ITGLueChecklists | convertto-json -depth 99 | Out-File "$MigrationLogs\RetrievedChecklists.json"
} else {
    Write-Host "No checklists retrieved from ITGlue, skipping saving to file."
}
