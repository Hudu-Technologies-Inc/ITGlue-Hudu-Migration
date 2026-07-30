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

        [string]$Color = "$(Get-RandomHexColor)",

        [hashtable]$Cache
    )

    if ([string]::IsNullOrWhiteSpace($Name)) { return $null }
    $canonicalRecordType = Get-HuduMigrationCanonicalLabelRecordType -RecordType $RecordType
    if ([string]::IsNullOrWhiteSpace($canonicalRecordType)) { return $null }

    if (-not (Get-Command -Name Get-HuduLabelTypes -ErrorAction SilentlyContinue) -or -not (Get-Command -Name New-HuduLabelType -ErrorAction SilentlyContinue)) {
        Write-Warning "Hudu label type commands are unavailable. Skipping label type '$Name'."
        return $null
    }

    $cacheKey = "$($canonicalRecordType.ToLowerInvariant())|$($Name.ToLowerInvariant())"
    if ($Cache -and $Cache.ContainsKey($cacheKey)) {
        return $Cache[$cacheKey]
    }

    $labelType = $null
    try {
        $labelType = @(Get-HuduLabelTypes -Name $Name -ErrorAction Stop | Where-Object { $_.name -ieq $Name }) | Select-Object -First 1
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
            }
        } else {
            Write-Warning "Label type '$Name' exists but is not applicable to '$canonicalRecordType', and Set-HuduLabelType is unavailable."
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

    if ($Cache) { $Cache[$cacheKey] = $labelType }
    return $labelType
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

    $labelType = Get-HuduMigrationLabelType -Name $LabelName -RecordType $canonicalRecordType -Color $Color -Cache $LabelTypeCache
    if ($null -eq $labelType -or $null -eq $labelType.id) { return $null }

    try {
        if (Get-Command -Name Get-HuduLabels -ErrorAction SilentlyContinue) {
            $existingLabel = @(Get-HuduLabels -LabelTypeId $labelType.id -Labelable_Type $canonicalRecordType -Labelable_Id $RecordId -ErrorAction Stop) | Select-Object -First 1
            if ($existingLabel) {
                return [pscustomobject]@{
                    LabelName  = $LabelName
                    LabelTypeId = $labelType.id
                    RecordType  = $canonicalRecordType
                    RecordId    = $RecordId
                    RecordName  = $RecordName
                    Status      = "AlreadyExists"
                }
            }
        }

        $newLabel = New-HuduLabel -LabelTypeId $labelType.id -Labelable_Type $canonicalRecordType -Labelable_Id $RecordId -ErrorAction Stop
        return [pscustomobject]@{
            LabelName  = $LabelName
            LabelTypeId = $labelType.id
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
            LabelTypeId = $labelType.id
            RecordType  = $canonicalRecordType
            RecordId    = $RecordId
            RecordName  = $RecordName
            Status      = "Failed"
            Error       = $_.Exception.Message
        }
    }
}
