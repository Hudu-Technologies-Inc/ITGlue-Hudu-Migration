$LinkReplacementJobPublicRoot = Split-Path -Parent $PSScriptRoot
$LinkReplacementJobProjectRoot = Split-Path -Parent $LinkReplacementJobPublicRoot

############################## Update ITGlue URLs on All Areas to Hudu #######################

$null = Start-MigrationJob -Name "LinkReplacement"

Reset-HuduURLReplacementLookup
$null = Initialize-HuduURLReplacementLookup -Force

$UpdatePasswords = $MatchedPasswords | Where-Object { Test-ITGlueURLReplacementCandidate -Content ([string]$_.HuduObject.description) }
$UpdateAssetPasswords = $MatchedAssetPasswords | Where-Object { Test-ITGlueURLReplacementCandidate -Content ([string]$_.ITGObject.attributes.notes) }
$UpdateCompanyNotes = $MatchedCompanies | Where-Object { Test-ITGlueURLReplacementCandidate -Content ([string]$_.HuduCompanyObject.notes) }

Write-Host "Article content link replacement will run after attachments are uploaded so IT Glue URLs, hard-coded images, attachment links, and hosted image anchors can be applied in one article update." -ForegroundColor Cyan

Write-Host "Asset rich text link replacement will run after attachments are uploaded so IT Glue links, image links, and attachment links can be handled in one asset update." -ForegroundColor Cyan

# Passwords
$passwordsUpdated = @()
foreach ($passwordFound in $UpdatePasswords.HuduObject) {
    $NewContent = Convert-ITGlueLinksToHudu -Content $passwordFound.description -Type "plain"
    if ($NewContent -and $NewContent -ne $passwordFound.description) {
        Write-Host "Updating Password $($passwordFound.name) with updated description" -ForegroundColor 'Green'
        $passwordsUpdated = $passwordsUpdated + @{"original_password" = $passwordFound; "updated_password" = (Set-HuduPassword -id $passwordFound.id -Description $NewContent).asset_password}
    }
}
$passwordsUpdated | ConvertTo-Json -depth 100 |Out-file "$MigrationLogs\ReplacedPasswordsURL.json"
Write-TimedMessage -Timeout 3 -Message  "Snapshot Point: Password URLs Replaced. Continue?"  -DefaultResponse "continue to Asset Passwords Matching, please."

# Asset Passwords
$assetPasswordsUpdated = @()
foreach ($passwordFound in $UpdateAssetPasswords) {
    $passwordFound = Get-HuduPasswords -id $passwordFound.HuduID
    $NewContent = Convert-ITGlueLinksToHudu -Content $passwordFound.description -Type "plain"
    if ($NewContent -and $NewContent -ne $passwordFound.description)   {
        Write-Host "Updating Asset Password $($passwordFound.name) with updated description" -ForegroundColor 'Green'
        $assetPasswordsUpdated = $assetPasswordsUpdated + @{"original_password" = $passwordFound; "updated_password" = (Set-HuduPassword -Id $passwordFound.id -Description $NewContent).asset_password}
    }

}
$assetPasswordsUpdated | ConvertTo-Json -depth 100 |Out-file "$MigrationLogs\ReplacedAssetPasswordsURL.json"
Write-TimedMessage -Timeout 3 -Message  "Snapshot Point: Asset Passwords URLs Replaced. Continue?"  -DefaultResponse "continue to Company Notes, please."

# Company Notes
$companyNotesUpdated = @()
foreach ($companyFound in $UpdateCompanyNotes.HuduCompanyObject) {
    $NewContent = Convert-ITGlueLinksToHudu -Content $companyFound.notes -Type "rich"
    if ($NewContent -and $NewContent -ne $companyFound.notes) {
        Write-Host "Updating Company $($companyFound.name) with updated notes" -ForegroundColor 'Green'
        $companyNotesUpdated = $companyNotesUpdated + @{"original_company" = $companyFound; "updated_company" = (Set-HuduCompany -id $companyFound.id -Notes $NewContent).company}
    }

}
$companyNotesUpdated | ConvertTo-Json -depth 100 |Out-file "$MigrationLogs\ReplacedCompaniesURL.json"
Write-TimedMessage -Timeout 3 -Message "Snapshot Point: Company Notes URLs Replaced. Continue?"  -DefaultResponse "continue to Manual Actions, please."

