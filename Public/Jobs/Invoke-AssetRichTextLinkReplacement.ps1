param(
    [AllowNull()]
    [hashtable]$AttachmentUrlMapForReplacement,

    [AllowNull()]
    [hashtable]$AttachmentUrlLookupForReplacement
)

$AssetLinkReplacementPublicRoot = Split-Path -Parent $PSScriptRoot
if (-not (Get-Command -Name Set-HuduImageAnchorsReplaced -ErrorAction SilentlyContinue)) {
    . (Join-Path $AssetLinkReplacementPublicRoot 'Set-HuduImageAnchorsReplaced.ps1')
}
# The main migration reuses the article maps. Separate invocations can obtain
# their own maps after attachments have been uploaded.
if ($null -eq $AttachmentUrlMapForReplacement) {
    $AttachmentUrlMapForReplacement = try {
        Get-AttachmentUrlMap
    } catch {
        Write-Warning "Attachment URL map unavailable during asset link replacement: $($_.Exception.Message)"
        @{}
    }
}
if ($null -eq $AttachmentUrlLookupForReplacement) {
    $AttachmentUrlLookupForReplacement = New-AttachmentUrlReplacementLookup -UrlMap (ConvertTo-RelativeUrlMap -UrlMap $AttachmentUrlMapForReplacement)
}

function Get-HuduAssetFieldLabel {
    param(
        [AllowNull()]
        $Field
    )

    foreach ($candidate in @($Field.label, $Field.field_name, $Field.fieldName, $Field.name, $Field.caption)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$candidate)) {
            return [string]$candidate
        }
    }

    return $null
}

function Get-NormalizedHuduFieldLabel {
    param(
        [AllowNull()]
        [string]$Label
    )

    if ([string]::IsNullOrWhiteSpace($Label)) {
        return $null
    }

    return ($Label.Trim() -replace '[^\w\s]', '' -replace '\s+', '_').ToLower()
}

function New-HuduRichTextFieldLookup {
    param(
        [AllowNull()]
        $LayoutFields
    )

    $lookup = @{}
    foreach ($field in @($LayoutFields)) {
        $huduField = $field.HuduLayoutField
        $fieldType = $huduField.field_type ?? $field.FieldType
        if ($fieldType -ne 'RichText') {
            continue
        }

        $layoutId = [string]($field.HuduLayoutID ?? $huduField.asset_layout_id)
        if ([string]::IsNullOrWhiteSpace($layoutId)) {
            continue
        }

        if (-not $lookup.ContainsKey($layoutId)) {
            $lookup[$layoutId] = @{}
        }

        foreach ($label in @($huduField.label, $field.FieldName, $field.HuduParsedName)) {
            $normalized = Get-NormalizedHuduFieldLabel -Label ([string]$label)
            if ($normalized) {
                $lookup[$layoutId][$normalized] = $true
            }
        }
    }

    return $lookup
}

function Test-HuduAssetFieldIsRichText {
    param(
        [AllowNull()]
        $Field,

        [AllowNull()]
        [hashtable]$RichTextFieldLookup,

        [AllowNull()]
        $AssetLayoutId
    )

    if (($Field.field_type ?? $Field.fieldType ?? $Field.type) -eq 'RichText') {
        return $true
    }

    $layoutId = [string]$AssetLayoutId
    if ([string]::IsNullOrWhiteSpace($layoutId) -or -not $RichTextFieldLookup.ContainsKey($layoutId)) {
        return $false
    }

    $fieldLabel = Get-HuduAssetFieldLabel -Field $Field
    $normalizedLabel = Get-NormalizedHuduFieldLabel -Label $fieldLabel
    return ($normalizedLabel -and $RichTextFieldLookup[$layoutId].ContainsKey($normalizedLabel))
}

