#requires -Version 7.2
# All IT Glue metadata, image downloads, and Hudu uploads are mocked offline.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
. "$repoRoot/Public/Resolve-ITGlueDocumentImage.ps1"
. "$repoRoot/Public/Resolve-ArticleAttachmentImage.ps1"
. "$repoRoot/Public/Repair-ITGlueLegacyStepScreenshots.ps1"
$checks = 0
function Assert-Recovery { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message }; $script:checks++ }
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) "itglue-document-images-$([guid]::NewGuid().ToString('N'))"
$logsPath = Join-Path $fixtureRoot 'logs'
$null = [IO.Directory]::CreateDirectory($logsPath)
$gate = New-ITGluePasswordRequestGate -MinimumIntervalMilliseconds 0
$resources = @{}
$metadataCalls = [Collections.Generic.List[string]]::new()
$downloadCalls = [Collections.Generic.List[object]]::new()
$publicPhotoCalls = [Collections.Generic.List[string]]::new()
$publicPhotoFailures = @{}
$downloadFailures = @{}
$webPages = @{}
$webCalls = [Collections.Generic.List[object]]::new()
$png = [Convert]::FromBase64String('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==')
function New-TestHttpError {
    param([int]$Status)
    $response = [Net.Http.HttpResponseMessage]::new([Net.HttpStatusCode]$Status)
    return [Microsoft.PowerShell.Commands.HttpResponseException]::new("Mock HTTP $Status", $response)
}
function Invoke-RestMethod {
    [CmdletBinding()]
    param($Method, [string]$Uri, $Headers)
    if ($Headers['x-api-key'] -ne 'offline-test-key') { throw 'Metadata request lost API authentication.' }
    $resource = ([Uri]$Uri).AbsolutePath.TrimStart('/')
    $metadataCalls.Add($resource)
    if (-not $resources.ContainsKey($resource)) { throw (New-TestHttpError 404) }
    if ($resources[$resource] -is [int]) { throw (New-TestHttpError $resources[$resource]) }
    return @{data=$resources[$resource]}
}
function Invoke-WebRequest {
    [CmdletBinding()]
    param($Method, [string]$Uri, [string]$OutFile, $TimeoutSec, $Headers, $WebSession)
    if ($webPages.ContainsKey($Uri)) {
        $webCalls.Add([pscustomobject]@{Uri=$Uri; Headers=$Headers; Session=$WebSession})
        return @{Content=$webPages[$Uri]}
    }
    $downloadCalls.Add([pscustomobject]@{Uri=$Uri; Headers=$Headers; OutFile=$OutFile})
    if ($downloadFailures.ContainsKey($Uri)) {
        [IO.File]::WriteAllText($OutFile, '<html>Access denied</html>')
        if ($downloadFailures[$Uri] -eq 'throw') { throw (New-TestHttpError 403) }
    } else { [IO.File]::WriteAllBytes($OutFile, $png) }
}
function New-TestArticle {
    param([string]$Id = '2027763')
    return [pscustomobject]@{ITGID=$Id; HuduID=383; Name='Backup'; Company=[pscustomobject]@{CompanyName='Offline'}; HuduObject=[pscustomobject]@{url='https://hudu.invalid/kba/backup'}; ITGLocator="DOC-2395254-$Id"}
}
function New-TestContext {
    param([Microsoft.PowerShell.Commands.WebRequestSession]$WebSession)
    $context = if ($WebSession) {
        New-ITGlueLegacyScreenshotRecoveryContext -ApiBase 'https://api.example.invalid' -ApiKey 'offline-test-key' -MigrationLogsPath $logsPath -TenantBase 'https://tenant.invalid' -WebSession $WebSession
    } else {
        New-ITGlueDocumentImageRecoveryContext -ApiBase 'https://api.example.invalid' -ApiKey 'offline-test-key' -MigrationLogsPath $logsPath
    }
    $context.RequestGate = $gate
    return $context
}
function Register-TestImage {
    param([string]$Id, [string]$Document = '2027763', [string]$Name = 'photo.png')
    $resources["document_images/$Id"] = @{id=$Id; type='document-images'; attributes=@{
        'document-id'=$Document; name=$Name
        'original-src'="https://storage.invalid/images/$Id/original/$Name`?signature=private"
        'slim-src'="https://storage.invalid/images/$Id/slim/$Name"
        'thumbnail-src'="https://storage.invalid/images/$Id/thumbnail/$Name"
    }}
}
function Register-BlankDocument {
    param([string]$Document = '2027763', [string]$First = '901', [string]$Second = '902')
    Register-TestImage $First $Document 'first.png'
    Register-TestImage $Second $Document 'second.png'
    $resources["documents/$Document"] = @{id=$Document; attributes=@{sections=@(
        @{attributes=@{sort=2; content="<p><img src='/$Document/docs/$Document/developer/images/$Second'></p>"; 'rendered-content'="<img src='https://storage.invalid/document/developer/images/$Second/original/second.png'>"}}
        @{attributes=@{sort=1; content="<p><img src='/$Document/docs/$Document/images/$First'></p>"; 'rendered-content'="<img src='https://storage.invalid/document/developer/images/$First/original/first.png'>"}}
    )}}
}

