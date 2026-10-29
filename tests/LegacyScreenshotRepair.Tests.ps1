#requires -Version 7.2
# Offline bearer-JWT, repair, retry, and standalone-entry-point checks.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
. "$repoRoot/Public/Repair-ITGlueLegacyStepScreenshots.ps1"
$checks = 0
function Assert-Legacy { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message }; $script:checks++ }
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) "itglue-legacy-repair-$([guid]::NewGuid().ToString('N'))"
$logsPath = Join-Path $fixtureRoot 'logs'
$null = [IO.Directory]::CreateDirectory($logsPath)
$gate = New-ITGluePasswordRequestGate -MinimumIntervalMilliseconds 0
$png = [Convert]::FromBase64String('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==')
$signedUrl = 'https://storage.invalid/document/steps/screenshots/000/071/601/slim/Generic_USB_Hub_Properties.jpg?X-Amz-Signature=keep%2Bthis%2Fexactly%3D'
$jwtMode = 'success'; $editorMode = 'empty'; $failCommit = $false
$requests = [Collections.Generic.List[object]]::new()
$downloads = [Collections.Generic.List[object]]::new()
$webRequests = [Collections.Generic.List[object]]::new()
$documentOverrides = @{}; $jwtOverrides = @{}
$photoCalls = 0; $commitCalls = 0
$photoMode = 'default'; $sanitizationMode = ''; $pendingSanitization = ''
$articleReads = 0; $simulateConcurrentEdit = $false
$originalContent = '<p>Keep this current user edit.</p><img src="/images/logo.png"><img class="screenshot" data-src-original="original/Generic_USB_Hub_Properties.jpg" src="thumbnail/Generic_USB_Hub_Properties.jpg" alt="USB settings">'
$liveContent = $originalContent
function New-TestHttpFailure {
    param([int]$Status)
    $response = [Net.Http.HttpResponseMessage]::new([Net.HttpStatusCode]$Status)
    return [Microsoft.PowerShell.Commands.HttpResponseException]::new("Mock HTTP $Status", $response)
}
function Invoke-RestMethod {
    [CmdletBinding()]
    param($Method, [string]$Uri, $Headers, $MaximumRedirection, $TimeoutSec)
    $jwt = $Headers.ContainsKey('Authorization')
    $requests.Add([pscustomobject]@{Uri=$Uri; JWT=$jwt; CorrectBearer=($jwt -and $Headers.Authorization -ceq 'Bearer test-jwt'); HasApiKey=$Headers.ContainsKey('x-api-key'); Accept=$Headers['Accept']; MaximumRedirection=$MaximumRedirection})
    if ($jwt) {
        if ($jwtMode -eq 'unauthorized') { throw (New-TestHttpFailure 401) }
        if ($Uri -match '/versions/published$') {
            if ($editorMode -eq 'unauthorized') { throw (New-TestHttpFailure 401) }
            $editorImages = if ($editorMode -ne 'empty') { @(@{name='Generic_USB_Hub_Properties.jpg'; src=$signedUrl; thumbnailSrc=$signedUrl.Replace('/slim/', '/thumbnail/'); originalSrc=$signedUrl.Replace('/slim/', '/original/')}) } else { @() }
            return @{id=if ($editorMode -eq 'wrong-document') { '999' } else { '58145' }; version=if ($editorMode -eq 'draft') { 'draft' } else { 'published' }; sections=@(@{id=256231; resourceType='Document::Step'; images=$editorImages})}
        }
        if ($jwtMode -eq 'missing') { return @{data=@{id='58145'; attributes=@{content=@()}}} }
        if ($jwtOverrides.ContainsKey($Uri)) { return $jwtOverrides[$Uri] }
        return @{data=@{id='58145'; attributes=@{content=@(@{resource=@{screenshot_url=$signedUrl}})}}}
    }
    if ($documentOverrides.ContainsKey($Uri)) { return $documentOverrides[$Uri] }
    if (([Uri]$Uri).AbsolutePath -ne '/documents/58145') { throw 'Unexpected API request; a step ID may have been treated as a document-image ID.' }
    return @{data=@{id='58145'; attributes=@{
        'resource-url'='https://tenant.invalid/91889/docs/58145'
        sections=@(@{id='256231'; attributes=@{sort=0; 'resource-type'='Document::Step'; 'document-images'=@()}})
        content=@(@{id=256231; document_id=58145; resource=@{id=71601; screenshot_file_name='Generic_USB_Hub_Properties.jpg'; screenshot_file_size=26880}})
    }}}
}
function Invoke-WebRequest {
    [CmdletBinding()]
    param($Method, [string]$Uri, [string]$OutFile, $Headers, $WebSession, $TimeoutSec)
    if ($WebSession) {
        $webRequests.Add([pscustomobject]@{Uri=$Uri; Headers=$Headers})
        return @{Content=('<img src="' + [Net.WebUtility]::HtmlEncode($signedUrl) + '">')}
    }
    $downloads.Add([pscustomobject]@{Uri=$Uri; Headers=$Headers; Session=$WebSession})
    [IO.File]::WriteAllBytes($OutFile, $png)
}
function Get-HuduArticles {
    [CmdletBinding()]
    param($Id)
    $script:articleReads++
    if ($pendingSanitization) {
        $script:liveContent = [regex]::Replace($script:liveContent, '(?is)<img\b[^>]*>', {
            param($match)
            $absolute = $match.Value -match '(?i)(?<![\w-])src\s*=\s*["'']https://hudu.invalid/public_photo/'
            $publicPhoto = $match.Value -match '/public_photo/'
            if ($absolute -or ($pendingSanitization -eq 'all-public-photos' -and $publicPhoto)) { '' } else { $match.Value }
        })
        $script:pendingSanitization = ''
    }
    if ($simulateConcurrentEdit -and $articleReads -eq 2) { $script:liveContent += '<p>Concurrent edit.</p>' }
    return @{article=[pscustomobject]@{id=$Id; content=$script:liveContent; name='Current article title'}}
}
function New-HuduPublicPhoto {
    [CmdletBinding()]
    param($FilePath, $record_id, $record_type)
    if (-not (Test-Path -LiteralPath $FilePath)) { throw 'Missing cached screenshot.' }
    $script:photoCalls++
    $leaf = [IO.Path]::GetFileName($FilePath)
    $url = if ($leaf -eq 'step-71601.png') { 'https://hudu.invalid/images/repaired.png' } else { "https://hudu.invalid/images/$leaf" }
    if ($photoMode -eq 'public-photo') { $url = 'https://hudu.invalid/public_photo/repaired' }
    return @{public_photo=@{url=$url}}
}
function Set-HuduArticle {
    [CmdletBinding()]
    param($Id, $Content)
    $script:commitCalls++
    if ($failCommit) { throw 'Simulated article commit failure' }
    $script:liveContent = $Content
    $script:pendingSanitization = $sanitizationMode
    return @{article=[pscustomobject]@{id=$Id; content=$Content; name='Current article title'}}
}
function New-LegacyTestArticle {
    $source = '<img src="original/Dragon_Logo.jpg"><img src="original/Generic_USB_Hub_Properties.jpg">'
    return [pscustomobject]@{ITGID='58145'; HuduID=383; Name='Original title'; HuduObject=@{}; SourceImages=@(Get-ITGlueArticleSourceImages $source)}
}
function New-LegacyTestContext {
    param([string]$Token = 'test-jwt', [Microsoft.PowerShell.Commands.WebRequestSession]$Session)
    $context = New-ITGlueLegacyScreenshotRecoveryContext -ApiBase 'https://api.example.invalid' -ApiKey 'offline-test-key' -MigrationLogsPath $logsPath -TenantBase 'https://tenant.invalid' -HuduBase 'https://hudu.invalid' -JWTAuthToken $Token -WebSession $Session
    $context.RequestGate = $gate
    $context.PlacementVerificationDelayMilliseconds = 0
    $context.DocumentUrls['58145'] = 'https://tenant.invalid/91889/docs/58145'
    return $context
}

