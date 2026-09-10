function Get-HuduMigrationCanonicalLabelRecordType {
    param(
        [AllowNull()]
        [string]$RecordType
    )

    if ([string]::IsNullOrWhiteSpace($RecordType)) { return $null }

    switch (($RecordType.Trim().ToLowerInvariant() -replace '[\s_-]+', '')) {
        { $_ -in @('asset', 'assets') } { return 'Asset' }
        { $_ -in @('assetpassword', 'assetpasswords', 'password', 'passwords') } { return 'AssetPassword' }
        { $_ -in @('article', 'articles') } { return 'Article' }
        { $_ -in @('website', 'websites') } { return 'Website' }
        default { return $RecordType.Trim() }
    }
}

function Test-HuduMigrationLabelTypeApplies {
    param(
        [Parameter(Mandatory)]
        $LabelType,

        [Parameter(Mandatory)]
        [string]$RecordType
    )

    $canonicalRecordType = Get-HuduMigrationCanonicalLabelRecordType -RecordType $RecordType
    $recordTypes = foreach ($labelRecordType in @($LabelType.applicable_record_types)) {
        Get-HuduMigrationCanonicalLabelRecordType -RecordType ([string]$labelRecordType)
    }
    $recordTypes = @($recordTypes | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    return ($recordTypes.Count -eq 0 -or $recordTypes -icontains $canonicalRecordType)
}

function Get-HuduMigrationLabelType {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$RecordType,

        [string]$Color = "$(Get-RandomHexColor)"
    )

    if ([string]::IsNullOrWhiteSpace($Name)) { return $null }
    $canonicalRecordType = Get-HuduMigrationCanonicalLabelRecordType -RecordType $RecordType
    if ([string]::IsNullOrWhiteSpace($canonicalRecordType)) { return $null }

    if (-not (Get-Command -Name Get-HuduLabelTypes -ErrorAction SilentlyContinue) -or -not (Get-Command -Name New-HuduLabelType -ErrorAction SilentlyContinue)) {
        Write-Warning "Hudu label type commands are unavailable. Skipping label type '$Name'."
        return $null
    }

    $labelType = $null
    try {
        $matchingTypes = @(Get-HuduLabelTypes -Name $Name -ErrorAction Stop | Where-Object { $_.name -ieq $Name })
        $labelType = $matchingTypes | Where-Object { Test-HuduMigrationLabelTypeApplies -LabelType $_ -RecordType $canonicalRecordType } | Select-Object -First 1
        if ($null -eq $labelType) {
            $labelType = $matchingTypes | Select-Object -First 1
        }
    } catch {
        Write-Warning "Unable to look up label type '$Name': $($_.Exception.Message)"
    }

    if ($null -ne $labelType -and -not (Test-HuduMigrationLabelTypeApplies -LabelType $labelType -RecordType $canonicalRecordType)) {
        if (Get-Command -Name Set-HuduLabelType -ErrorAction SilentlyContinue) {
            try {
                $currentTypes = foreach ($labelRecordType in @($labelType.applicable_record_types)) {
                    Get-HuduMigrationCanonicalLabelRecordType -RecordType ([string]$labelRecordType)
                }
                $updatedTypes = @($currentTypes + $canonicalRecordType) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique
                $labelType = Set-HuduLabelType -Id $labelType.id -ApplicableRecordTypes $updatedTypes -ErrorAction Stop
            } catch {
                Write-Warning "Unable to add '$canonicalRecordType' to existing label type '$Name'. Labels using this type may fail: $($_.Exception.Message)"
                return $null
            }
        } else {
            Write-Warning "Label type '$Name' exists but is not applicable to '$canonicalRecordType', and Set-HuduLabelType is unavailable."
            return $null
        }
    }

    if ($null -eq $labelType) {
        try {
            $labelType = New-HuduLabelType -Name $Name -Color $Color -ApplicableRecordTypes @($canonicalRecordType) -ErrorAction Stop
        } catch {
            Write-Warning "Unable to create label type '$Name' for '$canonicalRecordType': $($_.Exception.Message)"
            return $null
        }
    }

    return $labelType
}