############################### Wrap-Up ###############################

write-host "wrapup 1/10... setting asset layouts as active, enabling advanced website monitoring features" -ForegroundColor DarkCyan; $null = Start-MigrationJob -Name "Wrap-Up - Layouts";
foreach ($layout in Get-HuduAssetLayouts) {write-host "setting $($(Set-HuduAssetLayout -id $layout.id -Active $true).asset_layout.name) as active" }
if ($true -eq $DisableWebsiteMonitoring) {write-host "leaving websites unmonitored per user-config"} else {$MatchedWebsites.HuduObject | Where-Object {$_.id -and $_.id -gt 0} | Foreach-Object {write-host "Enabling advanced monitoring features for $($(Set-HuduWebsite -id $_.id -EnableDMARC 'true' -EnableDKIM 'true' -EnableSPF 'true' -DisableDNS 'false' -DisableSSL 'false' -DisableWhois 'false' -Paused 'false').name)" -ForegroundColor DarkCyan}}

write-host "wrapup 2/10... adding attachments and replacing any found attachment links (this can take a while)" ; $null = Start-MigrationJob -Name "Wrap-Up - Attachments";
. (Join-Path $LinkReplacementJobProjectRoot 'Add-HuduAttachmentsViaAPI.ps1')

Write-Host "Articles - replacing IT Glue links, hard-coded images, attachment links, and hosted image anchors in one pass"; $null = Start-MigrationJob -Name "Wrap-Up - Article Link Replacement";
if (-not $(Get-Command -Name Set-HuduImageAnchorsReplaced -ErrorAction SilentlyContinue)) { . (Join-Path $LinkReplacementJobPublicRoot 'Set-HuduImageAnchorsReplaced.ps1') }

$AttachmentUrlMapForReplacement = try {
    Get-AttachmentUrlMap
} catch {
    Write-Warning "Attachment URL map unavailable during article link replacement: $($_.Exception.Message)"
    @{}
}
$AttachmentUrlLookupForReplacement = if ($AttachmentUrlMapForReplacement -and $AttachmentUrlMapForReplacement.Count -gt 0) {
    New-AttachmentUrlReplacementLookup -UrlMap (ConvertTo-RelativeUrlMap -UrlMap $AttachmentUrlMapForReplacement)
} else {
    @{}
}

$ArticleContentCommitCandidates = @($MatchedArticles | Where-Object { $_ -and ($_.HuduID ?? $_.id) })
$StandaloneImageArticlePhotoResults = [System.Collections.ArrayList]@()
$UseFastArticleContentCommit = $UseFastArticleContentCommit ?? $true
if ($UseFastArticleContentCommit -and -not (Get-Command -Name Invoke-FastHuduArticleContentCommit -ErrorAction SilentlyContinue)) {
    . (Join-Path $LinkReplacementJobPublicRoot 'Invoke-FastArticleCommit.ps1')
}
if (-not (Get-Command -Name New-HuduArticleStandaloneMediaEmbed -ErrorAction SilentlyContinue)) {
    . (Join-Path $LinkReplacementJobPublicRoot 'ArticleMediaEmbed.ps1')
}

$preparedArticleCommits = [System.Collections.ArrayList]@()
$articlePreCommitFailures = [System.Collections.ArrayList]@()
$articleCommitIndex = 0
$convertStandalonePhotoArticlesEnabled = Test-HuduMigrationSettingEnabled $convertStandalonePhotoArticles
$articleContentStageProgressId = 41
$articleContentCommitProgressId = 42
$articleContentStageTotal = @($ArticleContentCommitCandidates).Count
$articleContentStageIndex = 0

