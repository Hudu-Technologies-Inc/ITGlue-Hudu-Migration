function ConvertTo-AttachmentUrlHashtable {
param(
    $MapObject
)
    if ($MapObject -is [hashtable]) { return $MapObject }

    $Hashtable = @{}

    if ($MapObject -is [System.Collections.IDictionary]) {
        foreach ($Key in $MapObject.Keys) {
            $Hashtable[[string]$Key] = [string]$MapObject[$Key]
        }
        return $Hashtable
    }

    foreach ($Property in $MapObject.PSObject.Properties) {
        if ($Property.MemberType -in 'NoteProperty','Property') {
            $Hashtable[[string]$Property.Name] = [string]$Property.Value
        }
    }

    return $Hashtable
}

function Get-AttachmentUrlMap {
param(
    [string]$MapPath = "$MigrationLogs\AttachmentUrlMap.json"
)
    if ($AttachmentUrlMap -and $AttachmentUrlMap.Count -gt 0) {
        return ConvertTo-AttachmentUrlHashtable -MapObject $AttachmentUrlMap
    }

    if (-not (Test-Path $MapPath)) {
        throw "Attachment URL map was not found at '$MapPath'. Run Add-HuduAttachmentsViaAPI.ps1 first."
    }

    $MapObject = Get-Content -Path $MapPath -Raw | ConvertFrom-Json -Depth 100
    return ConvertTo-AttachmentUrlHashtable -MapObject $MapObject
}

function Get-AttachmentUrlReplacementCandidates {
param(
    [string]$OriginalUrl
)
    $Candidates = @($OriginalUrl)

    try {
        $ParsedUrl = [Uri]$OriginalUrl
        if ($ParsedUrl.IsAbsoluteUri) {
            $Candidates += $ParsedUrl.PathAndQuery

            if ($ParsedUrl.AbsolutePath -match '/(?:files|attachments)/(?<AttachmentId>\d{1,20})(?:/|$)') {
                $AttachmentId = $Matches.AttachmentId
                $AttachmentPaths = @(
                    "/attachments/$AttachmentId"
                    "/attachments/$AttachmentId`?edit"
                    "/attachments/$AttachmentId`?edit=1"
                    "/attachments/$AttachmentId`?edit=true"
                    "/attachments/$AttachmentId`?preview"
                    "/attachments/$AttachmentId`?preview=1"
                    "/attachments/$AttachmentId`?preview=true"
                )

                foreach ($AttachmentPath in $AttachmentPaths) {
                    $Candidates += $AttachmentPath
                    $Candidates += "$($ParsedUrl.GetLeftPart([UriPartial]::Authority))$AttachmentPath"
                }
            }
        }
        elseif ($OriginalUrl -match '/(?:files|attachments)/(?<AttachmentId>\d{1,20})(?=$|[/?#])') {
            $AttachmentId = $Matches.AttachmentId
            $Candidates += "/attachments/$AttachmentId"
            $Candidates += "/attachments/$AttachmentId`?edit"
            $Candidates += "/attachments/$AttachmentId`?edit=1"
            $Candidates += "/attachments/$AttachmentId`?edit=true"
            $Candidates += "/attachments/$AttachmentId`?preview"
            $Candidates += "/attachments/$AttachmentId`?preview=1"
            $Candidates += "/attachments/$AttachmentId`?preview=true"
        }
    }
    catch {}

    foreach ($Candidate in @($Candidates | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique | Sort-Object Length -Descending)) {
        [pscustomobject]@{
            Url           = $Candidate
            IsHtmlEncoded = $false
            IsRelative    = $Candidate.StartsWith('/')
        }

        $HtmlEncodedCandidate = [System.Net.WebUtility]::HtmlEncode($Candidate)
        if ($HtmlEncodedCandidate -and $HtmlEncodedCandidate -ne $Candidate) {
            [pscustomobject]@{
                Url           = $HtmlEncodedCandidate
                IsHtmlEncoded = $true
                IsRelative    = $Candidate.StartsWith('/')
            }
        }
    }
}

function Get-ITGlueAttachmentUrls {
param(
    [AllowEmptyString()]
    [string]$Content
)
    if ([string]::IsNullOrWhiteSpace($Content)) { return @() }

    $AttachmentPattern = '(?:https?://[^"''\s<>]+)?/attachments/\d{1,20}(?:\?(?:edit|preview)(?:=(?:1|true))?)?'
    @(
        [regex]::Matches($Content, $AttachmentPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase) |
            ForEach-Object { $_.Value } |
            Select-Object -Unique
    )
}