try {
    $references = Get-ITGlueDocumentImageReferences @('<img src="https://tenant.invalid/1/docs/2027763/developer/images/123?x=1">', 'https://s3.invalid/document/developer/images/000/000/123/original/test%20photo.png')
    Assert-Recovery ($references.Ids.Count -eq 1 -and $references.Ids[0] -eq '123' -and $references.DocumentIds[0] -eq '2027763' -and 'test photo.png' -in $references.Names) 'Image ID, document ID, or sharded/encoded storage reference parsing failed.'

    Register-TestImage '101'
    $article = New-TestArticle
    $context = New-TestContext
    $result = Resolve-ITGlueDocumentImage $article -SourceValues @('/2395254/docs/2027763/images/101', 'https://storage.invalid/document/images/000/000/101/original/photo.png?signature=private') -ImageIndex 0 -Context $context
    Assert-Recovery ($null -ne $result.File -and $result.Record.DownloadedViaApi -and $result.Record.MatchMethod -eq 'ImageId') "Direct ID recovery failed: $($result.Reason)"
    Assert-Recovery ($result.Record.DownloadVariant -eq 'original-src' -and $result.Record.DownloadUrl -notmatch 'signature') 'Original image preference or signed-URL log redaction failed.'
    Assert-Recovery ($downloadCalls.Count -eq 1 -and $null -eq $downloadCalls[0].Headers) 'A download was duplicated or received API credentials.'
    $sidecar = Join-Path $logsPath 'DocumentImageRecovery/2027763.json'
    $saved = @(Get-Content -LiteralPath $sidecar -Raw | ConvertFrom-Json)
    Assert-Recovery ($saved.Count -eq 1 -and $saved[0].DownloadedViaApi -and @($article.ImageRecoveries).Count -eq 1) 'Recovery provenance was not saved to both the article and JSON sidecar.'
    Assert-Recovery ((Get-Content -LiteralPath $sidecar -Raw) -notmatch 'signature=|offline-test-key') 'Signed URL query strings or API credentials leaked into the recovery log.'
    $result = Resolve-ITGlueDocumentImage $article -SourceValues @('/2395254/docs/2027763/images/101') -ImageIndex 0 -Context $context
    Assert-Recovery ($result.Record.UsedCachedDownload -and $downloadCalls.Count -eq 1 -and @($metadataCalls | Where-Object { $_ -eq 'document_images/101' }).Count -eq 1 -and $article.ImageRecoveries.Count -eq 1) 'Cached image recovery redownloaded files, repeated metadata requests, or duplicated audit entries.'

    # ArticleBase preserves original references before HTML parsing/rewriting.
    # Its snapshot must win even when the live document has different images.
    . "$repoRoot/Public/Start-ArticleStubs.ps1"
    function Initialize-HuduFolder { param($Folders, $company_id) return @{id=12} }
    function New-HuduArticle { param($name, $content, $company_id, $folder_id) return @{article=[pscustomobject]@{id=606; content=$content}} }
    $stubRoot = Join-Path $fixtureRoot 'stub-export/Documents'
    $stubDirectory = Join-Path $stubRoot 'Records/DOC-2395254-6060 Original'
    $null = [IO.Directory]::CreateDirectory($stubDirectory)
    $stubHtmlPath = Join-Path $stubDirectory 'Original.html'
    $originalHtml = '<img alt="original > thumbnail" src="/2395254/docs/6060/images/601" data-src-original="https://storage.invalid/document/images/000/000/601/original/original-one.png"><img src="/2395254/docs/6060/images/602" data-src-original="https://storage.invalid/document/images/000/000/602/original/original-two.png">'
    [IO.File]::WriteAllText($stubHtmlPath, $originalHtml)
    $document = [pscustomobject]@{id='6060'; locator='DOC-2395254-6060'; name='Original'; organization='Offline'}
    $company = [pscustomobject]@{CompanyName='Offline'; InternalCompany=$false; HuduID=9}
    try {
        Set-StrictMode -Off
        $stub = Start-ArticleStubs -Document $document -Files @(Get-ChildItem -LiteralPath $stubRoot -Recurse) -ITGDocumentsPath $stubRoot -MatchedCompanies @($company) 6>$null
    } finally { Set-StrictMode -Version Latest }
    Assert-Recovery ($stub.SourceImages.Count -eq 2 -and $stub.SourceImages[0].Index -eq 0 -and $stub.SourceImages[0].ImageIds[0] -eq '601' -and 'original-two.png' -in $stub.SourceImages[1].FileNames) 'Article stubs did not preserve original image IDs, filenames, and order.'
    Assert-Recovery ($stub.SourceImages[0].Html -like '*original > thumbnail*' -and $stub.HuduObject.content -eq 'Migration in progress') 'Snapshot parsing truncated quoted HTML or confused the Hudu stub with source content.'
    $stub | ConvertTo-Json -Depth 30 -AsArray | Set-Content -LiteralPath (Join-Path $logsPath 'ArticleBase.json')
    Register-BlankDocument '6060' '699' '698'
    Register-TestImage '601' '6060' 'original-one.png'
    Register-TestImage '602' '6060' 'original-two.png'
    $snapshotArticle = New-TestArticle '6060'
    $snapshotContext = New-TestContext
    $snapshotTags = @('<img src="">', '<img src="">')
    $snapshotFirst = Resolve-ITGlueDocumentImage $snapshotArticle -SourceValues @($snapshotTags[0]) -ImageIndex 0 -ExportImageTags $snapshotTags -Context $snapshotContext
    $snapshotSecond = Resolve-ITGlueDocumentImage $snapshotArticle -SourceValues @($snapshotTags[1]) -ImageIndex 1 -ExportImageTags $snapshotTags -Context $snapshotContext
    Assert-Recovery ($null -ne $snapshotFirst.File -and $null -ne $snapshotSecond.File -and $snapshotFirst.Record.ITGImageId -eq '601' -and $snapshotSecond.Record.ITGImageId -eq '602' -and $snapshotFirst.Record.ReferenceSource -eq 'ArticleBase.json') 'Saved ArticleBase references were not preferred over the changed live document.'
    Assert-Recovery (@($metadataCalls | Where-Object { $_ -eq 'documents/6060' }).Count -eq 0) 'Preserved image IDs unnecessarily fetched current document sections.'
    $result = Resolve-ITGlueDocumentImage $stub -SourceValues @('original-two.png') -ImageIndex 0 -ExportImageTags @('<img src="original-two.png">') -Context (New-TestContext)
    Assert-Recovery ($null -ne $result.File -and $result.Record.ITGImageId -eq '602' -and $result.Record.ReferenceSource -eq 'PreservedSourceImages') 'A preserved unique filename did not map to its original image ID independently of image count.'
    $result = Resolve-ITGlueDocumentImage (New-TestArticle '6060') -SourceValues @('<img src="">') -ImageIndex 0 -ExportImageTags @('<img src="">') -Context (New-TestContext)
    Assert-Recovery ($null -eq $result.File -and $result.Reason -like '*align*') 'A mismatched snapshot image count was used to guess an image.'
    $result = Resolve-ITGlueDocumentImage (New-TestArticle '6060') -SourceValues @('<img src="">') -ImageIndex 0 -ExportImageTags @('<img src="">', '<img src="/1/docs/6060/images/601">') -Context (New-TestContext)
    Assert-Recovery ($null -eq $result.File -and $result.Reason -like '*order disagree*') 'Contradictory preserved image references were accepted by position.'
    Register-TestImage '701' '7070'
    $oldSourcePath = Join-Path $fixtureRoot 'old-export.html'
    [IO.File]::WriteAllText($oldSourcePath, '<img src="/2395254/docs/7070/images/701">')
    $oldArticle = New-TestArticle '7070'
    $oldArticle | Add-Member -NotePropertyName FullPath -NotePropertyValue $oldSourcePath
    $result = Resolve-ITGlueDocumentImage $oldArticle -SourceValues @('<img src="">') -ImageIndex 0 -ExportImageTags @('<img src="">') -Context (New-TestContext)
    Assert-Recovery ($null -ne $result.File -and $result.Record.ITGImageId -eq '701' -and $result.Record.ReferenceSource -eq 'ExportHtml') 'Older logs did not use the original exported HTML when no snapshot was stored.'

    # The observed export contains two <img src=""> tags. Recover their positions
    # from the sorted API sections only when image counts and anchors align.
    Register-BlankDocument
    $article = New-TestArticle
    $context = New-TestContext
    $emptyTags = @('<img src="">', '<img src="">')
    $first = Resolve-ITGlueDocumentImage $article -SourceValues @($emptyTags[0]) -ImageIndex 0 -ExportImageTags $emptyTags -Context $context
    $second = Resolve-ITGlueDocumentImage $article -SourceValues @($emptyTags[1]) -ImageIndex 1 -ExportImageTags $emptyTags -Context $context
    Assert-Recovery ($null -ne $first.File -and $null -ne $second.File -and $first.Record.ITGImageId -eq '901' -and $second.Record.ITGImageId -eq '902' -and $first.Record.MatchMethod -eq 'DocumentImageOrder') "Blank-source image recovery did not follow document section order: $($first.Reason); $($second.Reason)"
    Assert-Recovery (@($metadataCalls | Where-Object { $_ -eq 'documents/2027763' }).Count -eq 1) 'Each missing image refetched its document.'
    $result = Resolve-ITGlueDocumentImage (New-TestArticle) -SourceValues @('<img src="">') -ImageIndex 0 -ExportImageTags @('<img src="">') -Context $context
    Assert-Recovery ($null -eq $result.File -and $result.Reason -like '*align*') 'Mismatched image counts were guessed by position.'
    $result = Resolve-ITGlueDocumentImage (New-TestArticle) -SourceValues @('<img src="">') -ImageIndex 0 -ExportImageTags @('<img src="">', '<img src="/1/docs/2027763/images/901">') -Context $context
    Assert-Recovery ($null -eq $result.File -and $result.Reason -like '*order disagree*') 'Contradictory image-order anchors were ignored.'
    $result = Resolve-ITGlueDocumentImage (New-TestArticle) -SourceValues @('first.png') -Context $context
    Assert-Recovery ($null -ne $result.File -and $result.Record.ITGImageId -eq '901' -and $result.Record.MatchMethod -eq 'DocumentImageFilename') 'Document-scoped filenames were not matched to rendered section images.'

    Register-TestImage '201' '999'
    $result = Resolve-ITGlueDocumentImage (New-TestArticle) -SourceValues @('/1/docs/2027763/images/201') -Context (New-TestContext)
    Assert-Recovery ($null -eq $result.File -and $result.Reason -like '*another*document*') 'An image owned by another document was accepted.'
    $before = $metadataCalls.Count
    $result = Resolve-ITGlueDocumentImage (New-TestArticle) -SourceValues @('/1/docs/999/images/201') -Context (New-TestContext)
    Assert-Recovery ($null -eq $result.File -and $metadataCalls.Count -eq $before) 'A foreign document reference was queried or accepted.'

    Register-TestImage '301'
    $originalUrl = $resources['document_images/301'].attributes['original-src']
    $downloadFailures[$originalUrl] = 'html'
    $result = Resolve-ITGlueDocumentImage (New-TestArticle) -SourceValues @('/1/docs/2027763/images/301') -Context (New-TestContext)
    Assert-Recovery ($null -ne $result.File -and $result.Record.DownloadVariant -eq 'slim-src') 'An HTML response was accepted as an image or prevented variant fallback.'
    Assert-Recovery (@(Get-ChildItem -LiteralPath (Split-Path $result.File.FullName -Parent) -File -Filter '*.tmp').Count -eq 0) 'Failed downloads left temporary files behind.'
    Register-TestImage '302'
    foreach ($variant in @('original-src', 'slim-src', 'thumbnail-src')) { $downloadFailures[$resources['document_images/302'].attributes[$variant]] = 'throw' }
    $result = Resolve-ITGlueDocumentImage (New-TestArticle) -SourceValues @('/1/docs/2027763/images/302') -Context (New-TestContext)
    Assert-Recovery ($null -eq $result.File -and $result.Record.Status -eq 'Failed' -and -not $result.Record.DownloadedViaApi) 'Failed downloads were marked recovered or lost failure provenance.'
    $resources['document_images/401'] = 401
    $context = New-TestContext
    $result = Resolve-ITGlueDocumentImage (New-TestArticle) -SourceValues @('/1/docs/2027763/images/401') -Context $context
    $before = $metadataCalls.Count
    $result = Resolve-ITGlueDocumentImage (New-TestArticle) -SourceValues @('/1/docs/2027763/images/402') -Context $context
    Assert-Recovery ($context.ApiUnavailable -and $metadataCalls.Count -eq $before -and $null -eq $result.File) 'Unavailable API permissions caused repeated requests or fabricated a recovered image.'
    $context = New-TestContext; $context.ApiKey = ''
    $result = Resolve-ITGlueDocumentImage (New-TestArticle) -SourceValues @('/1/docs/2027763/images/101') -Context $context
    Assert-Recovery ($null -eq $result.File -and $metadataCalls.Count -eq $before) 'Missing API credentials did not preserve offline/manual-action behavior.'
    $resources['document_images/403'] = 403
    Register-TestImage '404'
    $context = New-TestContext
    $null = Resolve-ITGlueDocumentImage (New-TestArticle) -SourceValues @('/1/docs/2027763/images/403') -Context $context
    $before = $metadataCalls.Count
    $null = Resolve-ITGlueDocumentImage (New-TestArticle) -SourceValues @('/1/docs/2027763/images/403') -Context $context
    $result = Resolve-ITGlueDocumentImage (New-TestArticle) -SourceValues @('/1/docs/2027763/images/404') -Context $context
    Assert-Recovery ($null -ne $result.File -and $metadataCalls.Count -eq ($before + 1)) 'One restricted image disabled recovery for readable images or repeatedly queried the denied image.'

    Register-TestImage '444' '' 'gallery.png'
    $gallery = $resources['document_images/444']
    $resources['documents/3030'] = @{id='3030'; attributes=@{sections=@(@{attributes=@{sort=0; 'resource-type'='Document::Gallery'; 'document-images'=@($gallery)}})}}
    $resources['document_images/444'] = 404
    $result = Resolve-ITGlueDocumentImage (New-TestArticle '3030') -SourceValues @('<img src="">') -ImageIndex 0 -ExportImageTags @('<img src="">') -Context (New-TestContext)
    Assert-Recovery ($null -ne $result.File -and $result.Record.ITGImageId -eq '444') "Verified gallery metadata was not used when the individual image lookup was unavailable: $($result.Reason)"

    # Real legacy shape from document 58145: the gallery exposes signed URLs,
    # while a Step screenshot is only in content[].resource, with no API URL.
    Register-TestImage '40108' '58145' 'Dragon_Logo.jpg'
    $resources['documents/58145'] = @{id='58145'; attributes=@{
        'resource-url'='https://tenant.invalid/91889/docs/58145'
        sections=@(
            @{id='256189'; attributes=@{sort=0; 'resource-type'='Document::Gallery'; 'document-images'=@($resources['document_images/40108'])}}
            @{id='256231'; attributes=@{sort=1; 'resource-type'='Document::Step'; 'resource-id'=71601; content='<p>Instructions</p>'; 'document-images'=@()}}
        )
        content=@(@{id=256231; document_id=58145; sort=1; resource_type='Document::Step'; resource=@{id=71601; screenshot_file_name='Generic_USB_Hub_Properties.jpg'; screenshot_file_size=26880}})
    }}
    $legacyTags = @("<img data-src-original='original/Dragon_Logo.jpg' src='thumbnail/Dragon_Logo.jpg'>", "<img data-src-original='original/Generic_USB_Hub_Properties.jpg' src='thumbnail/Generic_USB_Hub_Properties.jpg'>")
    $legacyArticle = New-TestArticle '58145'
    $result = Resolve-ITGlueDocumentImage $legacyArticle -SourceValues @($legacyTags[1]) -ImageIndex 1 -ExportImageTags $legacyTags -Context (New-TestContext)
    Assert-Recovery ($null -eq $result.File -and $result.Record.ImageResourceType -eq 'LegacyStepScreenshot' -and $result.Reason -like '*public API*') 'A legacy screenshot was not recognized or still reported only an image-count alignment error.'
    Assert-Recovery (@($metadataCalls | Where-Object { $_ -eq 'document_images/71601' }).Count -eq 0) 'A step screenshot ID was incorrectly queried as a document-image ID.'
    $signedScreenshotUrl = 'https://storage.invalid/document/steps/screenshots/000/071/601/slim/Generic_USB_Hub_Properties.jpg?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Signature=abc%2Bdef%2Fghi%3D'
    $legacyRefs = Get-ITGlueDocumentImageReferences @($signedScreenshotUrl, 'https://storage.invalid/document/images/images/000/040/108/original/Dragon_Logo.jpg')
    Assert-Recovery ($legacyRefs.StepIds[0] -eq '71601' -and $legacyRefs.Ids.Count -eq 1 -and $legacyRefs.Ids[0] -eq '40108') 'Legacy screenshot IDs were confused with document-image IDs or double-images storage paths failed to parse.'
    $webSession = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
    $webPages['https://tenant.invalid/91889/docs/58145'] = '<img src="' + [Net.WebUtility]::HtmlEncode($signedScreenshotUrl) + '">'
    $context = New-TestContext -WebSession $webSession
    $result = Resolve-ITGlueDocumentImage (New-TestArticle '58145') -SourceValues @($legacyTags[1]) -ImageIndex 1 -ExportImageTags $legacyTags -Context $context
    Assert-Recovery ($null -ne $result.File -and $result.File.BaseName -eq 'step-71601' -and $result.Record.ITGSectionId -eq '256231' -and $result.Record.DownloadVariant -eq 'slim' -and -not $result.Record.DownloadedViaApi) "Authenticated web screenshot recovery failed: $($result.Reason)"
    Assert-Recovery ($downloadCalls[-1].Uri -ceq $signedScreenshotUrl -and $null -eq $downloadCalls[-1].Headers) 'The signed URL was decoded, reconstructed, or downloaded with API credentials.'
    Assert-Recovery ($webCalls.Count -eq 1 -and [object]::ReferenceEquals($webCalls[0].Session, $webSession) -and $null -eq $webCalls[0].Headers) 'The tenant HTML request did not use the supplied session or received the API key.'
    $before = $webCalls.Count
    $result = Resolve-ITGlueDocumentImage (New-TestArticle '58145') -SourceValues @($legacyTags[1]) -ImageIndex 1 -ExportImageTags $legacyTags -Context (New-TestContext)
    Assert-Recovery ($null -ne $result.File -and $result.Record.UsedCachedDownload -and $result.Record.DownloadUrlSource -eq 'Cache' -and $webCalls.Count -eq $before) 'A cached legacy screenshot unnecessarily required a web session or another download.'
    $legacySidecar = Join-Path $logsPath 'DocumentImageRecovery/58145.json'
    Assert-Recovery ((Get-Content -LiteralPath $legacySidecar -Raw) -notmatch 'X-Amz-Signature|offline-test-key') 'A screenshot recovery log retained a signed query string or API key.'

    # Name matching is document scoped and still rejects a different step ID.
    $result = Resolve-ITGlueDocumentImage (New-TestArticle '58145') -SourceValues @($signedScreenshotUrl.Replace('/071/601/', '/071/602/')) -ImageIndex 1 -ExportImageTags $legacyTags -Context (New-TestContext)
    Assert-Recovery ($null -eq $result.File -and $result.Reason -like '*another legacy screenshot*') 'A same-named screenshot from another step was accepted.'
    $context = New-TestContext -WebSession $webSession
    $context.DocumentUrls['58145'] = 'https://other-tenant.invalid/91889/docs/58145'
    $rejected = $false; $before = $webCalls.Count
    try { $null = Get-ITGlueLegacyScreenshotUrls $context '58145' '71601' } catch { $rejected = $true }
    Assert-Recovery ($rejected -and $webCalls.Count -eq $before) 'An authenticated request was sent to an unverified tenant.'
    $context = New-TestContext -WebSession $webSession
    $context.DocumentUrls['58145'] = 'https://tenant.invalid/91889/docs/58145'
    $savedPage = $webPages[$context.DocumentUrls['58145']]
    $webPages[$context.DocumentUrls['58145']] = '<html><form>Sign in</form></html>'
    $failure = ''
    try { $null = Get-ITGlueLegacyScreenshotUrls $context '58145' '71601' } catch { $failure = $_.Exception.Message }
    finally { $webPages[$context.DocumentUrls['58145']] = $savedPage }
    Assert-Recovery ($failure -like '*web session may be expired*') 'A login page was mistaken for a screenshot download or lost its authentication diagnostic.'
    Register-TestImage '888' '8888' 'repeated.png'
    $resources['documents/8888'] = @{id='8888'; attributes=@{sections=@(
        @{attributes=@{sort=0; content='<img src="/1/docs/8888/images/888">'; 'rendered-content'='<img src="https://storage.invalid/document/developer/images/888/original/repeated.png">'}}
        @{attributes=@{sort=1; 'document-images'=@($resources['document_images/888'])}}
    )}}
    $result = Resolve-ITGlueDocumentImage (New-TestArticle '8888') -SourceValues @('repeated.png') -Context (New-TestContext)
    Assert-Recovery ($null -ne $result.File -and $result.Record.ITGImageId -eq '888') 'The same canonical image appearing inline and in a gallery was treated as two different identities.'

    # Exercise the actual main-script image loop with two blank-source DOM nodes.
    # The fake DOM only replaces COM; resolution, validation, and image placement
    # execute the real migration code, with only the Hudu network call mocked.
    function Normalize-And-ConvertImage { param($InputPath) return @{FinalPath=$InputPath; Original=$InputPath} }
    function New-HuduPublicPhoto {
        [CmdletBinding()]
        param([string]$FilePath, $record_id, $record_type)
        $publicPhotoCalls.Add($FilePath)
        if ($publicPhotoFailures.ContainsKey([IO.Path]::GetFileName($FilePath))) { throw 'Simulated Hudu photo upload failure' }
        return @{public_photo=@{url="https://hudu.invalid/images/$([IO.Path]::GetFileName($FilePath))"}}
    }
    function Write-ErrorObjectsToFile { param($ErrorObject, $name) }
    $tokens = $null; $parseErrors = $null
    $mainAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'ITGlue-Hudu-Migration.ps1'), [ref]$tokens, [ref]$parseErrors)
    $loop = $mainAst.Find({param($node) $node -is [Management.Automation.Language.ForEachStatementAst] -and $node.Variable.VariablePath.UserPath -eq 'imageObject'}, $true)
    Assert-Recovery ($parseErrors.Count -eq 0 -and $null -ne $loop) 'Could not locate the real main image loop.'
    $Article = New-TestArticle
    $documentImageRecoveryContext = New-TestContext
    $images = @([pscustomobject]@{src=''; outerHTML=$emptyTags[0]; innerHTML=''}, [pscustomobject]@{src=''; outerHTML=$emptyTags[1]; innerHTML=''})
    $html = [pscustomobject]@{Links=@()}
    $exportImageTags = $emptyTags
    $InFile = Join-Path $fixtureRoot 'Backup.html'
    $Attachfiles = @(); $ITGlueExportPath = $fixtureRoot
    $ITGURL = 'https://tenant.invalid'; $HuduBaseDomain = 'https://hudu.invalid'
    $ImageMap = @{}; $ManualActions = [Collections.ArrayList]::new()
    $articleBodyImageIndex = 0; $articleBodyImageTotal = 2
    $articleBodyImageProgressId = 33; $articleBodyProgressId = 32
    try {
        Set-StrictMode -Off
        . ([scriptblock]::Create($loop.Extent.Text)) 6>$null
    } finally { Set-StrictMode -Version Latest }
    Assert-Recovery ($publicPhotoCalls.Count -eq 2 -and $images[0].src -eq '/images/901.png' -and $images[1].src -eq '/images/902.png' -and $ManualActions.Count -eq 0) 'The normal image-upload loop did not recover and place both missing images.'
    Assert-Recovery ($Article.ImageRecoveries.Count -eq 2 -and @($Article.ImageRecoveries | Where-Object { $_.Status -ne 'Placed' -or -not $_.HuduImageUrl }).Count -eq 0) 'Successful image placement was not recorded in article recovery metadata.'
    $saved = @(Get-Content -LiteralPath $sidecar -Raw | ConvertFrom-Json)
    Assert-Recovery ($saved.Count -eq 2 -and @($saved | Where-Object Status -eq 'Placed').Count -eq 2) 'Placed image status was not persisted to JSON.'

    $publicPhotoCalls.Clear(); $publicPhotoFailures['901.png'] = $true
    $Article = New-TestArticle; $documentImageRecoveryContext = New-TestContext
    $images = @([pscustomobject]@{src=''; outerHTML=$emptyTags[0]; innerHTML=''}, [pscustomobject]@{src=''; outerHTML=$emptyTags[1]; innerHTML=''})
    $articleBodyImageIndex = 0; $ImageMap = @{}; $ManualActions.Clear()
    try { Set-StrictMode -Off; . ([scriptblock]::Create($loop.Extent.Text)) 6>$null }
    finally { Set-StrictMode -Version Latest }
    Assert-Recovery ($publicPhotoCalls.Count -eq 2 -and $ManualActions.Count -eq 1 -and $images[0].src -eq '' -and $images[1].src -eq '/images/902.png') 'A failed recovered-image upload stopped subsequent images or removed the manual action.'
    Assert-Recovery (@($Article.ImageRecoveries | Where-Object Status -eq 'UploadFailed').Count -eq 1 -and @($Article.ImageRecoveries | Where-Object Status -eq 'Placed').Count -eq 1) 'Upload failures were logged as successful placement.'

    $publicPhotoFailures.Clear(); $publicPhotoCalls.Clear(); $ManualActions.Clear()
    $localImage = Join-Path $fixtureRoot 'local-image.png'
    [IO.File]::WriteAllBytes($localImage, $png)
    $Article = New-TestArticle; $documentImageRecoveryContext = New-TestContext
    $images = @([pscustomobject]@{src='local-image.png'; outerHTML='<img src="local-image.png">'; innerHTML=''})
    $exportImageTags = @($images[0].outerHTML)
    $articleBodyImageIndex = 0; $articleBodyImageTotal = 1; $ImageMap = @{}
    $before = $metadataCalls.Count
    try { Set-StrictMode -Off; . ([scriptblock]::Create($loop.Extent.Text)) 6>$null }
    finally { Set-StrictMode -Version Latest }
    Assert-Recovery ($publicPhotoCalls.Count -eq 1 -and $metadataCalls.Count -eq $before -and $images[0].src -eq '/images/local-image.png') 'An existing exported image unnecessarily triggered API recovery or stopped uploading normally.'

    $publicPhotoCalls.Clear(); $ManualActions.Clear()
    $Article = New-TestArticle; $documentImageRecoveryContext = New-TestContext; $documentImageRecoveryContext.ApiKey = ''
    $images = @([pscustomobject]@{src=''; outerHTML=$emptyTags[0]; innerHTML=''}, [pscustomobject]@{src=''; outerHTML=$emptyTags[1]; innerHTML=''})
    $exportImageTags = $emptyTags; $articleBodyImageIndex = 0; $articleBodyImageTotal = 2
    try { Set-StrictMode -Off; . ([scriptblock]::Create($loop.Extent.Text)) 3>$null 6>$null }
    finally { Set-StrictMode -Version Latest }
    Assert-Recovery ($ManualActions.Count -eq 2 -and $publicPhotoCalls.Count -eq 0 -and @($ManualActions | Where-Object { $_.ImageRecoveryReason -notlike '*not configured*' -or $_.ImageSources.Count -lt 1 }).Count -eq 0) 'Unrecoverable images lost their manual actions, source references, or API recovery reason.'

    # The standalone/legacy body-preparation path uses the same recovery helper.
    $legacyAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'Public/Start-ArticleContent.ps1'), [ref]$tokens, [ref]$parseErrors)
    $legacyCommand = $legacyAst.Find({param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'ForEach-Object' -and $node.Extent.Text.Contains('$legacyImageIndex++')}, $true)
    $legacyBlock = $legacyCommand.CommandElements[1].ScriptBlock.GetScriptBlock()
    $Article = New-TestArticle; $documentImageRecoveryContext = New-TestContext
    $images = @([pscustomobject]@{src=''; outerHTML=$emptyTags[0]; innerHTML=''}, [pscustomobject]@{src=''; outerHTML=$emptyTags[1]; innerHTML=''})
    $legacyImageIndex = -1; $publicPhotoCalls.Clear()
    try { Set-StrictMode -Off; $legacyErrors = @($images | ForEach-Object $legacyBlock 6>$null) }
    finally { Set-StrictMode -Version Latest }
    Assert-Recovery ($legacyErrors.Count -eq 0 -and $publicPhotoCalls.Count -eq 2 -and $images[0].src -eq '/images/901.png' -and $images[1].src -eq '/images/902.png') 'The standalone article image path failed recovery or required nonexistent image links.'

    # The regular image loop never opts into web/JWT authentication. It can still
    # reuse files cached by the standalone repair, without any extra user flow.
    $stepCache = Join-Path $fixtureRoot 'RecoveredDocumentImages/58145/step-71601.png'
    Remove-Item -LiteralPath $stepCache
    $logoDirectory = Join-Path $fixtureRoot 'original'
    $null = [IO.Directory]::CreateDirectory($logoDirectory)
    [IO.File]::WriteAllBytes((Join-Path $logoDirectory 'Dragon_Logo.jpg'), $png)
    $Article = New-TestArticle '58145'
    $Article | Add-Member -NotePropertyName SourceImages -NotePropertyValue @(Get-ITGlueArticleSourceImages ($legacyTags -join ''))
    $documentImageRecoveryContext = New-TestContext
    $domTags = @($legacyTags | ForEach-Object { $_.Replace("'", '"') })
    $images = @(
        [pscustomobject]@{src='thumbnail/Dragon_Logo.jpg'; outerHTML=$domTags[0]; innerHTML=''}
        [pscustomobject]@{src='thumbnail/Generic_USB_Hub_Properties.jpg'; outerHTML=$domTags[1]; innerHTML=''}
    )
    $exportImageTags = $domTags; $articleBodyImageIndex = 0; $articleBodyImageTotal = 2
    $publicPhotoCalls.Clear(); $ManualActions.Clear(); $ImageMap = @{}
    $before = $webCalls.Count
    try { Set-StrictMode -Off; . ([scriptblock]::Create($loop.Extent.Text)) 6>$null }
    finally { Set-StrictMode -Version Latest }
    Assert-Recovery ($publicPhotoCalls.Count -eq 1 -and $ManualActions.Count -eq 1 -and $images[0].src -eq '/images/dragon_logo.jpg' -and $webCalls.Count -eq $before) 'The regular migration opted into authenticated legacy recovery or stopped uploading the existing export image.'
    [IO.File]::WriteAllBytes($stepCache, $png)
    $ManualActions.Clear(); $publicPhotoCalls.Clear()
    $images = @($images[1]); $exportImageTags = @($domTags[1]); $articleBodyImageIndex = 0; $articleBodyImageTotal = 1
    try { Set-StrictMode -Off; . ([scriptblock]::Create($loop.Extent.Text)) 6>$null }
    finally { Set-StrictMode -Version Latest }
    Assert-Recovery ($publicPhotoCalls.Count -eq 1 -and $ManualActions.Count -eq 0 -and $images[0].src -eq '/images/step-71601.png' -and $webCalls.Count -eq $before) 'Regular uploads could not reuse a cached legacy screenshot without authentication.'
    Write-Output "Passed $checks document-image recovery checks (offline)."
} finally {
    Remove-Item -LiteralPath $gate.StatePath -Force -ErrorAction SilentlyContinue
    $tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([char[]]@('\', '/'))
    $cleanupPath = [IO.Path]::GetFullPath($fixtureRoot)
    if ((Split-Path $cleanupPath -Parent) -ne $tempParent -or (Split-Path $cleanupPath -Leaf) -notmatch '^itglue-document-images-[a-f0-9]{32}$') { throw 'Refusing cleanup outside the recovery test fixture.' }
    Remove-Item -LiteralPath $cleanupPath -Recurse -Force
}