foreach ($articleFound in $ArticleContentCommitCandidates) {
    $articleContentStageIndex++
    if ($articleContentStageTotal -gt 0) {
        $articleContentStagePercent = [math]::Min(99, [math]::Floor(($articleContentStageIndex / $articleContentStageTotal) * 100))
        Write-Progress -Id $articleContentStageProgressId -Activity "Staging article content for commit" -Status "Article $articleContentStageIndex of $articleContentStageTotal`: $($articleFound.name)" -PercentComplete $articleContentStagePercent
    }

    $localArticleContent = Get-HuduArticleLocalContent -Article $articleFound
    if ($null -eq $localArticleContent) {
        $message = "Local article HTML was not found for '$($articleFound.name)' at '$($articleFound.LocalContentPath)'. Refusing to use Hudu-returned content as a fallback."
        Write-Warning $message
        $null = $articlePreCommitFailures.Add([pscustomobject]@{
            status             = 'failed'
            article_id         = $articleFound.HuduID ?? $articleFound.id
            article_name       = $articleFound.name
            original_article   = $articleFound
            source_content_path = $articleFound.LocalContentPath
            replacement_sets   = @()
            error              = $message
        })
        continue
    }

    $UpdatedContent = Update-HuduContentLinks `
        -Content $localArticleContent `
        -Type 'rich' `
        -ImageMap $ImageMap `
        -AttachmentUrlMap $AttachmentUrlMapForReplacement `
        -AttachmentUrlLookup $AttachmentUrlLookupForReplacement `
        -IncludeHardcodedImages `
        -IncludeAttachments `
        -IncludeHostedImageAnchors `
        -IncludeUploads

    $finalArticleContent = $UpdatedContent.Content
    $standaloneAttachmentNoteApplied = $false
    if ($finalArticleContent -eq 'Empty Document in IT Glue Export - Please Check IT Glue' -and $articleFound.name -ilike '*.*') {
        $standaloneArticleFileKind = Get-HuduStandaloneArticleFileKind -Path ([string]$articleFound.name)
        if ($standaloneArticleFileKind -eq 'Image' -and $convertStandalonePhotoArticlesEnabled) {
            $standaloneImagePhoto = New-HuduArticleStandaloneImagePhoto -Article $articleFound -ExportPath $ITGlueExportPath -MatchedCompanies $MatchedCompanies
            if ($standaloneImagePhoto) {
                $finalArticleContent = $standaloneImagePhoto.Content
                $articleFound | Add-Member -MemberType NoteProperty -Name StandaloneImageArticlePhotoCreated -Value $true -Force
                $articleFound | Add-Member -MemberType NoteProperty -Name StandaloneImageArticlePhotoId -Value $standaloneImagePhoto.PhotoId -Force
                $articleFound | Add-Member -MemberType NoteProperty -Name StandaloneImageArticlePhotoFile -Value $standaloneImagePhoto.File.FullName -Force
                $articleFound | Add-Member -MemberType NoteProperty -Name StandaloneImageArticlePhotoFolderId -Value $standaloneImagePhoto.FolderId -Force
                $articleFound | Add-Member -MemberType NoteProperty -Name StandaloneImageArticlePhotoFolderPath -Value $standaloneImagePhoto.FolderPath -Force
                $articleFound | Add-Member -MemberType NoteProperty -Name StandaloneImageArticleArchiveOriginal -Value $true -Force
                $null = $StandaloneImageArticlePhotoResults.Add($standaloneImagePhoto)
                Write-Host "Converted standalone image article '$($articleFound.name)' to Hudu photo '$($standaloneImagePhoto.File.Name)'; original article will be archived." -ForegroundColor Cyan
            } else {
                $finalArticleContent = "Please see attached file, $($articleFound.name)"
            }
        } elseif ($standaloneArticleFileKind -eq 'Image') {
            $finalArticleContent = "Please see attached file, $($articleFound.name)"
        } elseif ($standaloneArticleFileKind -in @('Audio', 'Video')) {
            if ($articleContentStageTotal -gt 0) {
                Write-Progress -Id $articleContentStageProgressId -Activity "Staging article content for commit" -Status "Article $articleContentStageIndex of $articleContentStageTotal`: embedding standalone $($standaloneArticleFileKind.ToLowerInvariant())" -PercentComplete $articleContentStagePercent
            }
            if ($standaloneMediaEmbed = New-HuduArticleStandaloneMediaEmbed -Article $articleFound -ExportPath $ITGlueExportPath) {
                $finalArticleContent = $standaloneMediaEmbed.Content
                Write-Host "Embedded standalone $($standaloneMediaEmbed.Kind.ToLowerInvariant()) upload '$($standaloneMediaEmbed.File.Name)' in article $($articleFound.name)." -ForegroundColor Cyan
            } else {
                $finalArticleContent = "Please see attached file, $($articleFound.name)"
            }
        } else {
            $finalArticleContent = "Please see attached file, $($articleFound.name)"
        }
        $standaloneAttachmentNoteApplied = $true
    }
    $finalContentPath = $articleFound.LocalContentPath

    $status = if ($UpdatedContent.Changed -or $standaloneAttachmentNoteApplied) { 'replaced' } else { 'committed' }
    Write-Host "Preparing Article $($articleFound.name) from local HTML for commit ($status)" -ForegroundColor 'Green'
    try {
        $finalContentPath = Set-HuduArticleLocalContent -Article $articleFound -Content $finalArticleContent -MigrationLogsPath $MigrationLogs -DebugFolderPath $debugFolder
        $ArticleSplat = @{
            Id      = $articleFound.HuduID ?? $articleFound.id
            Content = $finalArticleContent
        }
        if ($articleFound.name) { $ArticleSplat.Name = $articleFound.name }
        $articleUsesGlobalKB = if ($null -ne $articleFound.PSObject.Properties['IsGlobalKBArticle']) {
            [bool]$articleFound.IsGlobalKBArticle
        } else {
            [bool]($articleFound.company.InternalCompany -and -not $PlaceInternalDocsInInternalCompany)
        }
        if (-not $articleUsesGlobalKB -and $articleFound.company.HuduID) {
            $ArticleSplat.CompanyId = $articleFound.company.HuduID
        } elseif ($articleFound.company_id) {
            $ArticleSplat.CompanyId = $articleFound.company_id
        }

        $null = $preparedArticleCommits.Add([pscustomobject]@{
            Index                              = $articleCommitIndex
            ArticleSplat                       = $ArticleSplat
            ArticleId                          = $ArticleSplat.Id
            ArticleName                        = $articleFound.name
            Name                               = $ArticleSplat['Name']
            CompanyId                          = $ArticleSplat['CompanyId']
            Content                            = $finalArticleContent
            OriginalArticle                    = $articleFound
            SourceContentPath                  = $finalContentPath
            ExpectedStatus                     = $status
            StandaloneAttachmentNoteApplied    = $standaloneAttachmentNoteApplied
            ReplacementSets                    = $UpdatedContent.ReplacementSets
        })
        $articleCommitIndex++
    } catch {
        $null = $articlePreCommitFailures.Add([pscustomobject]@{
            status             = 'failed'
            article_id         = $articleFound.HuduID ?? $articleFound.id
            article_name       = $articleFound.name
            original_article   = $articleFound
            source_content_path = $finalContentPath
            attempted_changes  = $finalArticleContent
            standalone_attachment_note_applied = $standaloneAttachmentNoteApplied
            replacement_sets   = $UpdatedContent.ReplacementSets
            error              = $_.Exception.Message
        })
    }
}
Write-Progress -Id $articleContentStageProgressId -Activity "Staging article content for commit" -Completed