function Update-ContentWithAttachmentUrlMap {
param(
    [AllowEmptyString()]
    [string]$Content,
    [hashtable]$UrlMap
)
    $NewContent = $Content
    $Replacements = @()

    foreach ($OriginalUrl in @($UrlMap.Keys | Sort-Object Length -Descending)) {
        if ([string]::IsNullOrWhiteSpace($OriginalUrl) -or [string]::IsNullOrWhiteSpace($UrlMap[$OriginalUrl])) { continue }

        foreach ($Candidate in @(Get-AttachmentUrlReplacementCandidates -OriginalUrl $OriginalUrl)) {
            $CandidateUrl = $Candidate.Url
            $CandidatePattern = [regex]::Escape($CandidateUrl)
            if ($Candidate.IsRelative) {
                $CandidatePattern = "(?<![A-Za-z0-9._~%+-])$CandidatePattern"
            }
            if ($CandidateUrl -notmatch '\?' -and $CandidateUrl -match '/(?:files|attachments)/\d{1,20}$') {
                $CandidatePattern = "$CandidatePattern(?![/?#])"
            }

            $Count = [regex]::Matches($NewContent, $CandidatePattern).Count
            if ($Count -lt 1) { continue }

            $ReplacementUrl = if ($Candidate.IsHtmlEncoded) {
                [System.Net.WebUtility]::HtmlEncode($UrlMap[$OriginalUrl])
            } else {
                $UrlMap[$OriginalUrl]
            }

            $NewContent = [regex]::Replace(
                $NewContent,
                $CandidatePattern,
                [System.Text.RegularExpressions.MatchEvaluator]{ param($match) $ReplacementUrl }
            )
            $Replacements += [pscustomobject]@{
                OriginalUrl    = $OriginalUrl
                MatchedUrl     = $CandidateUrl
                ReplacementUrl = $ReplacementUrl
                Count          = $Count
            }
        }
    }

    [pscustomobject]@{
        Content      = $NewContent
        Changed      = ($NewContent -ne $Content)
        Replacements = $Replacements
    }
}

function ConvertTo-HuduAssetFieldKey {
param(
    [string]$Label
)
    if ([string]::IsNullOrWhiteSpace($Label)) { return $null }

    (($Label -replace '[^\w\s]', '') -replace '\s+', '_').ToLower()
}

function Get-HuduAssetFieldEntry {
param(
    $Field
)
    if ($Field.label) {
        return [pscustomobject]@{
            Label = $Field.label
            Key   = ConvertTo-HuduAssetFieldKey -Label $Field.label
            Value = $Field.value
        }
    }

    if ($Field -is [System.Collections.IDictionary] -and $Field.Keys.Count -eq 1) {
        $Key = [string]@($Field.Keys)[0]
        return [pscustomobject]@{
            Label = $Key
            Key   = ConvertTo-HuduAssetFieldKey -Label $Key
            Value = $Field[$Key]
        }
    }

    $Properties = @($Field.PSObject.Properties | Where-Object { $_.MemberType -in 'NoteProperty','Property' })
    if ($Properties.Count -eq 1) {
        return [pscustomobject]@{
            Label = [string]$Properties[0].Name
            Key   = ConvertTo-HuduAssetFieldKey -Label $Properties[0].Name
            Value = $Properties[0].Value
        }
    }

    $Label = $Field.label
    return [pscustomobject]@{
        Label = $Label
        Key   = ConvertTo-HuduAssetFieldKey -Label $Label
        Value = $Field.value
    }
}

function Get-HuduAssetLayoutId {
param(
    $Asset
)
    return $Asset.asset_layout_id ?? $Asset.asset_layout.id
}