$RichTextFieldsByLayout = New-HuduRichTextFieldLookup -LayoutFields $AllFields
$AssetRichTextLinkCandidates = @(
    $MatchedAssets.HuduObject | Where-Object { $RichTextFieldsByLayout.ContainsKey([string]$_.asset_layout_id) } | Where-Object {
        $assetLayoutId = $_.asset_layout_id
        @($_.fields | Where-Object {
            if (Test-HuduAssetFieldIsRichText -Field $_ -RichTextFieldLookup $RichTextFieldsByLayout -AssetLayoutId $assetLayoutId) {
                Test-HuduContentLinkReplacementCandidate `
                    -Content ([string]$_.value) `
                    -Type 'rich' `
                    -ImageMap $ImageMap `
                    -AttachmentUrlMap $AttachmentUrlMapForReplacement `
                    -IncludeHardcodedImages `
                    -IncludeAttachments `
                    -IncludeHostedImageAnchors `
                    -IncludeUploads
            } else {
                $false
            }
        }).Count -gt 0
    }
)
Write-Host "Asset rich text link candidates: $($AssetRichTextLinkCandidates.Count) asset(s) across $($RichTextFieldsByLayout.Count) layout(s) with RichText fields." -ForegroundColor Cyan
$assetRichTextLinkResults = foreach ($assetFound in $AssetRichTextLinkCandidates) {
    $customFields = @()
    $replacementSets = @()

    foreach ($field in @($assetFound.fields)) {
        if (-not (Test-HuduAssetFieldIsRichText -Field $field -RichTextFieldLookup $RichTextFieldsByLayout -AssetLayoutId $assetFound.asset_layout_id)) {
            continue
        }

        $fieldContent = [string]$field.value
        if (-not (Test-HuduContentLinkReplacementCandidate `
                    -Content $fieldContent `
                    -Type 'rich' `
                    -ImageMap $ImageMap `
                    -AttachmentUrlMap $AttachmentUrlMapForReplacement `
                    -IncludeHardcodedImages `
                    -IncludeAttachments `
                    -IncludeHostedImageAnchors `
                    -IncludeUploads)) {
            continue
        }

        $updatedField = Update-HuduContentLinks `
            -Content $fieldContent `
            -Type 'rich' `
            -ImageMap $ImageMap `
            -AttachmentUrlMap $AttachmentUrlMapForReplacement `
            -AttachmentUrlLookup $AttachmentUrlLookupForReplacement `
            -IncludeHardcodedImages `
            -IncludeAttachments `
            -IncludeHostedImageAnchors `
            -IncludeUploads

        if (-not $updatedField.Changed) {
            continue
        }

        $label = Get-HuduAssetFieldLabel -Field $field
        if ([string]::IsNullOrWhiteSpace([string]$label)) {
            Write-Warning "Skipping changed rich text field on asset $($assetFound.name) because Hudu did not return a field label."
            continue
        }

        $customFields += @{ $label = $updatedField.Content }
        $replacementSets += [pscustomobject]@{
            Field           = $label
            ReplacementSets = $updatedField.ReplacementSets
        }
    }

    if ($customFields.Count -lt 1) {
        continue
    }

    Write-Host "Updating Asset $($assetFound.name) with rich text image/attachment link replacement(s)" -ForegroundColor Green
    try {
        $AssetPost = Set-HuduAsset -Id $assetFound.id -CompanyId $assetFound.company_id -Fields $customFields
        [pscustomobject]@{
            status           = 'replaced'
            original_asset   = $assetFound
            updated_asset    = $AssetPost.asset ?? $AssetPost
            replacement_sets = $replacementSets
        }
    } catch {
        [pscustomobject]@{
            status            = 'failed'
            original_asset    = $assetFound
            attempted_fields  = $customFields
            replacement_sets  = $replacementSets
            error             = $_.Exception.Message
        }
    }
}
$assetRichTextLinkResults | ConvertTo-Json -Depth 100 | Out-File "$MigrationLogs\ReplacedAssetRichTextLinks.json"