$null = Start-MigrationJob -Name "Wrap-Up - Article Content Commit"
try {
    $articleContentCommitTotal = @($preparedArticleCommits).Count
    $articleCommitTransportResults = if ($articleContentCommitTotal -gt 0 -and $UseFastArticleContentCommit) {
        $fastArticleCommitParams = @{
            CommitRequests = @($preparedArticleCommits)
            ThrottleLimit  = $MigrationParallelismLimit
        }
        if ($HuduFastCommitHeaders -and $HuduFastCommitHeaders.Count -gt 0) {
            $fastArticleCommitParams.CustomHeaders = $HuduFastCommitHeaders
        }
        Write-Progress -Id $articleContentCommitProgressId -Activity "Committing article content" -Status "Fast commit in progress: $articleContentCommitTotal article(s) with $MigrationParallelismLimit worker(s)" -PercentComplete 0
        Invoke-FastHuduArticleContentCommit @fastArticleCommitParams
    } elseif ($articleContentCommitTotal -gt 0) {
        $articleContentCommitIndex = 0
        foreach ($commitRequest in @($preparedArticleCommits)) {
            $articleContentCommitIndex++
            $articleContentCommitPercent = [math]::Min(99, [math]::Floor(($articleContentCommitIndex / $articleContentCommitTotal) * 100))
            Write-Progress -Id $articleContentCommitProgressId -Activity "Committing article content" -Status "Article $articleContentCommitIndex of $articleContentCommitTotal`: $($commitRequest.ArticleName)" -PercentComplete $articleContentCommitPercent
            $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            try {
                $articleSplat = $commitRequest.ArticleSplat
                $updatedArticle = Set-HuduArticle @articleSplat -ErrorAction Stop
                $stopwatch.Stop()
                [pscustomobject]@{
                    Status         = 'committed'
                    Index          = $commitRequest.Index
                    ArticleId      = $commitRequest.ArticleId
                    ArticleName    = $commitRequest.ArticleName
                    UpdatedArticle = $updatedArticle.article ?? $updatedArticle
                    Attempts       = 1
                    SleptSeconds   = 0
                    ElapsedSeconds = [math]::Round($stopwatch.Elapsed.TotalSeconds, 3)
                    StatusCode     = 200
                }
            } catch {
                $stopwatch.Stop()
                [pscustomobject]@{
                    Status         = 'failed'
                    Index          = $commitRequest.Index
                    ArticleId      = $commitRequest.ArticleId
                    ArticleName    = $commitRequest.ArticleName
                    UpdatedArticle = $null
                    Attempts       = 1
                    SleptSeconds   = 0
                    ElapsedSeconds = [math]::Round($stopwatch.Elapsed.TotalSeconds, 3)
                    StatusCode     = $null
                    Error          = $_.Exception.Message
                }
            }
        }
    } else {
        @()
    }
} finally {
    Write-Progress -Id $articleContentCommitProgressId -Activity "Committing article content" -Completed
    $null = Complete-MigrationJob -Name "Wrap-Up - Article Content Commit" -CompletedAt (Get-Date)
}