function New-HuduMigrationLabelCacheEntry {
    param(
        [Parameter(Mandatory)]
        $LabelType,

        [Parameter(Mandatory)]
        [string]$RecordType
    )

    $existingLabelableIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if (Get-Command -Name Get-HuduLabels -ErrorAction SilentlyContinue) {
        try {
            foreach ($existingLabel in @(Get-HuduLabels -LabelTypeId $LabelType.id -Labelable_Type $RecordType -ErrorAction Stop)) {
                if ($null -ne $existingLabel.labelable_id) {
                    [void]$existingLabelableIds.Add([string]$existingLabel.labelable_id)
                }
            }
        } catch {
            Write-Warning "Unable to load existing labels for label type '$($LabelType.name)' ($($LabelType.id)): $($_.Exception.Message)"
        }
    }

    return [pscustomobject]@{
        LabelType            = $LabelType
        ExistingLabelableIds = $existingLabelableIds
    }
}

function Add-HuduMigrationLabel {
    param(
        [Parameter(Mandatory)]
        [string]$LabelName,

        [Parameter(Mandatory)]
        [string]$RecordType,

        [Parameter(Mandatory)]
        [int]$RecordId,

        [string]$RecordName,

        [hashtable]$LabelTypeCache,

        [string]$Color = "$(Get-RandomHexColor)"
    )

    if ([string]::IsNullOrWhiteSpace($LabelName) -or $RecordId -lt 1) { return $null }
    $canonicalRecordType = Get-HuduMigrationCanonicalLabelRecordType -RecordType $RecordType
    if ([string]::IsNullOrWhiteSpace($canonicalRecordType)) { return $null }

    if (-not (Get-Command -Name New-HuduLabel -ErrorAction SilentlyContinue)) {
        Write-Warning "Hudu label command is unavailable. Skipping label '$LabelName' on '$RecordName'."
        return $null
    }

    $cacheKey = "$($canonicalRecordType.ToLowerInvariant())|$($LabelName.ToLowerInvariant())"
    if ($LabelTypeCache -and $LabelTypeCache.ContainsKey($cacheKey)) {
        $cacheEntry = $LabelTypeCache[$cacheKey]
    } else {
        $labelType = Get-HuduMigrationLabelType -Name $LabelName -RecordType $canonicalRecordType -Color $Color
        if ($null -eq $labelType -or $null -eq $labelType.id) { return $null }
        $cacheEntry = New-HuduMigrationLabelCacheEntry -LabelType $labelType -RecordType $canonicalRecordType
        if ($LabelTypeCache) { $LabelTypeCache[$cacheKey] = $cacheEntry }
    }

    if ($cacheEntry.ExistingLabelableIds.Contains([string]$RecordId)) {
        return [pscustomobject]@{
            LabelName  = $LabelName
            LabelTypeId = $cacheEntry.LabelType.id
            RecordType  = $canonicalRecordType
            RecordId    = $RecordId
            RecordName  = $RecordName
            Status      = "AlreadyExists"
        }
    }

    try {
        $newLabel = New-HuduLabel -LabelTypeId $cacheEntry.LabelType.id -Labelable_Type $canonicalRecordType -Labelable_Id $RecordId -ErrorAction Stop
        [void]$cacheEntry.ExistingLabelableIds.Add([string]$RecordId)
        return [pscustomobject]@{
            LabelName  = $LabelName
            LabelTypeId = $cacheEntry.LabelType.id
            RecordType  = $canonicalRecordType
            RecordId    = $RecordId
            RecordName  = $RecordName
            Status      = "Created"
            HuduLabel   = $newLabel
        }
    } catch {
        Write-Warning "Failed to add label '$LabelName' to $canonicalRecordType '$RecordName' ($RecordId): $($_.Exception.Message)"
        return [pscustomobject]@{
            LabelName  = $LabelName
            LabelTypeId = $cacheEntry.LabelType.id
            RecordType  = $canonicalRecordType
            RecordId    = $RecordId
            RecordName  = $RecordName
            Status      = "Failed"
            Error       = $_.Exception.Message
        }
    }
}