try {
    $serialized = @{resource=@{screenshot_url=$signedUrl}} | ConvertTo-Json -Compress
    $parsedUrls = @(Get-ITGlueLegacySignedUrls $serialized)
    Assert-Legacy ($parsedUrls.Count -eq 1 -and $parsedUrls[0] -ceq $signedUrl) 'Serialized JWT document content altered signed URL encoding.'
    $article = New-LegacyTestArticle
    $context = New-LegacyTestContext
    $result = @(Invoke-ITGlueLegacyScreenshotRepair -Articles @($article) -Context $context -DownloadOnly)
    Assert-Legacy ($result.Count -eq 1 -and $result[0].Status -eq 'Downloaded' -and $photoCalls -eq 0 -and $commitCalls -eq 0) 'DownloadOnly uploaded or changed a Hudu article.'
    $jwtRequests = @($requests | Where-Object JWT)
    Assert-Legacy ($jwtRequests.Count -eq 1 -and $jwtRequests[0].CorrectBearer -and -not $jwtRequests[0].HasApiKey) 'JWT lookup did not use the checklist bearer-token convention independently of the API key.'
    Assert-Legacy ($downloads.Count -eq 1 -and $downloads[0].Uri -ceq $signedUrl -and $null -eq $downloads[0].Headers -and $null -eq $downloads[0].Session) 'A signed download URL was changed or received authentication credentials.'
    Assert-Legacy ($article.ImageRecoveries[0].DownloadedViaApi -and $article.ImageRecoveries[0].DownloadUrlSource -eq 'JWTApi') 'JWT download provenance was not recorded.'

    $result = @(Invoke-ITGlueLegacyScreenshotRepair -Articles @($article) -Context $context)
    Assert-Legacy ($result.Count -eq 1 -and $result[0].Status -eq 'Placed' -and $photoCalls -eq 1 -and $commitCalls -eq 1) 'The standalone repair did not upload and place its screenshot.'
    Assert-Legacy ($liveContent.Contains('Keep this current user edit.') -and $liveContent.Contains('/images/logo.png') -and $liveContent.Contains('class="screenshot"') -and $liveContent.Contains('alt="USB settings"')) 'Repair overwrote unrelated current article content or image attributes.'
    Assert-Legacy ($liveContent -notmatch 'original/Generic_USB_Hub_Properties|thumbnail/Generic_USB_Hub_Properties' -and $article.ImageRecoveries[-1].Status -eq 'Placed' -and $article.LocalContentCommittedAt) 'Image source/original URLs or commit provenance were not updated.'
    $null = @(Invoke-ITGlueLegacyScreenshotRepair -Articles @($article) -Context $context -DownloadOnly)
    Assert-Legacy ($article.ImageRecoveries[-1].HuduImageUrl -eq 'https://hudu.invalid/images/repaired.png' -and $article.ImageRecoveries[-1].Status -eq 'Placed') 'A later download-only run erased prior placement metadata.'
    $result = @(Invoke-ITGlueLegacyScreenshotRepair -Articles @($article) -Context $context)
    Assert-Legacy ($result[0].Status -eq 'AlreadyPlaced' -and $photoCalls -eq 1 -and $commitCalls -eq 1) 'Rerunning the repair uploaded or committed an already placed image.'

    # Hudu accepts absolute photo URLs in a PUT response, then can strip those
    # embeds in post-processing. Match its regular-import relative URL format.
    $photoMode='public-photo'; $sanitizationMode='absolute-public-photos'
    $liveContent=$originalContent
    $publicPhotoSource=Join-Path $fixtureRoot 'public-photo-source.html'
    [IO.File]::WriteAllText($publicPhotoSource, $originalContent)
    $publicPhotoArticle=New-LegacyTestArticle
    $publicPhotoArticle | Add-Member -NotePropertyName LocalContentPath -NotePropertyValue $publicPhotoSource
    $publicPhotoArticle.SourceImages=@(Get-ITGlueArticleSourceImages $originalContent)
    $result=@(Invoke-ITGlueLegacyScreenshotRepair -Articles @($publicPhotoArticle) -Context (New-LegacyTestContext))
    Assert-Legacy ($result[-1].Status -eq 'Placed' -and $liveContent.Contains('src="/public_photo/repaired"') -and $liveContent -notmatch 'src="https://hudu.invalid/public_photo/') 'Hudu-hosted screenshots were embedded using absolute URLs that its post-processing can remove.'
    Assert-Legacy ($publicPhotoArticle.ImageRecoveries[-1].PlacementVerified -and $publicPhotoArticle.ImageRecoveries[-1].PlacementVerifiedAt) 'Placement was reported without checking the persisted article.'
    $beforePhotos=$photoCalls; $beforeCommits=$commitCalls
    $result=@(Invoke-ITGlueLegacyScreenshotRepair -Articles @($publicPhotoArticle) -Context (New-LegacyTestContext))
    Assert-Legacy ($result[0].Status -eq 'AlreadyPlaced' -and $photoCalls -eq $beforePhotos -and $commitCalls -eq $beforeCommits) 'Relative photo embeds were not recognized using their absolute recovery-log URLs.'
    $sanitizationMode='all-public-photos'; $liveContent=$originalContent
    $result=@(Invoke-ITGlueLegacyScreenshotRepair -Articles @($publicPhotoArticle) -Context (New-LegacyTestContext))
    Assert-Legacy ($result[-1].Status -eq 'Failed' -and $result[-1].Problem -like '*did not retain*' -and $publicPhotoArticle.ImageRecoveries[-1].Status -eq 'Uploaded' -and -not $publicPhotoArticle.ImageRecoveries[-1].PlacementVerified -and $photoCalls -eq $beforePhotos) 'A photo stripped after a successful PUT was falsely logged as placed or its upload was lost.'
    Assert-Legacy ((Get-Content -LiteralPath $publicPhotoArticle.LocalContentPath -Raw) -notmatch '/public_photo/') 'The local cache retained optimistic embeds missing from the persisted article.'
    $sanitizationMode=''
    $result=@(Invoke-ITGlueLegacyScreenshotRepair -Articles @($publicPhotoArticle) -Context (New-LegacyTestContext))
    Assert-Legacy ($result[-1].Status -eq 'Placed' -and $publicPhotoArticle.ImageRecoveries[-1].PlacementVerified -and $photoCalls -eq $beforePhotos) 'A stripped embed could not be retried with its existing photo and original source layout.'
    $linkedImage='<p>Keep</p><a href="large/1.png"> <img src="thumbnail/1.png"> </a>'
    $linkedImage=Set-ITGlueLegacyScreenshotTagUrl $linkedImage 0 '/public_photo/repaired'
    Assert-Legacy ($linkedImage.Contains('href="/public_photo/repaired"') -and $linkedImage.Contains('src="/public_photo/repaired"')) 'The screenshot retained a broken export-only full-size link.'
    $meaningfulLink='<a href="https://docs.invalid/instructions"><img src="thumbnail/1.png"></a>'
    Assert-Legacy ((Set-ITGlueLegacyScreenshotTagUrl $meaningfulLink 0 '/public_photo/repaired').Contains('href="https://docs.invalid/instructions"')) 'Repair replaced an unrelated meaningful link around an image.'
    Assert-Legacy ((ConvertTo-ITGlueLegacyHuduImageSrc 'https://other.invalid/public_photo/repaired' 'https://hudu.invalid') -eq 'https://other.invalid/public_photo/repaired') 'A different host was incorrectly converted into a local Hudu photo path.'
    $photoMode='default'

    $article = New-LegacyTestArticle
    $liveContent = '<p>Keep this current user edit.</p><img src="/images/logo.png"><img src="">'
    $result = @(Invoke-ITGlueLegacyScreenshotRepair -Articles @($article) -Context (New-LegacyTestContext))
    Assert-Legacy ($result[-1].Status -eq 'Placed' -and $liveContent.Contains('/images/logo.png') -and $liveContent.Contains('https://hudu.invalid/images/repaired.png')) 'A blank image source could not be repaired from the preserved source-image position.'
    $liveContent = $originalContent + '<p>https://hudu.invalid/images/repaired.png</p>'
    $beforeCommits = $commitCalls
    $result = @(Invoke-ITGlueLegacyScreenshotRepair -Articles @($article) -Context (New-LegacyTestContext))
    Assert-Legacy ($result[-1].Status -eq 'Placed' -and $commitCalls -eq ($beforeCommits + 1)) 'A photo URL mentioned only in text was mistaken for a placed image.'

    $article = New-LegacyTestArticle; $liveContent = $originalContent; $failCommit = $true
    $beforePhotos = $photoCalls
    $null = @(Invoke-ITGlueLegacyScreenshotRepair -Articles @($article) -Context (New-LegacyTestContext))
    Assert-Legacy ($article.ImageRecoveries[-1].Status -eq 'Uploaded' -and $article.ImageRecoveries[-1].HuduImageUrl -and $photoCalls -eq ($beforePhotos + 1)) 'A failed article commit lost the uploaded photo needed for a retry.'
    $failCommit = $false
    $result = @(Invoke-ITGlueLegacyScreenshotRepair -Articles @($article) -Context (New-LegacyTestContext))
    Assert-Legacy ($result[-1].Status -eq 'Placed' -and $photoCalls -eq ($beforePhotos + 1)) 'Retrying a failed article commit uploaded a duplicate photo.'
    $article = New-LegacyTestArticle; $liveContent = $originalContent; $articleReads = 0; $simulateConcurrentEdit = $true
    $beforeCommits = $commitCalls
    $result = @(Invoke-ITGlueLegacyScreenshotRepair -Articles @($article) -Context (New-LegacyTestContext))
    Assert-Legacy ($result[-1].Status -eq 'Failed' -and $commitCalls -eq $beforeCommits -and $liveContent.Contains('Concurrent edit.')) 'Concurrent article edits were overwritten by the repair.'
    $simulateConcurrentEdit = $false; $beforePhotos = $photoCalls
    $result = @(Invoke-ITGlueLegacyScreenshotRepair -Articles @($article) -Context (New-LegacyTestContext))
    Assert-Legacy ($result[-1].Status -eq 'Placed' -and $photoCalls -eq $beforePhotos -and $liveContent.Contains('Concurrent edit.')) 'Retrying a concurrent edit lost newer content or uploaded another photo.'

    $article = New-LegacyTestArticle; $liveContent = $originalContent
    $beforePhotos = $photoCalls; $beforeCommits = $commitCalls
    $null = @(Invoke-ITGlueLegacyScreenshotRepair -Articles @($article) -Context (New-LegacyTestContext) -WhatIf)
    Assert-Legacy ($photoCalls -eq $beforePhotos -and $commitCalls -eq $beforeCommits) 'WhatIf performed external writes.'
    $liveContent = '<img src="Generic_USB_Hub_Properties.jpg"><img src="Generic_USB_Hub_Properties.jpg">'
    $result = @(Invoke-ITGlueLegacyScreenshotRepair -Articles @((New-LegacyTestArticle)) -Context (New-LegacyTestContext))
    Assert-Legacy ($result[0].Status -eq 'Failed' -and $photoCalls -eq $beforePhotos) 'Ambiguous current article images were replaced or uploaded.'

    $context = New-LegacyTestContext; $jwtMode = 'unauthorized'
    $message = ''
    try { $null = Get-ITGlueLegacyScreenshotUrls $context '58145' '71601' } catch { $message = $_.Exception.Message }
    Assert-Legacy ($context.JWTUnavailable -and $message -like '*token may be expired*' -and $message -notmatch 'test-jwt') 'Rejected JWTs were accepted or exposed in errors.'
    $before = @($requests | Where-Object JWT).Count
    try { $null = Get-ITGlueLegacyScreenshotUrls $context '58145' '71601' } catch {}
    Assert-Legacy (@($requests | Where-Object JWT).Count -eq $before) 'An expired JWT was repeatedly queried.'
    $jwtMode = 'missing'; $message = ''
    try { $null = Get-ITGlueLegacyScreenshotUrls (New-LegacyTestContext) '58145' '71601' } catch { $message = $_.Exception.Message }
    Assert-Legacy ($message -like '*JWT document response did not expose*') 'JWT authentication was incorrectly treated as proof that a signed image URL exists.'
    $context = New-LegacyTestContext; $context.JWTBaseUri='https://unrelated.invalid'
    $before = $requests.Count; $rejected=$false
    try { $null = Get-ITGlueLegacyScreenshotUrls $context '58145' '71601' } catch { $rejected=$true }
    Assert-Legacy ($rejected -and $requests.Count -eq $before) 'A bearer token was sent to an unrelated host.'
    $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
    $context = New-LegacyTestContext -Session $session
    $context.DocumentUrls['58145'] = 'https://tenant.invalid/91889/docs/58145'
    $urls = @(Get-ITGlueLegacyScreenshotUrls $context '58145' '71601')
    Assert-Legacy ($urls.Count -eq 1 -and $urls[0].Source -eq 'AuthenticatedWebDocument' -and $webRequests.Count -eq 1) 'An available web-session fallback was not used when JWT metadata omitted signed URLs.'

    # The real public API omits legacy screenshot URLs even with a valid JWT.
    # The tenant's published editor JSON exposes images[].originalSrc instead.
    $editorMode='success'
    $context=New-LegacyTestContext
    $before=$requests.Count
    $urls=@(Get-ITGlueLegacyScreenshotUrls $context '58145' '71601')
    $editorRequests=@($requests | Select-Object -Skip $before | Where-Object Uri -like '*/versions/published')
    Assert-Legacy ($urls.Count -eq 3 -and $urls[0].Variant -eq 'original' -and $urls[0].Source -eq 'JWTDocumentEditor' -and $urls[0].Url -ceq $signedUrl.Replace('/slim/', '/original/')) 'Published editor screenshot variants or signed encoding were not preserved.'
    Assert-Legacy ($editorRequests.Count -eq 1 -and $editorRequests[0].Uri -eq 'https://tenant.invalid/91889/docs/58145/versions/published' -and $editorRequests[0].CorrectBearer -and -not $editorRequests[0].HasApiKey -and $editorRequests[0].Accept -eq 'application/json' -and $editorRequests[0].MaximumRedirection -eq 0) 'Published editor lookup used the wrong endpoint, credentials, headers, or redirect policy.'
    $before=$requests.Count
    $null=@(Get-ITGlueLegacyScreenshotUrls $context '58145' '71601')
    Assert-Legacy ($requests.Count -eq $before) 'Published screenshot URLs were not cached across screenshots in the same document.'
    $context.CachePath=Join-Path $fixtureRoot 'editor-downloads'
    $editorArticle=New-LegacyTestArticle
    $beforePhotos=$photoCalls; $beforeCommits=$commitCalls
    $result=@(Invoke-ITGlueLegacyScreenshotRepair -Articles @($editorArticle) -Context $context -DownloadOnly)
    Assert-Legacy ($result[0].Status -eq 'Downloaded' -and $editorArticle.ImageRecoveries[0].DownloadedViaApi -and $editorArticle.ImageRecoveries[0].DownloadUrlSource -eq 'JWTDocumentEditor' -and $photoCalls -eq $beforePhotos -and $commitCalls -eq $beforeCommits) 'Published editor download failed to persist its API provenance or performed a Hudu write.'
    $beforeDownloads=$downloads.Count
    $null=@(Invoke-ITGlueLegacyScreenshotRepair -Articles @($editorArticle) -Context $context -DownloadOnly)
    Assert-Legacy ($downloads.Count -eq $beforeDownloads -and $editorArticle.ImageRecoveries[0].UsedCachedDownload -and $editorArticle.ImageRecoveries[0].DownloadedViaApi -and $editorArticle.ImageRecoveries[0].DownloadUrlSource -eq 'JWTDocumentEditor') 'Reusing a cached screenshot erased its original JWT API download provenance.'
    foreach ($mode in @('wrong-document', 'draft')) {
        $editorMode=$mode; $message=''
        try { $null=Get-ITGlueLegacyScreenshotUrls (New-LegacyTestContext) '58145' '71601' } catch { $message=$_.Exception.Message }
        Assert-Legacy ($message -like '*Cannot verify*published-document response*') "A $mode response supplied signed URLs for the published document."
    }
    $editorMode='success'
    foreach ($badUrl in @('https://unrelated.invalid/91889/docs/58145', 'http://tenant.invalid/91889/docs/58145', 'https://tenant.invalid/91889/docs/999')) {
        $context=New-LegacyTestContext; $context.DocumentUrls['58145']=$badUrl
        $before=@($requests | Where-Object Uri -like '*/versions/published').Count; $message=''
        try { $null=Get-ITGlueLegacyScreenshotUrls $context '58145' '71601' } catch { $message=$_.Exception.Message }
        Assert-Legacy ($message -and @($requests | Where-Object Uri -like '*/versions/published').Count -eq $before) 'The editor JWT was sent to an unverified tenant/document endpoint.'
    }
    $context=New-LegacyTestContext; $context.DocumentUrls['58145']='https://tenant.invalid/DOC-91889-58145'
    Assert-Legacy (@(Get-ITGlueLegacyScreenshotUrls $context '58145' '71601').Count -eq 3) 'A canonical DOC organization/document URL could not resolve published screenshot URLs.'
    $editorMode='unauthorized'; $context=New-LegacyTestContext
    try { $null=Get-ITGlueLegacyScreenshotUrls $context '58145' '71601' } catch {}
    $before=$requests.Count
    try { $null=Get-ITGlueLegacyScreenshotUrls $context '58145' '71601' } catch {}
    Assert-Legacy ($context.JWTUnavailable -and $requests.Count -eq $before) 'A rejected tenant JWT was repeatedly queried.'
    $editorMode='empty'
    $jwtMode = 'success'

    # Document 52165 has eleven legacy screenshots, eight named 1.png. Hudu
    # removed all broken image tags while retaining their surrounding blocks.
    $stepIds = @('64152','64153','64154','64155','64156','64159','64161','64162','64164','64165','64166')
    $stepNames = @('1.png','1.png','1.png','1.png','1.png','TouchUP.png','1.png','1.png','1.png','CheckName2.png','Creds2.png')
    $sourceParts = @(); $sections = @(); $resources = @(); $jwtParts = @()
    for ($index=0; $index -lt $stepIds.Count; $index++) {
        $stepId=$stepIds[$index]; $name=$stepNames[$index]; $text="Instruction number $index."
        $sourceParts += "<div class='source-step'><p>$text</p><img src='thumbnail/$name' data-src-original='original/$name'></div>"
        $sections += @{id="section-$index"; attributes=@{sort=$index; content="<p>$text</p>"; 'resource-type'='Document::Step'; 'document-images'=@()}}
        $resources += @{id="section-$index"; document_id=52165; resource=@{id=$stepId; screenshot_file_name=$name}}
        $shards = $stepId.PadLeft(9,'0') -replace '^(...)(...)(...)$', '$1/$2/$3'
        $jwtParts += @{resource=@{screenshot_url="https://storage.invalid/document/steps/screenshots/$shards/original/$name`?X-Amz-Signature=step-$stepId"}}
    }
    # Real section IDs are numeric; retain that contract in the regression.
    for ($index=0; $index -lt $stepIds.Count; $index++) { $sections[$index].id="$(202627+$index)"; $resources[$index].id="$(202627+$index)" }
    $documentOverrides['https://api.example.invalid/documents/52165'] = @{data=@{id='52165'; attributes=@{sections=$sections; content=$resources}}}
    $jwtOverrides['https://api.example.invalid/documents/52165'] = @{data=@{id='52165'; attributes=@{content=$jwtParts}}}
    $fullSource = '<html><head><title>Snapshot</title></head><body>' + ($sourceParts -join '') + '</body></html>'
    $imagePattern = '(?is)<img\b(?:[^>"'']|"[^"]*"|''[^'']*'')*>'
    $strippedSource = [regex]::Replace($fullSource, $imagePattern, '')
    $sourceCache = Join-Path $fixtureRoot 'ArticleContent/251.html'
    [IO.File]::WriteAllText($sourceCache, $fullSource)
    $multiArticle = [pscustomobject]@{ITGID='52165'; HuduID=251; Name='Outlook setup'; HuduObject=@{}; LocalContentPath=$sourceCache; SourceImages=@(Get-ITGlueArticleSourceImages $fullSource)}
    $liveContent = $strippedSource.Replace("class='source-step'", "data-formatting='keep'")
    $beforePhotos=$photoCalls; $beforeCommits=$commitCalls; $beforeDownloads=$downloads.Count
    $result = @(Invoke-ITGlueLegacyScreenshotRepair -Articles @($multiArticle) -Context (New-LegacyTestContext))
    $placedImages = @(Get-ITGlueArticleSourceImages $liveContent)
    Assert-Legacy ($result.Count -eq 11 -and @($result | Where-Object Status -eq 'Placed').Count -eq 11 -and $placedImages.Count -eq 11 -and $photoCalls -eq ($beforePhotos+11) -and $commitCalls -eq ($beforeCommits+1)) 'The eleven removed screenshot tags were not restored in one article commit.'
    for ($index=0; $index -lt $stepIds.Count; $index++) {
        Assert-Legacy ($placedImages[$index].Html.Contains("/step-$($stepIds[$index]).png")) "Repeated filename was resolved to the wrong step at source index $index."
    }
    Assert-Legacy ($liveContent.Contains("data-formatting='keep'") -and @($downloads | Select-Object -Skip $beforeDownloads | ForEach-Object { (Get-ITGlueDocumentImageReferences @($_.Uri)).StepIds[0] } | Select-Object -Unique).Count -eq 11) 'Restoration changed current formatting or downloaded the same 1.png screenshot for multiple steps.'
    Assert-Legacy ((Test-Path -LiteralPath (Join-Path $logsPath 'LegacyScreenshotSources/52165.html')) -and @($multiArticle.ImageRecoveries | Where-Object { $_.PlacementMethod -ne 'RestoredSourceStructure' -or $_.MatchMethod -ne 'LegacyStepId' }).Count -eq 0) 'The original placement layout or exact step-ID provenance was not preserved.'
    $beforePhotos=$photoCalls; $beforeCommits=$commitCalls
    $result = @(Invoke-ITGlueLegacyScreenshotRepair -Articles @($multiArticle) -Context (New-LegacyTestContext))
    Assert-Legacy (@($result | Where-Object Status -eq 'AlreadyPlaced').Count -eq 11 -and $photoCalls -eq $beforePhotos -and $commitCalls -eq $beforeCommits) 'Rerunning a restored article uploaded or committed its screenshots again.'

    $partialIndex=0
    $liveContent = [regex]::Replace($fullSource, $imagePattern, { param($match) $keep=$script:partialIndex -in @(0,5,10); $script:partialIndex++; if($keep){$match.Value}else{''} })
    $liveContent = $liveContent.Replace('<body>', '<body><img src="/images/user-banner.png">')
    $partialArticle = [pscustomobject]@{ITGID='52165'; HuduID=251; Name='Outlook setup'; HuduObject=@{}; SourceImages=@(Get-ITGlueArticleSourceImages $fullSource)}
    $result = @(Invoke-ITGlueLegacyScreenshotRepair -Articles @($partialArticle) -Context (New-LegacyTestContext))
    $partialImages = @(Get-ITGlueArticleSourceImages $liveContent)
    Assert-Legacy (@($result | Where-Object Status -eq 'Placed').Count -eq 11 -and $partialImages.Count -eq 12 -and $partialImages[0].Html.Contains('/images/user-banner.png') -and $partialImages[2].Html.Contains('/step-64153.png')) 'Partial tag removal or an added image shifted screenshots into the wrong source slots.'
    $liveContent = $strippedSource.Replace('Instruction number 5.', 'User changed this instruction.')
    $beforePhotos=$photoCalls; $beforeCommits=$commitCalls
    $result = @(Invoke-ITGlueLegacyScreenshotRepair -Articles @($partialArticle) -Context (New-LegacyTestContext))
    Assert-Legacy (@($result | Where-Object Status -eq 'Failed').Count -eq 11 -and $photoCalls -eq $beforePhotos -and $commitCalls -eq $beforeCommits) 'Removed tags were restored into a source layout whose surrounding text had changed.'
    $documentOverrides['https://api.example.invalid/documents/52165'].data.attributes.sections[0].attributes.content='<p>Changed API section order.</p>'
    $liveContent=$strippedSource
    $beforePhotos=$photoCalls
    $conflictArticle=[pscustomobject]@{ITGID='52165'; HuduID=251; Name='Outlook setup'; HuduObject=@{}; SourceImages=@(Get-ITGlueArticleSourceImages $fullSource)}
    $result=@(Invoke-ITGlueLegacyScreenshotRepair -Articles @($conflictArticle) -Context (New-LegacyTestContext))
    Assert-Legacy (@($result | Where-Object Status -eq 'Failed').Count -eq 8 -and @($result | Where-Object Status -eq 'Placed').Count -eq 3 -and $photoCalls -eq ($beforePhotos+3)) 'Conflicting API step text was ignored when assigning repeated filenames by order.'
    $documentOverrides['https://api.example.invalid/documents/52165'].data.attributes.sections[0].attributes.content='<p>Instruction number 0.</p>'
    $downloadContext=New-LegacyTestContext; $downloadContext.CachePath=Join-Path $fixtureRoot 'download-only-duplicates'
    $downloadContext.LogsPath=Join-Path $fixtureRoot 'no-source/logs'
    $downloadArticle=[pscustomobject]@{ITGID='52165'; HuduID=251; Name='Outlook setup'; HuduObject=@{}; SourceImages=@()}
    $result = @(Invoke-ITGlueLegacyScreenshotRepair -Articles @($downloadArticle) -Context $downloadContext -DownloadOnly)
    Assert-Legacy (@($result | Where-Object Status -eq 'Downloaded').Count -eq 11 -and @(Get-ChildItem -LiteralPath (Join-Path $downloadContext.CachePath '52165') -File).Count -eq 11) 'Download-only recovery could not distinguish legacy screenshots sharing a filename.'

    # Invoke the actual entry point in an already initialized caller scope.
    $cachedPath = Join-Path $fixtureRoot 'RecoveredDocumentImages/58145/step-71601.png'
    Remove-Item -LiteralPath $cachedPath
    $entryArticle = New-LegacyTestArticle
    @($entryArticle) | ConvertTo-Json -Depth 30 -AsArray | Set-Content -LiteralPath (Join-Path $logsPath 'Articles.json')
    $ITGlueHuduMigrationRun = @{LogsFolder=$logsPath}; $MigrationLogs=$logsPath; $FirstTimeLoad=1
    $ITGAPIEndpoint='https://api.example.invalid'; $ITGKey='offline-test-key'; $ITGURL='https://tenant.invalid'; $HuduBaseDomain='https://hudu.invalid'; $ITGlueJWT='test-jwt'
    $before = @($requests | Where-Object JWT).Count
    $entryResult = @(. "$repoRoot/Repair-ITGlueLegacyStepScreenshots.ps1" -DocumentId 58145 -DownloadOnly)
    Assert-Legacy ($entryResult.Count -eq 1 -and $entryResult[0].Status -eq 'Downloaded' -and @($requests | Where-Object JWT).Count -eq ($before + 1) -and $ITGlueJWT -ceq 'test-jwt') 'The entry point did not reuse the existing checklist JWT or changed its caller variable.'
    $loggedArticles = @(Get-Content -LiteralPath (Join-Path $logsPath 'Articles.json') -Raw | ConvertFrom-Json -Depth 40)
    Assert-Legacy ($loggedArticles.Count -eq 1 -and $loggedArticles[0].ImageRecoveries.Count -gt 0 -and (Test-Path -LiteralPath (Join-Path $logsPath 'LegacyStepScreenshotRecovery.json'))) 'The entry point did not persist article provenance and repair results.'
    foreach ($jsonFile in Get-ChildItem -LiteralPath $logsPath -File -Recurse -Filter '*.json') {
        Assert-Legacy ((Get-Content -LiteralPath $jsonFile.FullName -Raw) -notmatch 'test-jwt|X-Amz-Signature') 'A JWT or signed query string leaked into saved logs.'
    }
    $readme = Get-Content -LiteralPath (Join-Path $repoRoot 'README.md') -Raw
    Assert-Legacy ($readme -notmatch 'Repair-ITGlueLegacyStepScreenshots|ITGlueWebSession' -and $readme -match 'Legacy step screenshots can be inconsistent') 'The README advertises the optional script/authentication flow or omits the requested limitation note.'
    $initializer = Get-Content -LiteralPath (Join-Path $repoRoot 'Initialize-Module.ps1') -Raw
    Assert-Legacy ($initializer -notmatch 'Repair-ITGlueLegacyStepScreenshots') 'The standalone repair was added to normal initialization.'
    Write-Output "Passed $checks standalone legacy screenshot repair checks (offline)."
} finally {
    Remove-Item -LiteralPath $gate.StatePath -Force -ErrorAction SilentlyContinue
    $defaultGate = Get-Variable -Name ITGluePasswordRequestGate -Scope Script -ValueOnly -ErrorAction Ignore
    if ($defaultGate) { Remove-Item -LiteralPath $defaultGate.StatePath -Force -ErrorAction SilentlyContinue }
    $tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([char[]]@('\', '/'))
    $cleanupPath = [IO.Path]::GetFullPath($fixtureRoot)
    if ((Split-Path $cleanupPath -Parent) -ne $tempParent -or (Split-Path $cleanupPath -Leaf) -notmatch '^itglue-legacy-repair-[a-f0-9]{32}$') { throw 'Refusing cleanup outside the legacy repair fixture.' }
    Remove-Item -LiteralPath $cleanupPath -Recurse -Force
}
