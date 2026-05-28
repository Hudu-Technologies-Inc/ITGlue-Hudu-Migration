

$HuduCompanies  = $HuduCompanies ?? $(Get-HuduCompanies)
$huduUsers      = $huduUsers ?? $(Get-HuduUsers)    
$userIndex = @{}
$MatchedChecklists = $MatchedChecklists ?? @()
foreach ($u in $huduUsers) {$key = "$($u.first_name) $($u.last_name)".ToLower(); $userIndex[$key] = $u;}

if (-not (Get-Command -Name Get-ITGlueCheckLists -ErrorAction SilentlyContinue)) { . "$($(get-childitem -path "." -Recurse -file "Get-Checklists.ps1" | Select-Object -first 1).fullname)" }
if (-not (Get-Command -Name Get-ITGlueJWTAuth -ErrorAction SilentlyContinue)) { . "$($(get-childitem -path "." -Recurse -file "JWT-Auth.ps1" | Select-Object -first 1).fullname)" }
$ITGAPIEndpoint = $settings.ITGAPIEndpoint ?? 
    $(Select-ObjectFromList -objects @("https://api.itglue.com", "https://api.eu.itglue.com", "https://api.au.itglue.com") -message "Select ITGlue API Endpoint for your instance/region")

$ITGlueJWT = $ITGlueJWT ?? (Read-Host "Please enter your ITGlue JWT as retrieved from browser.")
$ITGlueJWT = Get-ITGlueJWTAuth -ITglueJWT $ITglueJWT -ITGBaseURI $ITGAPIEndpoint



if (-not (test-path "$MigrationLogs\RetrievedChecklists.json")){
    Write-Host "No preloaded checklists found. attempting second-line retrieval"
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
                $ITGChecklistItems=$(Get-ITGlueChecklistItems -JWTAuthToken $ITGlueJWT -filter_checklist_id $checklistTemplate.id)
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
    $ITGLueChecklists | convertto-json -depth 99 | Out-File "$MigrationLogs\RetrievedChecklists.json"    
} else {
    write-host "Preloaded checklists found, loading from file if needed."
    if (-not $ITGLueChecklists) {
        $loaded = Get-Content "$MigrationLogs\RetrievedChecklists.json" -Raw | ConvertFrom-Json -Depth 99
        $ITGLueChecklists = [System.Collections.ArrayList]@()
        foreach ($item in @($loaded)) {
            [void]$ITGLueChecklists.Add($item)
        }
    } else {
        Write-Host "ITGLueChecklists variable already populated, skipping loading from file."
    }
}


# Match/Add Checklists/Items
$ChecklistIDX=0
foreach ($checklist in $ITGLueChecklists) {
    $ChecklistIDX=$ChecklistIDX+1

    $HuduProcedureTasks = @()
    $procedureRequest = @{
        Name = [System.Net.WebUtility]::UrlDecode("$($checklist.attributes.name ?? 'Unnamed Procedure')")
        CompanyTemplate = $checklist.IsTemplate ?? $false
        Description =  $($($checklist.attributes.description ?? "No description found for procedure.") + "`n" + 
            "Imported from ITGlue. <a href='$($checklist.attributes.'resource-url')'>itglue checklist url</a>")
    }
    $matchedCompany = $null
    $matchedCompany = $($($MatchedCompanies | Where-Object {[string]$checklist.attributes.'organization-id' -eq [string]$_.ITGID} | Select-Object -First 1))

    if ($matchedCompany -and $matchedCompany.HuduID -and $matchedCompany.HuduID -gt 0){
        $procedureRequest["CompanyID"] = $matchedCompany.HuduID
    }

    try {
        $newProcedure = $null
        $newProcedure = New-HuduProcedure @procedureRequest
        $newProcedure = $newProcedure.procedure ?? $newProcedure

    } catch {
        Write-Host "Error creating procedure in Hudu $_"
        continue
    }

    if ($newProcedure -and $newProcedure.Id) {
        $checklist | Add-Member -MemberType 'NoteProperty' -Name 'HuduProcedure' -Value $newProcedure -Force
        Write-Host "Created $(if (-not $newProcedure.company_id) {'Global'} else {'Company'}) Procedure $(if ($true -eq $checklist.IsTemplate) {'Template'}) $($ChecklistIDX) of $($ITGLueChecklists.count)"

        $TaskIDX=0

        
        foreach ($task in $checklist.ITGChecklistItems){
            $TaskIDX = $TaskIDX + 1

            $NewProcedureTask = $null
            $DueDate = $null
            $assignedUsers = @()

            $NewTaskRequest = @{
                ProcedureId = $newProcedure.id
                Name        = [System.Net.WebUtility]::UrlDecode("$($task.attributes.name ?? ("Task #$($task.attributes.order)" ?? "Unnamed Task"))")
                Description = ($task.attributes.description ?? "Imported from ITglue with no description")
            }

            if ($task.attributes.order) {
                $NewTaskRequest["Position"] = $task.attributes.order
            }

            if ($CurrentVersion -and $CurrentVersion -lt [version]'2.41.0'){
                $assigneeCandidates = @(
                    $checklist.attributes.'assignee-name',
                    $task.attributes.'assignee-name'
                ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

                foreach ($a in $assigneeCandidates) {
                    $first,$last = ($a -replace '\s+', ' ').Trim() -split '\s+', 2
                    if ($last) {
                        $key = "$first $last".ToLower()
                        if ($userIndex.ContainsKey($key)) {
                            $assignedUsers += $userIndex[$key].id
                            $runTask = $true
                        }
                    }
                }

                if ($assignedUsers.Count -gt 0) {
                    $NewTaskRequest['AssignedUsers'] = $assignedUsers
                }

                if ($task.attributes.'due-date') {
                    $runTask = $true
                    $dueDate = [datetime]$task.attributes.'due-date'
                    $NewTaskRequest['DueDate'] = $dueDate.ToString('yyyy-MM-dd')

                    $age = (Get-Date) - $dueDate
                    $NewTaskRequest['Priority'] = if ($age.TotalDays -lt 0) { 'urgent' }
                                                elseif ($age.TotalDays -le 14) { 'high' }
                                                else { 'normal' }
                }
            }
            try {             
                $NewProcedureTask = New-HuduProcedureTask @NewTaskRequest
            }
            catch {
                Write-Host "Error adding checklist Task $_"
            }

            if ($NewProcedureTask) {
                Write-Host "Added $(if (($assignedUsers).Count -gt 0) {'User-Assigned '} else {''})procedure task $($TaskIDX) of $($checklist.ITGChecklistItems.count)"
                $HuduProcedureTasks += $NewProcedureTask
            }
        }        
        
        $checklist.HuduProcedure | Add-Member -MemberType 'NoteProperty' -Name 'HuduProcedureTasks' -Value $HuduProcedureTasks -Force
        $MatchedChecklists+=$checklist
    }
}
$MatchedChecklists | ConvertTo-Json -Depth 99 | Out-File "$MigrationLogs\Checklists.json"

Write-Host "Proceduires and tasks migrated"