function Get-HuduAssetLayoutFields {
param(
    $Asset,
    [object[]]$AssetLayouts,
    [hashtable]$AssetLayoutCache
)
    if ($Asset.asset_layout) {
        $EmbeddedFields = @($Asset.asset_layout.field) + @($Asset.asset_layout.fields)
        $EmbeddedFields = @($EmbeddedFields | Where-Object { $_ })
        if ($EmbeddedFields.Count -gt 0) { return $EmbeddedFields }
    }

    $LayoutId = Get-HuduAssetLayoutId -Asset $Asset
    if (-not $LayoutId) { return @() }

    if ($AssetLayoutCache -and $AssetLayoutCache.ContainsKey([string]$LayoutId)) {
        $CachedLayout = $AssetLayoutCache[[string]$LayoutId]
        return @($CachedLayout.field) + @($CachedLayout.fields) | Where-Object { $_ }
    }

    $Layout = $null
    if ($AssetLayouts) {
        $Layout = $AssetLayouts | Where-Object {
            $_.id -eq $LayoutId -or $_.HuduID -eq $LayoutId -or $_.HuduObject.id -eq $LayoutId
        } | Select-Object -First 1
        $Layout = $Layout.HuduObject ?? $Layout.asset_layout ?? $Layout
    }

    if (-not $Layout -and $MatchedLayouts) {
        $Layout = $MatchedLayouts | Where-Object {
            $_.id -eq $LayoutId -or $_.HuduID -eq $LayoutId -or $_.HuduObject.id -eq $LayoutId
        } | Select-Object -First 1
        $Layout = $Layout.HuduObject ?? $Layout.asset_layout ?? $Layout
    }

    if (-not $Layout -and (Get-Command Get-HuduAssetLayouts -ErrorAction SilentlyContinue)) {
        $Layout = Get-HuduAssetLayouts -layoutid $LayoutId
        $Layout = $Layout.asset_layout ?? $Layout
    }

    if ($Layout -and $AssetLayoutCache) {
        $AssetLayoutCache[[string]$LayoutId] = $Layout
    }

    return @($Layout.field) + @($Layout.fields) | Where-Object { $_ }
}