$articleCommitTransportResultsByIndex = @{}
foreach ($commitResult in @($articleCommitTransportResults)) {
    $articleCommitTransportResultsByIndex[[string]$commitResult.Index] = $commitResult
}

$articleCommitResults = foreach ($commitRequest in @($preparedArticleCommits | Sort-Object Index)) {
    $commitResult = $articleCommitTransportResultsByIndex[[string]$commitRequest.Index]
    if (-not $commitResult) {
        [pscustomobject]@{
            status                             = 'failed'
            article_id                         = $commitRequest.ArticleId
            article_name                       = $commitRequest.ArticleName
            original_article                   = $commitRequest.OriginalArticle
            source_content_path                = $commitRequest.SourceContentPath
            attempted_changes                  = $commitRequest.Content
            standalone_attachment_note_applied = $commitRequest.StandaloneAttachmentNoteApplied
            replacement_sets                   = $commitRequest.ReplacementSets
            error                              = 'No article commit result was returned.'
        }
        continue
    }

    if ($commitResult.Status -eq 'committed') {
        $updatedArticleObject = $commitResult.UpdatedArticle.article ?? $commitResult.UpdatedArticle
        $updatedArticleSummary = [pscustomobject]@{
            id         = $updatedArticleObject.id ?? $commitRequest.ArticleId
            name       = $updatedArticleObject.name ?? $commitRequest.ArticleName
            company_id = $updatedArticleObject.company_id ?? $commitRequest.CompanyId
            url        = $updatedArticleObject.url ?? $commitRequest.OriginalArticle.HuduObject.url
        }
        $commitRequest.OriginalArticle | Add-Member -MemberType NoteProperty -Name LocalContentCommittedAt -Value (Get-Date).ToString('o') -Force

        [pscustomobject]@{
            status                             = $commitRequest.ExpectedStatus
            article_id                         = $commitRequest.ArticleId
            article_name                       = $commitRequest.ArticleName
            original_article                   = $commitRequest.OriginalArticle
            updated_article                    = $updatedArticleSummary
            source_content_path                = $commitRequest.SourceContentPath
            standalone_attachment_note_applied = $commitRequest.StandaloneAttachmentNoteApplied
            replacement_sets                   = $commitRequest.ReplacementSets
            commit_attempts                    = $commitResult.Attempts
            commit_elapsed_seconds            = $commitResult.ElapsedSeconds
            commit_slept_seconds              = $commitResult.SleptSeconds
            commit_mode                        = if ($UseFastArticleContentCommit) { 'direct-put' } else { 'set-huduarticle' }
        }
    } else {
        [pscustomobject]@{
            status                             = 'failed'
            article_id                         = $commitRequest.ArticleId
            article_name                       = $commitRequest.ArticleName
            original_article                   = $commitRequest.OriginalArticle
            source_content_path                = $commitRequest.SourceContentPath
            attempted_changes                  = $commitRequest.Content
            standalone_attachment_note_applied = $commitRequest.StandaloneAttachmentNoteApplied
            replacement_sets                   = $commitRequest.ReplacementSets
            error                              = $commitResult.Error
            commit_attempts                    = $commitResult.Attempts
            commit_elapsed_seconds            = $commitResult.ElapsedSeconds
            commit_slept_seconds              = $commitResult.SleptSeconds
            commit_status_code                 = $commitResult.StatusCode
            commit_mode                        = if ($UseFastArticleContentCommit) { 'direct-put' } else { 'set-huduarticle' }
        }
    }
}

