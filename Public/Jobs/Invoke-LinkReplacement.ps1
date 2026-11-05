# Stage article replacements and local content for the separate commit phase.
$LinkReplacementJobPublicRoot = Split-Path -Parent $PSScriptRoot
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
if (-not (Get-Command -Name New-HuduArticleStandaloneMediaEmbed -ErrorAction SilentlyContinue)) {
    . (Join-Path $LinkReplacementJobPublicRoot 'ArticleMediaEmbed.ps1')
}

$preparedArticleCommits = [System.Collections.ArrayList]@()
$articlePreCommitFailures = [System.Collections.ArrayList]@()
$articleCommitIndex = 0
$convertStandalonePhotoArticlesEnabled = Test-HuduMigrationSettingEnabled $convertStandalonePhotoArticles
$articleContentStageProgressId = 41
$articleContentStageTotal = @($ArticleContentCommitCandidates).Count
$articleContentStageIndex = 0

if (-not (Get-Command -Name Invoke-HuduArticleLinkReplacement -ErrorAction SilentlyContinue)) {
    . (Join-Path $LinkReplacementJobPublicRoot 'Invoke-HuduArticleLinkReplacement.ps1')
}
$articleLinkReplacementParams = @{
    Articles = $ArticleContentCommitCandidates
    ImageMap = $ImageMap
    AttachmentUrlLookup = $AttachmentUrlLookupForReplacement
    ThrottleLimit = $ArticleLinkReplacementThrottleLimit ?? [math]::Max(1, [math]::Min(8, [math]::Min([Environment]::ProcessorCount, [int]($MigrationParallelismLimit ?? 8))))
}
Invoke-HuduArticleLinkReplacement @articleLinkReplacementParams | ForEach-Object {
    $articleLinkResult = $_
    $articleFound = $ArticleContentCommitCandidates[$articleLinkResult.Index]
    $articleContentStageIndex++
    if ($articleContentStageTotal -gt 0) {
        $articleContentStagePercent = [math]::Min(99, [math]::Floor(($articleContentStageIndex / $articleContentStageTotal) * 100))
        Write-Progress -Id $articleContentStageProgressId -Activity "Staging article content for commit" -Status "Article $articleContentStageIndex of $articleContentStageTotal`: $($articleFound.name)" -PercentComplete $articleContentStagePercent
    }

    if ($articleLinkResult.Error) {
        $message = $articleLinkResult.Error
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
        return
    }

    $UpdatedContent = $articleLinkResult.UpdatedContent

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
