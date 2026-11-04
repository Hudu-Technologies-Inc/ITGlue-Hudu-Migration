# Commit the requests prepared by Invoke-LinkReplacement.ps1 and write reports.
$articleContentCommitProgressId = 42
$UseFastArticleContentCommit = $UseFastArticleContentCommit ?? $true
if ($UseFastArticleContentCommit -and -not (Get-Command -Name Invoke-FastHuduArticleContentCommit -ErrorAction SilentlyContinue)) {
    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'Invoke-FastArticleCommit.ps1')
}

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
