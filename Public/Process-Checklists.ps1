

$HuduCompanies  = $HuduCompanies ?? $(Get-HuduCompanies)
$huduUsers      = $huduUsers ?? $(Get-HuduUsers)    
$userIndex = @{}
$MatchedChecklists = $MatchedChecklists ?? @()
foreach ($u in $huduUsers) {$key = "$($u.first_name) $($u.last_name)".ToLower(); $userIndex[$key] = $u;}

if (-not (Get-Command -Name Get-ITGlueCheckLists -ErrorAction SilentlyContinue)) { . "$($(get-childitem -path "." -Recurse -file "Get-Checklists.ps1" | Select-Object -first 1).fullname)" }
if (-not (Get-Command -Name Get-ITGlueJWTAuth -ErrorAction SilentlyContinue)) { . "$($(get-childitem -path "." -Recurse -file "JWT-Auth.ps1" | Select-Object -first 1).fullname)" }


$ITGAPIEndpoint = @($ITGBaseURI,$ITGAPIEndpoint, $settings.ITGAPIEndpoint) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1
if ([string]::IsNullOrWhiteSpace($ITGAPIEndpoint)) {
    $ITGAPIEndpoint = Select-ObjectFromList -objects @("https://api.itglue.com", "https://api.eu.itglue.com", "https://api.au.itglue.com") -message "Select ITGlue API Endpoint for your instance/region"
}
$ITGAPIEndpoint= ($ITGAPIEndpoint.Trim() -replace '[\\/]+$', '')

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
        $ITGlueRawChecklists = @(Get-ITGlueChecklistTemplates -JWTAuthToken $ITGlueJWT -page_size $PageSize -page_number $PageNum -ITGBaseURI $ITGAPIEndpoint)
        foreach ($checklistTemplate in $ITGlueRawChecklists | Where-Object {$_}) {
            $ITGChecklistItems=$null
            try {
                $checklistTemplate | Add-Member -MemberType 'NoteProperty' -Name 'IsTemplate' -Value $true -Force
                $ITGChecklistItems=$(Get-ITGlueChecklistTemplateItems -JWTAuthToken $ITGlueJWT -filter_checklist_id $checklistTemplate.id -ITGBaseURI $ITGAPIEndpoint)
                $checklistTemplate | Add-Member -MemberType 'NoteProperty' -Name 'ITGChecklistItems' -Value $ITGChecklistItems -Force
            } catch {
                Write-host "Error getting checklist template items $_"
            }

            $ITGLueChecklists.Add($checklistTemplate)
        }
        $PageNum = $PageNum +1
        if (-not $ITGlueRawChecklists -or $ITGlueRawChecklists.count -lt $PageSize) {break}
    }
    $ChecklistCount = @($ITGLueChecklists | Where-Object { $_.IsTemplate -eq $false }).Count
    $ChecklistTemplateCount = @($ITGLueChecklists | Where-Object { $_.IsTemplate -eq $true }).Count
    $ChecklistItemCount = ($ITGLueChecklists | Where-Object { $_.IsTemplate -eq $false } | ForEach-Object { @($_.ITGChecklistItems | Where-Object { $_ }).Count } | Measure-Object -Sum).Sum
    $ChecklistTemplateItemCount = ($ITGLueChecklists | Where-Object { $_.IsTemplate -eq $true } | ForEach-Object { @($_.ITGChecklistItems | Where-Object { $_ }).Count } | Measure-Object -Sum).Sum
    Write-Host "Got $ChecklistCount ITGlue checklists ($ChecklistItemCount tasks) and $ChecklistTemplateCount ITGlue checklist templates ($ChecklistTemplateItemCount template tasks)."
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
# Hudu process mapping:
# - ITGlue checklist templates are reusable definitions, so they become Hudu process templates.
#   With a matched company they become company process templates; otherwise they become global process templates.
# - ITGlue checklists are single-use company records. On Hudu 2.41.0+, a company process is created and
#   kicked off as a process run so run-only fields like due dates and assignees can be preserved.
$ChecklistIDX=0
foreach ($checklist in $ITGLueChecklists) {
    $ChecklistIDX=$ChecklistIDX+1

    $HuduProcedureTasks = @()
    $isChecklistTemplate = $true -eq $checklist.IsTemplate
    $matchedCompany = $null
    $matchedCompany = $($($MatchedCompanies | Where-Object {[string]$checklist.attributes.'organization-id' -eq [string]$_.ITGID} | Select-Object -First 1))

    $runMetadataValues = @($checklist.attributes.'assignee-name')
    foreach ($item in @($checklist.ITGChecklistItems | Where-Object { $_ })) {
        $runMetadataValues += $item.attributes.'assignee-name'
        $runMetadataValues += $item.attributes.'due-date'
    }
    $hasRunMetadata = (-not $isChecklistTemplate) -and @( $runMetadataValues | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count -gt 0

    $importExplanation = if ($isChecklistTemplate) {
        if ($matchedCompany -and $matchedCompany.HuduID -and $matchedCompany.HuduID -gt 0) {
            'checklist template as a reusable Hudu company process template.'
        } else {
            'checklist template as a reusable Hudu global process template.'
        }
    } elseif ($CurrentVersion -and $CurrentVersion -ge [version]'2.41.0') {
        if ($matchedCompany -and $matchedCompany.HuduID -and $matchedCompany.HuduID -gt 0) {
            'checklist as a Hudu process run.'
        } else {
            'checklist as a Hudu global process template because no matched company was found to kick off a run.'
        }
    } elseif ($hasRunMetadata) {
        'checklist as a Hudu procedure with due dates or assignees applied to tasks where supported.'
    } else {
        'checklist as a Hudu procedure; no due dates or assignees were found.'
    }

    $procedureRequest = @{
        Name = [System.Net.WebUtility]::UrlDecode("$($checklist.attributes.name ?? 'Unnamed Procedure')")
        CompanyTemplate = $checklist.IsTemplate ?? $false
        Description =  $($($checklist.attributes.description ?? "No description found for procedure.") + "`n" + 
            "Imported from ITGlue $importExplanation <a href='$($checklist.attributes.'resource-url')'>ITGlue source</a>")
    }

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

        $taskTargetProcedure = $newProcedure
        $newProcedureRun = $null
        if ((-not $isChecklistTemplate) -and $CurrentVersion -and $CurrentVersion -ge [version]'2.41.0' -and $newProcedure.company_id -and (Get-Command -Name Start-HuduProcedure -ErrorAction SilentlyContinue)) {
            try {
                $newProcedureRun = Start-HuduProcedure -ProcedureId $newProcedure.id -Name $procedureRequest['Name']
                $newProcedureRun = $newProcedureRun.procedure ?? $newProcedureRun
            } catch {
                Write-Host "Error starting Hudu process run for checklist $($checklist.id): $_"
            }

            if ($newProcedureRun -and $newProcedureRun.Id) {
                $taskTargetProcedure = $newProcedureRun
                $checklist | Add-Member -MemberType 'NoteProperty' -Name 'HuduProcedureRun' -Value $newProcedureRun -Force
                Write-Host "Started Hudu process run $($newProcedureRun.Id) from procedure $($newProcedure.Id)"
            } elseif ($hasRunMetadata) {
                Write-Host "Could not start a Hudu process run for checklist $($checklist.id); due dates and assignees may not be applied."
            }
        }

        $TaskIDX=0

        
        foreach ($task in $checklist.ITGChecklistItems){
            $TaskIDX = $TaskIDX + 1

            $NewProcedureTask = $null
            $DueDate = $null
            $assignedUsers = @()

            $NewTaskRequest = @{
                ProcedureId = $taskTargetProcedure.id
                Name        = [System.Net.WebUtility]::UrlDecode("$($task.attributes.name ?? ("Task #$($task.attributes.order)" ?? "Unnamed Task"))")
                Description = ($task.attributes.description ?? "Imported from ITglue with no description")
            }

            if ($task.attributes.order) {
                $NewTaskRequest["Position"] = $task.attributes.order
            }

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
                    }
                }
            }

            $canApplyRunFields = (-not ($CurrentVersion -and $CurrentVersion -ge [version]'2.41.0')) -or ($newProcedureRun -and $newProcedureRun.Id)
            if ($canApplyRunFields) {
                if ($assignedUsers.Count -gt 0) {
                    $NewTaskRequest['AssignedUsers'] = $assignedUsers
                }

                if ($task.attributes.'due-date') {
                    $dueDate = [datetime]$task.attributes.'due-date'
                    $NewTaskRequest['DueDate'] = $dueDate.ToString('yyyy-MM-dd')

                    $age = (Get-Date) - $dueDate
                    $NewTaskRequest['Priority'] = if ($age.TotalDays -lt 0) { 'urgent' }
                                                elseif ($age.TotalDays -le 14) { 'high' }
                                                else { 'normal' }
                }

                if ($newProcedureRun -and $newProcedureRun.Id) {
                    $NewTaskRequest['RunTask'] = $true
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

Write-Host "Procedures and tasks migrated"