$articlesUpdated = @($articlePreCommitFailures.ToArray()) + @($articleCommitResults)

$articlesUpdated | ConvertTo-Json -Depth 100 | Out-File "$MigrationLogs\ReplacedArticlesURL.json"
$MatchedArticles | ConvertTo-Json -Depth 100 | Out-File "$MigrationLogs\Articles.json"
$replacedAttachmentURLs = @(
    $articlesUpdated | Where-Object { $_.replacement_sets.Type -contains 'AttachmentLinks' } | ForEach-Object {
        [pscustomobject]@{
            Status       = $_.status
            ArticleId    = $_.article_id
            ArticleName  = $_.article_name
            Replacements = @($_.replacement_sets | Where-Object { $_.Type -eq 'AttachmentLinks' } | ForEach-Object { $_.Replacements })
        }
    }
)
$replacedAttachmentURLs | ConvertTo-Json -Depth 100 | Out-File "$MigrationLogs\ReplacedAttachmentLinks.json"
$imageAnchorReplacementResults = @(
    $articlesUpdated | Where-Object { $_.replacement_sets.Type -contains 'HostedImageAnchors' } | ForEach-Object {
        [pscustomobject]@{
            Status      = $_.status
            ArticleId   = $_.article_id
            ArticleName = $_.article_name
        }
    }
)
$imageAnchorReplacementResults | ConvertTo-Json -Depth 100 | Out-File "$MigrationLogs\ReplacedImageAnchors.json"

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

Write-Host "Assets - replacing rich text image and attachment links now that upload maps are available"
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
