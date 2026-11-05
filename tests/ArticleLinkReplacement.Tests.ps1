#requires -Version 7.2
# Offline equivalence, failure isolation, streaming, and pool cleanup checks.
param([switch]$Benchmark)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$ITGURL = 'https://custom.example.invalid'
$HuduBaseDomain = 'https://hudu.example.invalid'
$settings = @{ HuduBaseDomain = 'https://alias.example.invalid' }
$environmentSettings = @{ HuduBaseDomain = 'https://other.example.invalid' }
function Get-HuduBaseURL { 'https://hudu.example.invalid' }
. "$repoRoot/Private/ConvertTo-HuduURL.ps1"
. "$repoRoot/Public/ReplaceAttachmentLinks.ps1"
. "$repoRoot/Public/Set-HuduImageAnchorsReplaced.ps1"
. "$repoRoot/Public/ArticleContentLocalCache.ps1"
. "$repoRoot/Public/Invoke-HuduArticleLinkReplacement.ps1"
$checks = 0
function Assert-ArticleLinks {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    $script:checks++
}
function New-LinkTarget {
    param($Id, $Url, $Name = 'Target')
    [pscustomobject]@{ ITGID = $Id; ITGLocator = "DOC-1-$Id"; HuduObject = [pscustomobject]@{ url = $Url; name = $Name } }
}
$MatchedArticles = @(New-LinkTarget '11' "$HuduBaseDomain/kba/doc" '文档 & name')
$MatchedPasswords = @(New-LinkTarget '12' "$HuduBaseDomain/passwords/password")
$MatchedConfigurations = @(New-LinkTarget '13' 'http://alias.example.invalid/assets/config')
$MatchedAssets = @(New-LinkTarget '14' 'https://other.example.invalid/assets/flex')
$MatchedContacts = @(New-LinkTarget '15' "$HuduBaseDomain/assets/contact")
$MatchedWebsites = @(New-LinkTarget '16' "$HuduBaseDomain/websites/domain")
$MatchedCompanies = @(New-LinkTarget '1' "$HuduBaseDomain/companies/company")
$null = Initialize-HuduURLReplacementLookup -Force
$ImageMap = [ordered]@{
    'C:\images\screenshot.png' = "$HuduBaseDomain/public_photo/first"
    'C:\images\other.jpg' = "$HuduBaseDomain/public_photos/other"
    'C:\collision\screenshot.png' = "$HuduBaseDomain/public_photo/second"
}
$attachmentMap = @{
    'https://tenant.itglue.com/1/docs/11/files/71' = "$HuduBaseDomain/uploads/71?download=1&name=a"
    'https://tenant.itglue.com/attachments/72?preview=true' = "$HuduBaseDomain/uploads/72"
}
$attachmentLookup = New-AttachmentUrlReplacementLookup -UrlMap (ConvertTo-RelativeUrlMap $attachmentMap)
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) "itglue-article-links-$([guid]::NewGuid().ToString('N'))"
$null = [IO.Directory]::CreateDirectory($fixtureRoot)
$lock = $null
try {
    $contents = @(
        '<p>Untouched 文档 &amp; notes</p>',
        '<a class="kept" href="https://custom.example.invalid/1/docs/11">Original <strong>text</strong></a>',
        '<a href="http://another.itglue.com/1/passwords/12">password</a>',
        '<a href="/1/configurations/13">config</a> <a href="/1/assets/type/14">flex</a>',
        '<a href="/1/contacts/15">contact</a> <a href="/1/domains/16">domain</a> <a href="/1/domains">company</a>',
        '<a href="/DOC-1-11">locator</a> <a href="https://custom.example.invalid/DOC-1-11">absolute locator</a>',
        '<p>https://tenant.itglue.com/1/docs/11 and /1/passwords/12</p>',
        '<a href="/1/docs/999">unmatched</a><a href="https://external.invalid/">external</a>',
        '<img alt="kept" src="https://tenant.itglue.com/1/docs/11/images/screenshot.png"><img src="documents/export/images/screenshot">',
        '<a href="/1/docs/11/files/71">file</a> <a href="/attachments/72?preview=true">preview</a>',
        '<a href="https://old.invalid/"><img src="https://hudu.example.invalid/public_photo/first"></a><img src="/uploads/71">',
        '<a href="https://external.invalid/"><img src="https://external.invalid/logo.png"></a>',
        'Empty Document in IT Glue Export - Please Check IT Glue',
        '   ',
        '<a href="/1/docs/11">doc</a><img src="/1/docs/11/images/other.jpg"><a href="/attachments/72?preview=true">file</a>'
    )
    $articles = @(for ($i = 0; $i -lt 60; $i++) {
        $path = Join-Path $fixtureRoot "$i.html"
        [IO.File]::WriteAllText($path, $contents[$i % $contents.Count], [Text.UTF8Encoding]::new($false))
        [pscustomobject]@{ HuduID = $i + 1; name = "Article $i"; LocalContentPath = $path }
    })
    $expected = @(foreach ($article in $articles) {
        Update-HuduContentLinks -Content (Get-HuduArticleLocalContent $article) -ImageMap $ImageMap `
            -AttachmentUrlLookup $attachmentLookup -IncludeHardcodedImages -IncludeAttachments -IncludeHostedImageAnchors -IncludeUploads 6>$null
    })
    Assert-ArticleLinks ($expected[2].Content.Contains('/passwords/password')) 'Serial fixture did not exercise password replacement.'
    Assert-ArticleLinks ($expected[8].Content.Contains('/public_photo/first') -and -not $expected[8].Content.Contains('/public_photo/second')) 'Image collisions no longer retain the first mapping.'
    Assert-ArticleLinks (($expected[14].ReplacementSets.Type -join ',') -ceq 'ITGlueLinks,HardcodedImages,AttachmentLinks,HostedImageAnchors') 'The combined fixture did not exercise every replacement phase in order.'
    $mapBefore = $ImageMap | ConvertTo-Json -Compress
    foreach ($workers in @(1, 8)) {
        $actual = @(Invoke-HuduArticleLinkReplacement -Articles $articles -ImageMap $ImageMap -AttachmentUrlLookup $attachmentLookup -ThrottleLimit $workers 6>$null)
        Assert-ArticleLinks ($actual.Count -eq $articles.Count) "Missing results with $workers worker(s)."
        for ($i = 0; $i -lt $articles.Count; $i++) {
            Assert-ArticleLinks ($actual[$i].Index -eq $i -and -not $actual[$i].Error) "Article failed or results reordered at $i with $workers workers: $($actual[$i].Error)"
            Assert-ArticleLinks ($actual[$i].UpdatedContent.Content -ceq $expected[$i].Content) "HTML differs at $i with $workers worker(s)."
            Assert-ArticleLinks (($actual[$i].UpdatedContent | ConvertTo-Json -Depth 30 -Compress) -ceq ($expected[$i] | ConvertTo-Json -Depth 30 -Compress)) "Replacement reports differ at $i with $workers worker(s)."
        }
    }
    Assert-ArticleLinks (($ImageMap | ConvertTo-Json -Compress) -ceq $mapBefore) 'Workers mutated the caller image map.'
    Assert-ArticleLinks ($script:HuduURLReplacementLookup.docs['11'].Source -eq $MatchedArticles[0]) 'Workers changed the parent URL lookup.'
    Assert-ArticleLinks (@(Invoke-HuduArticleLinkReplacement -Articles @() 6>$null).Count -eq 0) 'An empty batch produced results.'

    $emptyPath = Join-Path $fixtureRoot 'empty.html'
    [IO.File]::WriteAllText($emptyPath, '')
    $lockedPath = Join-Path $fixtureRoot 'locked.html'
    [IO.File]::WriteAllText($lockedPath, 'locked')
    $lock = [IO.File]::Open($lockedPath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $badArticles = @(
        @{ name = 'missing'; LocalContentPath = (Join-Path $fixtureRoot 'missing.html') },
        @{ name = 'blank path'; LocalContentPath = '' },
        @{ name = 'empty'; LocalContentPath = $emptyPath },
        @{ name = 'locked'; LocalContentPath = $lockedPath },
        $articles[14]
    )
    $failed = @(Invoke-HuduArticleLinkReplacement -Articles $badArticles -ImageMap $ImageMap -AttachmentUrlLookup $attachmentLookup -ThrottleLimit 3 6>$null)
    Assert-ArticleLinks ($failed.Count -eq 5) 'A failed article terminated the batch.'
    foreach ($failure in $failed[0..3]) {
        Assert-ArticleLinks ($failure.Error -and $null -eq $failure.UpdatedContent) 'A missing/unreadable article was prepared for commit.'
    }
    Assert-ArticleLinks ($failed[4].UpdatedContent.Content -ceq $expected[14].Content) 'A failure contaminated the next article.'
    $lock.Dispose(); $lock = $null

    # Downstream work runs before the next article window is scheduled. Removing
    # the first unscheduled file must be observed, rather than having preloaded
    # all source HTML or queued an unbounded number of completed results.
    $streamed = @(Invoke-HuduArticleLinkReplacement -Articles $articles -ImageMap $ImageMap -AttachmentUrlLookup $attachmentLookup -ThrottleLimit 3 6>$null | ForEach-Object {
        if ($_.Index -eq 0) { [IO.File]::Delete($articles[3].LocalContentPath) }
        $_
    })
    Assert-ArticleLinks ($streamed[3].Error -and $streamed[4].UpdatedContent.Content -ceq $expected[4].Content) 'Article processing did not apply backpressure or isolate a streaming failure.'
    [IO.File]::WriteAllText($articles[3].LocalContentPath, $contents[3])
    $openBefore = @(Get-Runspace | Where-Object { $_.RunspaceStateInfo.State -eq 'Opened' }).Count
    $null = Invoke-HuduArticleLinkReplacement -Articles $articles -ThrottleLimit 4 6>$null | Select-Object -First 1
    Assert-ArticleLinks (@(Get-Runspace | Where-Object { $_.RunspaceStateInfo.State -eq 'Opened' }).Count -eq $openBefore) 'Stopping downstream left worker runspaces open.'
    try {
        Invoke-HuduArticleLinkReplacement -Articles $articles -ThrottleLimit 4 6>$null | ForEach-Object { throw 'downstream failure' }
        throw 'The downstream failure was swallowed.'
    } catch {
        Assert-ArticleLinks ($_.Exception.Message -eq 'downstream failure') 'The wrong downstream error was propagated.'
    }
    Assert-ArticleLinks (@(Get-Runspace | Where-Object { $_.RunspaceStateInfo.State -eq 'Opened' }).Count -eq $openBefore) 'A downstream error left worker runspaces open.'

    # Run the real staging pipeline, including its serial media branch and local
    # writes, without entering any migration jobs or performing API requests.
    $jobSource = Get-Content -LiteralPath "$repoRoot/Public/Jobs/Invoke-LinkReplacement.ps1" -Raw
    $stageStart = $jobSource.IndexOf('$preparedArticleCommits =')
    $stageScript = [scriptblock]::Create($jobSource.Substring($stageStart))
    $realContentWriter = (Get-Command Set-HuduArticleLocalContent).ScriptBlock
    foreach ($photosEnabled in @($false, $true)) {
        & {
            $ArticleContentCommitCandidates = @(for ($i = 0; $i -lt 8; $i++) {
                $name = @('normal', 'missing', 'write-failure', 'photo.png', 'audio.mp3', 'video.mp4', 'file.pdf', 'global')[$i]
                $path = Join-Path $fixtureRoot "stage-$i.html"
                if ($i -ne 1) {
                    $html = if ($i -in 3..6) { $contents[12] } else { $contents[14] }
                    [IO.File]::WriteAllText($path, $html)
                }
                [pscustomobject]@{
                    name = $name; HuduID = 1000 + $i; LocalContentPath = $path
                    company = @{ HuduID = 777; InternalCompany = $false }
                    company_id = $null; IsGlobalKBArticle = ($i -eq 7)
                }
            })
            $LinkReplacementJobPublicRoot = Join-Path $repoRoot 'Public'
            $AttachmentUrlLookupForReplacement = $attachmentLookup
            $ArticleLinkReplacementThrottleLimit = 3
            $MigrationParallelismLimit = 28
            $convertStandalonePhotoArticles = $photosEnabled
            $PlaceInternalDocsInInternalCompany = $false
            $ITGlueExportPath = $fixtureRoot
            $MigrationLogs = Join-Path $fixtureRoot 'logs'
            $debugFolder = $fixtureRoot
            $StandaloneImageArticlePhotoResults = [Collections.ArrayList]::new()
            $mediaActions = [Collections.Generic.List[string]]::new()
            function Test-HuduMigrationSettingEnabled { param($Value) return [bool]$Value }
            function Get-HuduStandaloneArticleFileKind {
                param($Path)
                switch ([IO.Path]::GetExtension($Path)) { '.png' { 'Image' }; '.mp3' { 'Audio' }; '.mp4' { 'Video' }; default { 'Other' } }
            }
            function New-HuduArticleStandaloneImagePhoto {
                param($Article, $ExportPath, $MatchedCompanies)
                $mediaActions.Add($Article.name)
                @{ Content = '<p>photo created</p>'; PhotoId = 123; File = [IO.FileInfo]::new((Join-Path $fixtureRoot $Article.name)); FolderId = 7; FolderPath = 'photos' }
            }
            function New-HuduArticleStandaloneMediaEmbed {
                param($Article, $ExportPath)
                $mediaActions.Add($Article.name)
                @{ Content = "<p>media $($Article.name)</p>"; Kind = (Get-HuduStandaloneArticleFileKind $Article.name); File = [IO.FileInfo]::new((Join-Path $fixtureRoot $Article.name)) }
            }
            function Set-HuduArticleLocalContent {
                param($Article, $Content, $MigrationLogsPath, $DebugFolderPath)
                if ($Article.name -eq 'write-failure') { throw 'simulated local write failure' }
                & $realContentWriter @PSBoundParameters
            }
            . $stageScript 3>$null 6>$null
            Assert-ArticleLinks ($articlePreCommitFailures.Count -eq 2 -and $preparedArticleCommits.Count -eq 6) 'Staging lost successful articles or committed a failed preparation.'
            Assert-ArticleLinks (($preparedArticleCommits.ArticleId -join ',') -ceq '1000,1003,1004,1005,1006,1007') 'Staging changed article order or mapping.'
            Assert-ArticleLinks (($preparedArticleCommits.Index -join ',') -ceq '0,1,2,3,4,5') 'Staging commit indexes have gaps or duplicates.'
            Assert-ArticleLinks ($preparedArticleCommits[0].Content -ceq $expected[14].Content -and $preparedArticleCommits[0].ArticleSplat.CompanyId -eq 777) 'Staging changed HTML or company assignment.'
            Assert-ArticleLinks (-not $preparedArticleCommits[5].ArticleSplat.ContainsKey('CompanyId')) 'A global KB article was assigned to a company.'
            $expectedActions = if ($photosEnabled) { 'photo.png,audio.mp3,video.mp4' } else { 'audio.mp3,video.mp4' }
            Assert-ArticleLinks (($mediaActions -join ',') -ceq $expectedActions) 'Serial media API actions changed order or ignored the photo conversion setting.'
            Assert-ArticleLinks ($StandaloneImageArticlePhotoResults.Count -eq [int]$photosEnabled) 'Photo conversion results were lost or duplicated.'
            Assert-ArticleLinks ($preparedArticleCommits[4].Content -ceq 'Please see attached file, file.pdf') 'Standalone attachment note was lost.'
            foreach ($request in $preparedArticleCommits) {
                Assert-ArticleLinks (([IO.File]::ReadAllText($request.SourceContentPath)) -ceq $request.Content) 'Saved HTML differs from the staged commit payload.'
            }

            # Exercise the extracted commit/report helper in both transport modes.
            function Set-HuduArticle {
                param($Id, $Content, $Name, $CompanyId, $ErrorAction)
                if ($Id -eq 1005) { throw 'simulated commit failure' }
                @{ article = @{ id = $Id; name = $Name; company_id = $CompanyId; url = "/kba/$Id" } }
            }
            function Invoke-FastHuduArticleContentCommit {
                param($CommitRequests, $ThrottleLimit, $CustomHeaders)
                foreach ($request in $CommitRequests) {
                    [pscustomobject]@{
                        Index = $request.Index; Status = $(if ($request.ArticleId -eq 1005) { 'failed' } else { 'committed' })
                        UpdatedArticle = @{ id = $request.ArticleId; name = $request.Name; company_id = $request.CompanyId; url = "/kba/$($request.ArticleId)" }
                        Attempts = 1; ElapsedSeconds = 0; SleptSeconds = 0; StatusCode = 200; Error = 'simulated commit failure'
                    }
                }
            }
            $HuduFastCommitHeaders = @{}
            $MatchedArticles = $ArticleContentCommitCandidates
            $null = [IO.Directory]::CreateDirectory($MigrationLogs)
            foreach ($UseFastArticleContentCommit in @($false, $true)) {
                # API result normalization uses optional wrapper properties in
                # the migration's default (non-strict) execution mode.
                try {
                    Set-StrictMode -Off
                    . "$repoRoot/Public/Jobs/Invoke-ArticleContentCommit.ps1" 6>$null
                } finally {
                    Set-StrictMode -Version Latest
                }
                Assert-ArticleLinks ($articlesUpdated.Count -eq 8 -and @($articlesUpdated | Where-Object status -eq 'failed').Count -eq 3) 'The commit helper lost preparation/transport failures or successful results.'
                Assert-ArticleLinks (($articleCommitResults.article_id -join ',') -ceq '1000,1003,1004,1005,1006,1007') 'The commit helper changed result order.'
                foreach ($name in @('ReplacedArticlesURL.json', 'Articles.json', 'ReplacedAttachmentLinks.json', 'ReplacedImageAnchors.json')) {
                    Assert-ArticleLinks (Test-Path -LiteralPath (Join-Path $MigrationLogs $name)) "The extracted commit helper lost $name."
                }
                $savedResults = @(Get-Content -LiteralPath (Join-Path $MigrationLogs 'ReplacedArticlesURL.json') -Raw | ConvertFrom-Json)
                Assert-ArticleLinks ($savedResults.Count -eq 8 -and @($savedResults | Where-Object status -eq 'failed').Count -eq 3) 'The extracted commit helper wrote incomplete results.'
            }
        }
    }

    # The asset helper can reuse attachment maps or load them independently,
    # without staging/committing articles as a side effect.
    & {
        $AllFields = @(@{ HuduLayoutID = 901; HuduLayoutField = @{ field_type = 'RichText'; label = 'Notes' } })
        $MatchedAssets = @(@{ HuduObject = @{
            id = 501; name = 'asset'; company_id = 1; asset_layout_id = 901
            fields = @(
                @{ label = 'Notes'; field_type = 'RichText'; value = $contents[14] },
                @{ label = 'plain'; field_type = 'Text'; value = $contents[14] }
            )
        } })
        $MigrationLogs = Join-Path $fixtureRoot 'logs'
        $assetCommits = [Collections.Generic.List[object]]::new()
        $mapCalls = [int[]]@(0)
        function Get-AttachmentUrlMap { $mapCalls[0]++; return $attachmentMap }
        function Set-HuduAsset {
            param($Id, $CompanyId, $Fields)
            $assetCommits.Add(@{ Id = $Id; CompanyId = $CompanyId; Fields = $Fields })
            @{ asset = @{ id = $Id } }
        }
        foreach ($reuseMaps in @($true, $false)) {
            $assetCommits.Clear(); $mapCalls[0] = 0
            try {
                Set-StrictMode -Off
                if ($reuseMaps) {
                    . "$repoRoot/Public/Jobs/Invoke-AssetRichTextLinkReplacement.ps1" -AttachmentUrlMapForReplacement $attachmentMap -AttachmentUrlLookupForReplacement $attachmentLookup 6>$null
                } else {
                    . "$repoRoot/Public/Jobs/Invoke-AssetRichTextLinkReplacement.ps1" 6>$null
                }
            } finally {
                Set-StrictMode -Version Latest
            }
            Assert-ArticleLinks ($mapCalls[0] -eq [int](-not $reuseMaps)) 'Asset replacement ignored the supplied map or failed to load its own map.'
            Assert-ArticleLinks ($assetCommits.Count -eq 1 -and $assetCommits[0].Id -eq 501 -and $assetCommits[0].CompanyId -eq 1) 'The extracted asset helper lost or duplicated a commit.'
            Assert-ArticleLinks ($assetCommits[0].Fields.Count -eq 1 -and $assetCommits[0].Fields[0].Notes -ceq $expected[14].Content) 'Asset rich text replacement changed HTML or included a plain-text field.'
            Assert-ArticleLinks ($MatchedAssets[0].HuduObject.fields[1].value -ceq $contents[14]) 'The asset helper changed an unrelated field.'
            $savedAssetResults = @(Get-Content -LiteralPath (Join-Path $MigrationLogs 'ReplacedAssetRichTextLinks.json') -Raw | ConvertFrom-Json)
            Assert-ArticleLinks ($savedAssetResults.Count -eq 1 -and $savedAssetResults[0].status -eq 'replaced') 'The extracted asset helper lost its report.'
        }
    }

    if ($Benchmark) {
        # Deliberately large candidate map with few actual links per article.
        $largeMap = @{}
        for ($i = 0; $i -lt 2000; $i++) { $largeMap["C:\images\image-$i.png"] = "$HuduBaseDomain/public_photo/$i" }
        $watch = [Diagnostics.Stopwatch]::StartNew()
        foreach ($article in $articles[0..19]) {
            $null = Update-HuduContentLinks -Content (Get-HuduArticleLocalContent $article) -ImageMap $largeMap `
                -IncludeHardcodedImages -IncludeAttachments -IncludeHostedImageAnchors -IncludeUploads 6>$null
        }
        $watch.Stop(); $serialSeconds = $watch.Elapsed.TotalSeconds
        $watch.Restart()
        $null = Invoke-HuduArticleLinkReplacement -Articles $articles[0..19] -ImageMap $largeMap -ThrottleLimit 4 6>$null
        $watch.Stop()
        Write-Output ('Synthetic benchmark: serial repeated lookup {0:N2}s; shared lookup + 4 workers {1:N2}s; {2:N1}x faster (20 articles, 2,000 image candidates).' -f $serialSeconds, $watch.Elapsed.TotalSeconds, ($serialSeconds / $watch.Elapsed.TotalSeconds))
    }
    Write-Output "Passed $checks article link replacement checks (offline; serial and parallel HTML/reports match)."
} finally {
    if ($lock) { $lock.Dispose() }
    $resolvedFixtureRoot = [IO.Path]::GetFullPath($fixtureRoot)
    $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $resolvedFixtureRoot.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolvedFixtureRoot) -notmatch '^itglue-article-links-[a-f0-9]{32}$') {
        throw "Refusing fixture cleanup outside the expected temp directory: $resolvedFixtureRoot"
    }
    if ([IO.Directory]::Exists($resolvedFixtureRoot)) { [IO.Directory]::Delete($resolvedFixtureRoot, $true) }
}