function Test-HuduAssetFieldIsRichText {
param(
    $Asset,
    $Field,
    [object[]]$AssetLayouts,
    [hashtable]$AssetLayoutCache
)
    $FieldEntry = Get-HuduAssetFieldEntry -Field $Field
    $FieldLabel = $FieldEntry.Label
    $FieldKey = $FieldEntry.Key

    $FieldTypeValues = @(
        $Field.field_type
        $Field.fieldType
        $Field.type
        $Field.field_kind
        $Field.kind
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    if ($FieldTypeValues) {
        return [bool]($FieldTypeValues | Where-Object { "$_" -ieq 'RichText' -or "$_" -ieq 'Textbox' })
    }

    $LayoutFields = Get-HuduAssetLayoutFields -Asset $Asset -AssetLayouts $AssetLayouts -AssetLayoutCache $AssetLayoutCache
    foreach ($LayoutField in $LayoutFields) {
        $LayoutFieldKey = ConvertTo-HuduAssetFieldKey -Label $LayoutField.label
        if ($LayoutFieldKey -eq $FieldKey) {
            return ($LayoutField.field_type -ieq 'RichText')
        }
    }

    $LayoutId = Get-HuduAssetLayoutId -Asset $Asset
    if ($AllFields -and $FieldKey) {
        $MatchedField = $AllFields | Where-Object {
            $FieldMatches = $_.HuduParsedName -eq $FieldKey -or $_.FieldName -eq $FieldLabel
            $LayoutMatches = -not $LayoutId -or $_.HuduLayoutID -eq $LayoutId
            $FieldMatches -and $LayoutMatches
        } | Select-Object -First 1

        if ($MatchedField) {
            if ($MatchedField.HuduLayoutField.field_type -ieq 'RichText') { return $true }
            if ($MatchedField.FieldType -ieq 'Textbox') { return $true }
            if ($MatchedField.FieldType -ieq 'RichText') { return $true }
            return $false
        }
    }

    if ($FieldEntry.Value -is [string] -and $FieldEntry.Value -match '<(?:a|p|br|div|span|table|ul|ol|li|img)\b') {
        return $true
    }

    return $false
}

function Get-HuduAssetsForAttachmentLinkReplacement {
    if ($MatchedAssets) {
        return @($MatchedAssets | ForEach-Object { $_.HuduObject ?? $_.asset ?? $_ } | Where-Object { $_ })
    }

    if (Get-Command Get-HuduAssets -ErrorAction SilentlyContinue) {
        return @(Get-HuduAssets)
    }

    return @()
}

function Update-HuduAssetFieldsWithAttachmentUrlMap {
[CmdletBinding(SupportsShouldProcess)]
param(
    [object[]]$Assets,
    [hashtable]$UrlMap,
    [object[]]$AssetLayouts
)
    $AssetLayoutCache = @{}
    $Results = foreach ($AssetInput in $Assets) {
        $Asset = $AssetInput.HuduObject ?? $AssetInput.asset ?? $AssetInput
        if (-not $Asset -or -not $Asset.fields) {
            [pscustomobject]@{
                Status       = 'skipped'
                ObjectType   = 'asset'
                AssetId      = $Asset.id
                AssetName    = $Asset.name
                Reason       = 'no fields'
                Replacements = @()
            }
            continue
        }

        $CustomFields = @()
        $AssetReplacements = @()
        $UnresolvedAttachmentUrls = @()

        foreach ($Field in $Asset.fields) {
            $FieldEntry = Get-HuduAssetFieldEntry -Field $Field
            $FieldLabel = $FieldEntry.Label
            $FieldKey = $FieldEntry.Key
            if ([string]::IsNullOrWhiteSpace($FieldKey)) { continue }
            if ([string]::IsNullOrWhiteSpace($FieldLabel)) { continue }

            $FieldValue = $FieldEntry.Value
            if (Test-HuduAssetFieldIsRichText -Asset $Asset -Field $Field -AssetLayouts $AssetLayouts -AssetLayoutCache $AssetLayoutCache) {
                $Updated = Update-ContentWithAttachmentUrlMap -Content "$FieldValue" -UrlMap $UrlMap

                if ($Updated.Changed) {
                    Write-Host "Replacing $($Updated.Replacements.Count) attachment URL set(s) in asset '$($Asset.name)' field '$FieldLabel'" -ForegroundColor Green
                    $FieldValue = $Updated.Content
                    $CustomFields += @{ $FieldLabel = $FieldValue }
                    $AssetReplacements += foreach ($Replacement in $Updated.Replacements) {
                        [pscustomobject]@{
                            FieldName      = $FieldLabel
                            OriginalUrl    = $Replacement.OriginalUrl
                            MatchedUrl     = $Replacement.MatchedUrl
                            ReplacementUrl = $Replacement.ReplacementUrl
                            Count          = $Replacement.Count
                        }
                    }
                }
                else {
                    $UnresolvedAttachmentUrls += Get-ITGlueAttachmentUrls -Content "$FieldValue" |
                        ForEach-Object {
                            [pscustomobject]@{
                                FieldName = $FieldLabel
                                Url       = $_
                            }
                        }
                }
            }
        }

        if ($AssetReplacements.Count -lt 1) {
            if ($UnresolvedAttachmentUrls.Count -gt 0) {
                [pscustomobject]@{
                    Status                   = 'unresolved'
                    ObjectType               = 'asset'
                    AssetId                  = $Asset.id
                    AssetName                = $Asset.name
                    Reason                   = 'attachment URLs found in rich text fields but no AttachmentUrlMap match'
                    UnresolvedAttachmentUrls = $UnresolvedAttachmentUrls
                    Replacements             = @()
                }
                continue
            }

            [pscustomobject]@{
                Status       = 'clean'
                ObjectType   = 'asset'
                AssetId      = $Asset.id
                AssetName    = $Asset.name
                Reason       = 'no attachment URLs found in rich text fields'
                Replacements = @()
            }
            continue
        }

        try {
            $UpdatedAsset = $null
            if ($PSCmdlet.ShouldProcess("Asset $($Asset.id) '$($Asset.name)'", "replace attachment links in rich text fields")) {
                $UpdatedAssetResponse = Set-HuduAsset -asset_id $Asset.id -name $Asset.name -company_id $Asset.company_id -asset_layout_id (Get-HuduAssetLayoutId -Asset $Asset) -fields $CustomFields -ErrorAction Stop
                $UpdatedAsset = $UpdatedAssetResponse.asset ?? $UpdatedAssetResponse
            }

            [pscustomobject]@{
                Status       = if ($WhatIfPreference) { 'whatif' } else { 'replaced' }
                ObjectType   = 'asset'
                AssetId      = $Asset.id
                AssetName    = $Asset.name
                Replacements = $AssetReplacements
                UpdatedAsset = $UpdatedAsset
            }
        }
        catch {
            [pscustomobject]@{
                Status       = 'failed'
                ObjectType   = 'asset'
                AssetId      = $Asset.id
                AssetName    = $Asset.name
                Error        = $_.Exception.Message
                Replacements = $AssetReplacements
            }
        }
    }

    return $Results
}

function Start-HuduAttachmentLinkReplacement {
[CmdletBinding(SupportsShouldProcess)]
param(
    [object[]]$Articles,
    [object[]]$Assets,
    [object[]]$AssetLayouts,
    [hashtable]$UrlMap,
    [string]$MapPath = "$MigrationLogs\AttachmentUrlMap.json",
    [string]$OutputPath = "$MigrationLogs\ReplacedAttachmentLinks.json"
)
    if (-not $UrlMap) {
        $UrlMap = Get-AttachmentUrlMap -MapPath $MapPath
    }

    if (-not $UrlMap -or $UrlMap.Count -lt 1) {
        Write-Warning "Attachment URL map is empty. No articles or assets were updated."
        return @()
    }

    if (-not $Articles) {
        $Articles = @(Get-HuduArticles)
    }

    if (-not $PSBoundParameters.ContainsKey('Assets')) {
        $Assets = @(Get-HuduAssetsForAttachmentLinkReplacement)
    }

    $ArticleResults = foreach ($Article in $Articles) {
        if ([string]::IsNullOrEmpty($Article.content)) {
            [pscustomobject]@{
                Status       = 'skipped'
                ObjectType   = 'article'
                ArticleId    = $Article.id
                ArticleName  = $Article.name
                Reason       = 'empty content'
                Replacements = @()
            }
            continue
        }

        $Updated = Update-ContentWithAttachmentUrlMap -Content $Article.content -UrlMap $UrlMap
        if (-not $Updated.Changed) {
            $UnresolvedAttachmentUrls = Get-ITGlueAttachmentUrls -Content $Article.content
            if ($UnresolvedAttachmentUrls.Count -gt 0) {
                [pscustomobject]@{
                    Status                   = 'unresolved'
                    ObjectType               = 'article'
                    ArticleId                = $Article.id
                    ArticleName              = $Article.name
                    Reason                   = 'attachment URLs found but no AttachmentUrlMap match'
                    UnresolvedAttachmentUrls = $UnresolvedAttachmentUrls
                    Replacements             = @()
                }
                continue
            }

            [pscustomobject]@{
                Status       = 'clean'
                ObjectType   = 'article'
                ArticleId    = $Article.id
                ArticleName  = $Article.name
                Reason       = 'no attachment URLs found'
                Replacements = @()
            }
            continue
        }

        Write-Host "Replacing $($Updated.Replacements.Count) attachment URL set(s) in article '$($Article.name)'" -ForegroundColor Green

        try {
            $UpdatedArticle = $null
            if ($PSCmdlet.ShouldProcess("Article $($Article.id) '$($Article.name)'", "replace attachment links")) {
                $SetArticleSplat = @{
                    Id      = $Article.id
                    Content = $Updated.Content
                }
                if ($Article.name) { $SetArticleSplat.Name = $Article.name }
                if ($Article.company_id) { $SetArticleSplat.CompanyId = $Article.company_id }

                $UpdatedArticle = Set-HuduArticle @SetArticleSplat -ErrorAction Stop
            }

            [pscustomobject]@{
                Status       = if ($WhatIfPreference) { 'whatif' } else { 'replaced' }
                ObjectType   = 'article'
                ArticleId    = $Article.id
                ArticleName  = $Article.name
                Replacements = $Updated.Replacements
                UpdatedArticle = $UpdatedArticle
            }
        }
        catch {
            [pscustomobject]@{
                Status       = 'failed'
                ObjectType   = 'article'
                ArticleId    = $Article.id
                ArticleName  = $Article.name
                Error        = $_.Exception.Message
                Replacements = $Updated.Replacements
            }
        }
    }

    $AssetResults = Update-HuduAssetFieldsWithAttachmentUrlMap -Assets $Assets -UrlMap $UrlMap -AssetLayouts $AssetLayouts -WhatIf:$WhatIfPreference
    $Results = @($ArticleResults) + @($AssetResults)

    $Results | ConvertTo-Json -Depth 100 | Out-File $OutputPath -WhatIf:$false
    return $Results
}
