function Invoke-FastFlexibleAssetFieldPreparation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Assets,

        [Parameter(Mandatory)]
        [object[]]$AllFields,

        [object[]]$MatchedContacts = @(),
        [object[]]$MatchedConfigurations = @(),
        [object[]]$MatchedWebsites = @(),
        [object[]]$MatchedLocations = @(),
        [object[]]$MatchedAssets = @(),
        [object[]]$ITGPasswordsRaw = @(),

        [AllowNull()]
        [string]$ITGKey,

        [AllowNull()]
        [string]$ITGAPIEndpoint,

        [version]$CurrentVersion = [version]'2.44.0',
        [bool]$ImportDomains = $true,

        [ValidateRange(1, 32)]
        [int]$ThrottleLimit = 4
    )

    if (-not $Assets -or $Assets.Count -lt 1) {
        return @()
    }

    function New-FlexLookupMap {
        param([object[]]$Items)

        $map = @{}
        foreach ($item in @($Items | Where-Object { $_ })) {
            $key = [string]$item.ITGID
            if (-not [string]::IsNullOrWhiteSpace($key) -and -not $map.ContainsKey($key)) {
                $map[$key] = $item
            }
        }
        $map
    }

    $fieldMap = @{}
    foreach ($field in @($AllFields | Where-Object { $_ })) {
        $key = "$($field.IGLayoutID)|$($field.ITGParsedName)"
        if (-not $fieldMap.ContainsKey($key)) {
            $fieldMap[$key] = $field
        }
    }

    $passwordValueMap = @{}
    foreach ($passwordRow in @($ITGPasswordsRaw | Where-Object { $_ })) {
        $key = [string]$passwordRow.id
        if (-not [string]::IsNullOrWhiteSpace($key) -and -not $passwordValueMap.ContainsKey($key)) {
            $passwordValueMap[$key] = $passwordRow.password
        }
    }

    $contactMap = New-FlexLookupMap -Items $MatchedContacts
    $configurationMap = New-FlexLookupMap -Items $MatchedConfigurations
    $websiteMap = New-FlexLookupMap -Items $MatchedWebsites
    $locationMap = New-FlexLookupMap -Items $MatchedLocations
    $assetMap = New-FlexLookupMap -Items $MatchedAssets

    $ThrottleLimit = [math]::Max(1, $ThrottleLimit)
    Write-Host "Preparing $($Assets.Count) flexible asset content update request(s) with $ThrottleLimit worker(s)." -ForegroundColor Cyan

    $Assets | ForEach-Object -Parallel {
        $UpdateAsset = $_
        $fieldMap = $using:fieldMap
        $passwordValueMap = $using:passwordValueMap
        $contactMap = $using:contactMap
        $configurationMap = $using:configurationMap
        $websiteMap = $using:websiteMap
        $locationMap = $using:locationMap
        $assetMap = $using:assetMap
        $currentVersion = $using:CurrentVersion
        $importDomains = $using:ImportDomains
        $itgKey = $using:ITGKey
        $itgApiEndpoint = $using:ITGAPIEndpoint
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

        function Get-ParallelCastIfNumeric {
            param([object]$Value)

            if ($Value -is [string]) {
                $Value = $Value.Trim()
            }

            if ($Value -match '^[+-]?\d+(\.\d+)?$') {
                try {
                    return [int][double]$Value
                } catch {
                    return 0
                }
            }
            return $Value
        }

        function Get-ParallelCoercedDate {
            param(
                [Parameter(Mandatory)]
                [object]$InputDate,

                [datetime]$Cutoff = [datetime]'1000-01-01',

                [ValidateSet('DD.MM.YYYY','YYYY.MM.DD','MM/DD/YYYY')]
                [string]$OutputFormat = 'MM/DD/YYYY'
            )

            $inv = [System.Globalization.CultureInfo]::InvariantCulture

            if ($InputDate -is [datetime]) {
                $dt = [datetime]$InputDate
            } else {
                $text = "$InputDate".Trim()
                if ([string]::IsNullOrWhiteSpace($text)) { return $null }

                $formats = @(
                    'MM/dd/yyyy HH:mm:ss'
                    'MM/dd/yyyy hh:mm:ss tt'
                    'MM/dd/yyyy'
                )

                $dt = $null
                $ok = $false

                foreach ($fmt in $formats) {
                    try {
                        $dt = [System.DateTime]::ParseExact($text, $fmt, $inv)
                        $ok = $true
                        break
                    } catch {}
                }

                if (-not $ok) {
                    try {
                        $dt = [System.DateTime]::Parse($text, $inv)
                    } catch {
                        return $null
                    }
                }
            }

            if ($dt -lt $Cutoff) { return $null }

            switch ($OutputFormat) {
                'DD.MM.YYYY' { $dt.ToString('dd.MM.yyyy', $inv) }
                'YYYY.MM.DD' { $dt.ToString('yyyy.MM.dd', $inv) }
                'MM/DD/YYYY' { $dt.ToString('MM/dd/yyyy', $inv) }
            }
        }

        function Get-ParallelMapMatches {
            param(
                [hashtable]$Map,
                [AllowNull()]$Values
            )

            foreach ($value in @($Values)) {
                $id = $value.id
                if ([string]::IsNullOrWhiteSpace([string]$id)) { continue }
                $match = $Map[[string]$id]
                if ($match) { $match }
            }
        }

        function Add-ParallelAssetTagFieldValue {
            param(
                [hashtable]$AssetFields,
                $Field,
                [AllowNull()]$LinkedItems,
                [string]$AssetName,
                [System.Collections.ArrayList]$Messages
            )

            $validLinks = @($LinkedItems | ForEach-Object {
                $id = $_.HuduID ?? $_.id
                $name = $_.Name ?? $_.name

                if (-not [string]::IsNullOrWhiteSpace([string]$id)) {
                    [pscustomobject]@{
                        id   = $id
                        name = $name
                    }
                }
            })

            if ($validLinks.Count -eq 0) {
                $null = $Messages.Add("Skipping AssetTag value '$($Field.FieldName)' in '$AssetName' because none of the tagged IT Glue items are within the import scope.")
                return $false
            }

            $AssetFields["$($Field.HuduParsedName)"] = "$($validLinks | ConvertTo-Json -Compress -AsArray | Out-String)"
            return $true
        }

        $messages = [System.Collections.ArrayList]@()
        $manualActions = [System.Collections.ArrayList]@()
        $relationsToCreate = [System.Collections.ArrayList]@()
        $huduRelationsToCreate = [System.Collections.ArrayList]@()
        $matchedAssetPasswords = [System.Collections.ArrayList]@()
        $uploadFieldsArePresent = $false

        try {
            $null = $messages.Add("Populating $($UpdateAsset.Name)")
            $AssetFields = @{
                'Imported From ITGlue' = Get-Date -Format 'o'
            }

            $traits = $UpdateAsset.ITGObject.attributes.traits
            foreach ($trait in @($traits.PSObject.Properties)) {
                $ITGParsed = $trait.name
                $ITGValues = $trait.value
                $field = $fieldMap["$($UpdateAsset.ITGObject.attributes.'flexible-asset-type-id')|$ITGParsed"]

                if ($field) {
                    $supported = $true
                    if ($field.FieldType -eq 'Date') {
                        $raw = ($ITGValues.values ?? $ITGValues) -as [string]
                        $ReturnData = Get-ParallelCoercedDate -InputDate $raw -Cutoff '1000-01-01' -OutputFormat 'MM/DD/YYYY'
                        if (-not $ReturnData) {
                            if ($field.HuduLayoutField.required) {
                                $ReturnData = (Get-Date).ToString('MM/dd/yyyy', [System.Globalization.CultureInfo]::InvariantCulture)
                            } else {
                                continue
                            }
                        }
                        $AssetFields["$($field.HuduParsedName)"] = "$ReturnData"
                    } elseif ($field.FieldType -eq 'Tag') {
                        switch ($field.FieldSubType) {
                            'Checklists' {
                                foreach ($IDMatch in @($ITGValues.values)) {
                                    $null = $relationsToCreate.Add(@{ hudu_from_id = $UpdateAsset.HuduID; relation_type = 'Procedure'; itg_to_id = $IDMatch.id })
                                }
                                $null = $messages.Add("Tags to Procedure from $($field.FieldName) in $($UpdateAsset.Name) has been recorded for later.")
                            }
                            'ChecklistTemplates' {
                                foreach ($IDMatch in @($ITGValues.values)) {
                                    $null = $relationsToCreate.Add(@{ hudu_from_id = $UpdateAsset.HuduID; relation_type = 'Procedure'; itg_to_id = $IDMatch.id })
                                }
                                $null = $messages.Add("Tags to Procedure Template from $($field.FieldName) in $($UpdateAsset.Name) has been recorded for later.")
                            }
                            'Contacts' {
                                $ContactsLinked = Get-ParallelMapMatches -Map $contactMap -Values $ITGValues.values
                                $null = Add-ParallelAssetTagFieldValue -AssetFields $AssetFields -Field $field -LinkedItems $ContactsLinked -AssetName $UpdateAsset.Name -Messages $messages
                            }
                            'Configurations' {
                                $ConfigsLinked = Get-ParallelMapMatches -Map $configurationMap -Values $ITGValues.values
                                $null = Add-ParallelAssetTagFieldValue -AssetFields $AssetFields -Field $field -LinkedItems $ConfigsLinked -AssetName $UpdateAsset.Name -Messages $messages
                            }
                            'Documents' {
                                foreach ($IDMatch in @($ITGValues.values)) {
                                    $null = $relationsToCreate.Add(@{ hudu_from_id = $UpdateAsset.HuduID; relation_type = 'Article'; itg_to_id = $IDMatch.id })
                                }
                                $null = $messages.Add("Tags to Articles $($field.FieldName) in $($UpdateAsset.Name) has been recorded for later.")
                            }
                            'Domains' {
                                if ($true -ne $importDomains) {
                                    $null = $messages.Add("Skipping website/domain tags for $($field.FieldName) in $($UpdateAsset.Name) because website migration is disabled.")
                                    $supported = $false
                                } else {
                                    $DomainsLinked = Get-ParallelMapMatches -Map $websiteMap -Values $ITGValues.values | Where-Object {
                                        -not [string]::IsNullOrWhiteSpace([string]$_.HuduID)
                                    }
                                    foreach ($domain in @($DomainsLinked)) {
                                        $null = $huduRelationsToCreate.Add([pscustomobject]@{
                                            FromableType = 'Asset'
                                            FromableID   = [int]$UpdateAsset.HuduID
                                            ToableType   = 'Website'
                                            ToableID     = [int]$domain.HuduID
                                        })
                                    }
                                }
                            }
                            'Passwords' {
                                foreach ($IDMatch in @($ITGValues.values)) {
                                    $null = $relationsToCreate.Add(@{ hudu_from_id = $UpdateAsset.HuduID; relation_type = 'AssetPassword'; itg_to_id = $IDMatch.id })
                                }
                                $null = $messages.Add("Tags to Password $($field.FieldName) in $($UpdateAsset.Name) has been recorded for later.")
                            }
                            'Locations' {
                                $LocationsLinked = Get-ParallelMapMatches -Map $locationMap -Values $ITGValues.values
                                $null = Add-ParallelAssetTagFieldValue -AssetFields $AssetFields -Field $field -LinkedItems $LocationsLinked -AssetName $UpdateAsset.Name -Messages $messages
                            }
                            'Organizations' {
                                foreach ($IDMatch in @($ITGValues.values)) {
                                    $null = $relationsToCreate.Add(@{ hudu_from_id = $UpdateAsset.HuduID; relation_type = 'Company'; itg_to_id = $IDMatch.id })
                                }
                                $null = $messages.Add("Tags to Companies $($field.FieldName) in $($UpdateAsset.Name) has been recorded later.")
                            }
                            'FlexibleAssetType' {
                                $AssetsLinked = Get-ParallelMapMatches -Map $assetMap -Values $ITGValues.values
                                $null = Add-ParallelAssetTagFieldValue -AssetFields $AssetFields -Field $field -LinkedItems $AssetsLinked -AssetName $UpdateAsset.Name -Messages $messages
                            }
                            'SslCertificates' {
                                $null = $messages.Add("Tags to SSL Certificates are not supported $($field.FieldName) in $($UpdateAsset.Name) will need to be manually migrated, Sorry!")
                                $supported = $false
                            }
                            'Tickets' {
                                $null = $messages.Add("Tags to Tickets are not supported $($field.FieldName) in $($UpdateAsset.Name) will need to be manually migrated, Sorry!")
                                $supported = $false
                            }
                            'AccountsUsers' {
                                $null = $messages.Add("Tags to Account Users are not supported $($field.FieldName) in $($UpdateAsset.Name) will need to be manually migrated, Sorry!")
                                $supported = $false
                            }
                        }
                    } elseif ($field.FieldType -eq 'Password') {
                        $PasswordIds = @(
                            $ITGValues
                            $ITGValues.values
                        ) | ForEach-Object {
                            if ($null -ne $_) {
                                $candidate = if ($_.PSObject.Properties['id']) {
                                    $_.id
                                } elseif ($_.PSObject.Properties['resource-id']) {
                                    $_.'resource-id'
                                } elseif ($_.PSObject.Properties['resource_id']) {
                                    $_.'resource_id'
                                } elseif ($_ -is [string] -or $_.GetType().IsValueType) {
                                    $_
                                } else {
                                    $null
                                }

                                if (-not [string]::IsNullOrWhiteSpace([string]$candidate)) {
                                    [string]$candidate
                                }
                            }
                        } | Select-Object -Unique

                        if (-not [string]::IsNullOrWhiteSpace($itgKey) -and -not [string]::IsNullOrWhiteSpace($itgApiEndpoint)) {
                            Import-Module ITGlueAPIv2 -ErrorAction SilentlyContinue
                            if (Get-Command -Name Add-ITGlueBaseURI -ErrorAction SilentlyContinue) {
                                Add-ITGlueBaseURI -base_uri $itgApiEndpoint
                            }
                            if (Get-Command -Name Add-ITGlueAPIKey -ErrorAction SilentlyContinue) {
                                Add-ITGlueAPIKey $itgKey
                            }
                        }

                        $PasswordFieldWasSet = $false
                        foreach ($PasswordId in $PasswordIds) {
                            $ITGPassword = $null
                            $ITGPasswordValue = $null
                            $MigratedPasswordStatus = 'Skipped'

                            try {
                                $ITGPassword = (Get-ITGluePasswords -id $PasswordId -include related_items).data
                                $ITGPasswordValue = $passwordValueMap[[string]$ITGPassword.id]

                                if ($ITGPasswordValue) {
                                    if (-not $PasswordFieldWasSet) {
                                        $AssetFields["$($field.HuduParsedName)"] = $ITGPasswordValue
                                        $PasswordFieldWasSet = $true
                                        $MigratedPasswordStatus = 'Into Asset'
                                    } else {
                                        $ManualLog = [PSCustomObject]@{
                                            Document_Name = $UpdateAsset.Name
                                            Type          = 'Asset Field - Password'
                                            Company_Name  = $UpdateAsset.HuduObject.company_name
                                            HuduID        = $UpdateAsset.HuduID
                                            Field_Name    = "$($field.HuduParsedName)"
                                            Notes         = 'Multiple embedded IT Glue passwords were found for one Hudu password field. The first value was added to the asset field.'
                                            Action        = 'Manually review whether this additional password should be migrated elsewhere'
                                            Data          = ($ITGPassword.attributes.'resource-url' -replace '[^\x09\x0A\x0D\x20-\xD7FF\xE000-\xFFFD\x10000\x10FFFF]')
                                            Hudu_URL      = $UpdateAsset.HuduObject.url
                                            ITG_URL       = $UpdateAsset.ITGObject.attributes.'resource-url'
                                        }
                                        $null = $manualActions.Add($ManualLog)
                                        $MigratedPasswordStatus = 'Manual Review - Additional Embedded Password'
                                    }
                                }
                            } catch {
                                $null = $messages.Add('Error occured adding field, possible duplicate name')
                                $ManualLog = [PSCustomObject]@{
                                    Document_Name = $UpdateAsset.Name
                                    Type          = 'Asset Field - Password'
                                    Company_Name  = $UpdateAsset.HuduObject.company_name
                                    HuduID        = $UpdateAsset.HuduID
                                    Field_Name    = "$($field.HuduParsedName)"
                                    Notes         = "Failed to add password to Asset with error $_"
                                    Action        = 'Manually add the password to the asset'
                                    Data          = ($ITGPassword.attributes.'resource-url' -replace '[^\x09\x0A\x0D\x20-\xD7FF\xE000-\xFFFD\x10000\x10FFFF]')
                                    Hudu_URL      = $UpdateAsset.HuduObject.url
                                    ITG_URL       = $UpdateAsset.ITGObject.attributes.'resource-url'
                                }
                                $null = $manualActions.Add($ManualLog)
                                $MigratedPasswordStatus = 'Failed to add'
                            }

                            if ($ITGPassword) {
                                $MigratedPassword = [PSCustomObject]@{
                                    Name      = $ITGPassword.attributes.name
                                    ITGID     = $ITGPassword.id
                                    HuduID    = $UpdateAsset.HuduID
                                    Matched   = $true
                                    ITGObject = $ITGPassword
                                    Imported  = $MigratedPasswordStatus
                                }
                                $null = $matchedAssetPasswords.Add($MigratedPassword)
                            }
                        }
                    } elseif ($field.FieldType -eq 'Number') {
                        $coerced = Get-ParallelCastIfNumeric ($ITGValues -replace '[^\x09\x0A\x0D\x20-\xD7FF\xE000-\xFFFD\x10000\x10FFFF]')
                        $AssetFields["$($field.HuduParsedName)"] = [string]"$coerced"
                    } elseif ($field.FieldType -ieq 'Upload') {
                        $uploadFieldsArePresent = $true
                        continue
                    } else {
                        $AssetFields["$($field.HuduParsedName)"] = [string]"$ITGValues"
                    }
                } else {
                    $null = $messages.Add("Warning $ITGParsed : $ITGValues Could not be added")
                }
            }

            $CleanedAssetFields = @()
            foreach ($entry in $AssetFields.GetEnumerator()) {
                $fieldName = ($entry.Key -replace '_', ' ').Trim()
                $value = $entry.Value

                if ([string]::IsNullOrWhiteSpace($fieldName)) { continue }
                if ($null -eq $value) { continue }
                if ($value -is [string] -and [string]::IsNullOrWhiteSpace($value)) { continue }
                if ($value -is [array] -and $value.Count -eq 0) { continue }
                if ($value -is [string] -and $value.Trim() -in @('[]', '[,,]', '[,]', 'null')) { continue }

                $CleanedAssetFields += @{ $fieldName = $value }
            }

            $stopwatch.Stop()
            [pscustomobject]@{
                Status                 = 'prepared'
                Index                  = $UpdateAsset.PreparationIndex
                AssetUpdateRequest     = [pscustomobject]@{
                    Index         = $UpdateAsset.PreparationIndex
                    AssetId       = [int]$UpdateAsset.HuduID
                    Name          = $UpdateAsset.name
                    CompanyId     = [int]$UpdateAsset.HuduObject.company_id
                    AssetLayoutId = [int]$UpdateAsset.HuduObject.asset_layout_id
                    Fields        = @($CleanedAssetFields)
                    SourceAsset   = $UpdateAsset
                }
                SourceAsset            = $UpdateAsset
                RelationsToCreate      = @($relationsToCreate)
                HuduRelationsToCreate  = @($huduRelationsToCreate)
                ManualActions          = @($manualActions)
                MatchedAssetPasswords  = @($matchedAssetPasswords)
                UploadFieldsArePresent = $uploadFieldsArePresent
                Messages               = @($messages)
                ElapsedSeconds         = [math]::Round($stopwatch.Elapsed.TotalSeconds, 3)
                Error                  = $null
            }
        } catch {
            $stopwatch.Stop()
            [pscustomobject]@{
                Status                 = 'failed'
                Index                  = $UpdateAsset.PreparationIndex
                AssetUpdateRequest     = $null
                SourceAsset            = $UpdateAsset
                RelationsToCreate      = @($relationsToCreate)
                HuduRelationsToCreate  = @($huduRelationsToCreate)
                ManualActions          = @($manualActions)
                MatchedAssetPasswords  = @($matchedAssetPasswords)
                UploadFieldsArePresent = $uploadFieldsArePresent
                Messages               = @($messages)
                ElapsedSeconds         = [math]::Round($stopwatch.Elapsed.TotalSeconds, 3)
                Error                  = $_.Exception.Message
            }
        }
    } -ThrottleLimit $ThrottleLimit
}