function Add-HuduMigrationLabels {
    param(
        [Parameter(Mandatory)]
        [object[]]$Labels,

        [hashtable]$LabelTypeCache,

        [ValidateRange(1, 32)]
        [int]$ThrottleLimit = 4,

        [bool]$UseFastLabelCommit = $true,

        [hashtable]$CustomHeaders = @{}
    )

    if (-not $Labels -or $Labels.Count -lt 1) {
        return @()
    }

    if (-not $LabelTypeCache) {
        $LabelTypeCache = @{}
    }

    $results = [System.Collections.ArrayList]@()
    $labelsToCreate = [System.Collections.ArrayList]@()
    $seenInBatch = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($label in @($Labels)) {
        $labelName = [string]$label.LabelName
        $recordType = Get-HuduMigrationCanonicalLabelRecordType -RecordType ([string]$label.RecordType)
        $recordId = [int]($label.RecordId ?? 0)
        $recordName = [string]$label.RecordName
        $color = [string]($label.Color ?? "$(Get-RandomHexColor)")

        if ([string]::IsNullOrWhiteSpace($labelName) -or [string]::IsNullOrWhiteSpace($recordType) -or $recordId -lt 1) {
            continue
        }

        $cacheKey = "$($recordType.ToLowerInvariant())|$($labelName.ToLowerInvariant())"
        if ($LabelTypeCache.ContainsKey($cacheKey)) {
            $cacheEntry = $LabelTypeCache[$cacheKey]
        } else {
            $labelType = Get-HuduMigrationLabelType -Name $labelName -RecordType $recordType -Color $color
            if ($null -eq $labelType -or $null -eq $labelType.id) {
                $null = $results.Add([pscustomobject]@{
                    LabelName  = $labelName
                    LabelTypeId = $null
                    RecordType  = $recordType
                    RecordId    = $recordId
                    RecordName  = $recordName
                    Status      = 'Failed'
                    Error       = 'Unable to resolve or create label type.'
                })
                continue
            }
            $cacheEntry = New-HuduMigrationLabelCacheEntry -LabelType $labelType -RecordType $recordType
            $LabelTypeCache[$cacheKey] = $cacheEntry
        }

        $batchKey = "$($cacheEntry.LabelType.id)|$recordType|$recordId"
        if ($cacheEntry.ExistingLabelableIds.Contains([string]$recordId) -or -not $seenInBatch.Add($batchKey)) {
            $null = $results.Add([pscustomobject]@{
                LabelName  = $labelName
                LabelTypeId = $cacheEntry.LabelType.id
                RecordType  = $recordType
                RecordId    = $recordId
                RecordName  = $recordName
                Status      = 'AlreadyExists'
            })
            continue
        }

        $null = $labelsToCreate.Add([pscustomobject]@{
            LabelName   = $labelName
            LabelTypeId = $cacheEntry.LabelType.id
            RecordType  = $recordType
            RecordId    = $recordId
            RecordName  = $recordName
            CacheEntry  = $cacheEntry
        })
    }

    $labelCommitResults = if ($labelsToCreate.Count -gt 0 -and $UseFastLabelCommit) {
        if (-not (Get-Command -Name Invoke-FastHuduLabelCommit -ErrorAction SilentlyContinue)) {
            . $PSScriptRoot\Invoke-FastLabelCommit.ps1
        }
        $fastLabelCommitParams = @{
            LabelRequests = @($labelsToCreate)
            ThrottleLimit = $ThrottleLimit
        }
        if ($CustomHeaders -and $CustomHeaders.Count -gt 0) {
            $fastLabelCommitParams.CustomHeaders = $CustomHeaders
        }
        Invoke-FastHuduLabelCommit @fastLabelCommitParams
    } else {
        foreach ($labelToCreate in @($labelsToCreate)) {
            try {
                [pscustomobject]@{
                    Status       = 'Created'
                    LabelRequest = $labelToCreate
                    HuduLabel    = New-HuduLabel -LabelTypeId $labelToCreate.LabelTypeId -Labelable_Type $labelToCreate.RecordType -Labelable_Id $labelToCreate.RecordId -ErrorAction Stop
                    Error        = $null
                }
            } catch {
                [pscustomobject]@{
                    Status       = 'Failed'
                    LabelRequest = $labelToCreate
                    HuduLabel    = $null
                    Error        = $_.Exception.Message
                }
            }
        }
    }

    foreach ($commitResult in @($labelCommitResults)) {
        $labelRequest = $commitResult.LabelRequest
        if ($commitResult.Status -eq 'Created' -and $commitResult.HuduLabel) {
            [void]$labelRequest.CacheEntry.ExistingLabelableIds.Add([string]$labelRequest.RecordId)
        }

        $null = $results.Add([pscustomobject]@{
            LabelName             = $labelRequest.LabelName
            LabelTypeId           = $labelRequest.LabelTypeId
            RecordType            = $labelRequest.RecordType
            RecordId              = $labelRequest.RecordId
            RecordName            = $labelRequest.RecordName
            Status                = $commitResult.Status
            HuduLabel             = $commitResult.HuduLabel
            Error                 = $commitResult.Error
            commit_attempts       = $commitResult.Attempts
            commit_elapsed_seconds = $commitResult.ElapsedSeconds
            commit_slept_seconds  = $commitResult.SleptSeconds
        })
    }

    return @($results.ToArray())
}
