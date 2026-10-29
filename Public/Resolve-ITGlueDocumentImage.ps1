# Read-only recovery through GET /document_images/:id and GET /documents/:id.
# https://api.itglue.com/developer/#documentimages
if (-not (Get-Command Invoke-ITGlueCommandWithRetry -ErrorAction SilentlyContinue)) { . "$PSScriptRoot/Get-ITGluePasswordWithRetry.ps1" }
if (-not (Get-Command Invoke-ImageTest -ErrorAction SilentlyContinue)) { . "$PSScriptRoot/../Private/Invoke-ImageTest.ps1" }
if (-not (Get-Command Get-ImageTypeFromSignature -ErrorAction SilentlyContinue)) { . "$PSScriptRoot/Normalize-And-ConvertImage.ps1" }

function Get-ITGlueDocumentImageProperty {
    param($Value, [string]$Name)
    if ($Value -is [Collections.IDictionary]) { return $Value[$Name] }
    if ($null -ne $Value -and $null -ne $Value.PSObject.Properties[$Name]) { return $Value.PSObject.Properties[$Name].Value }
}

function Get-ITGlueDocumentImageReferences {
    param([string[]]$SourceValues)
    $ids = [Collections.Generic.List[string]]::new()
    $documents = [Collections.Generic.List[string]]::new()
    $names = [Collections.Generic.List[string]]::new()
    foreach ($value in $SourceValues) {
        if ([string]::IsNullOrWhiteSpace($value)) { continue }
        $text = [Net.WebUtility]::HtmlDecode([Uri]::UnescapeDataString($value))
        foreach ($match in [regex]::Matches($text, '(?i)/docs/(?<document>\d+)/(?:developer/)?images/(?<id>\d+)(?=[/?#."''\s<>]|$)')) {
            $ids.Add($match.Groups['id'].Value)
            $documents.Add($match.Groups['document'].Value)
        }
        foreach ($match in [regex]::Matches($text, '(?i)/(?:document/(?:developer/)?images|developer/images)/(?<id>(?:\d{3}/){0,2}\d+)/(?:original|slim|thumbnail)/')) {
            $ids.Add(($match.Groups['id'].Value.Replace('/', '').TrimStart('0')))
        }
        foreach ($match in [regex]::Matches($text, '(?i)data-(?:document-)?image-id\s*=\s*["'']?(?<id>\d+)')) { $ids.Add($match.Groups['id'].Value) }
        $sources = if ($text -match '<\w') {
            foreach ($match in [regex]::Matches($text, '(?i)(?:\bsrc|data-src-original|data-original)\s*=\s*(?:"(?<source>[^"]*)"|''(?<source>[^'']*)''|(?<source>[^\s>]+))')) { $match.Groups['source'].Value }
        } else { $text }
        foreach ($source in $sources) {
            $leaf = [IO.Path]::GetFileName(($source -split '[?#]', 2)[0].Replace('\', '/')).Trim().ToLowerInvariant()
            if ($leaf -and $leaf -match '\.[a-z0-9]{2,5}$') { $names.Add($leaf) }
        }
    }
    return [pscustomobject]@{Ids=@($ids | Select-Object -Unique); DocumentIds=@($documents | Select-Object -Unique); Names=@($names | Select-Object -Unique)}
}

function New-ITGlueDocumentImageRecoveryContext {
    param([string]$ApiBase, [string]$ApiKey, [Parameter(Mandatory)][string]$MigrationLogsPath)
    return @{
        ApiBase=$ApiBase.Trim().TrimEnd('/'); ApiKey=$ApiKey; LogsPath=$MigrationLogsPath
        CachePath=(Join-Path (Split-Path $MigrationLogsPath -Parent) 'RecoveredDocumentImages')
        Documents=@{}; Images=@{}; ApiUnavailable=$false
        SourceImages=@{}; ArticleBaseLoaded=$false
        RequestGate=$null
    }
}

function Get-ITGlueArticleSourceImages {
    param([AllowEmptyString()][string]$Content)
    $index = 0
    foreach ($tag in [regex]::Matches($Content, '(?is)<img\b(?:[^>"'']|"[^"]*"|''[^'']*'')*>')) {
        $references = Get-ITGlueDocumentImageReferences @($tag.Value)
        [pscustomobject]@{Index=$index; ImageIds=$references.Ids; FileNames=$references.Names; Html=$tag.Value}
        $index++
    }
}

function Get-ITGlueArticleOriginalImage {
    param($Article, [int]$ImageIndex, [string[]]$ExportImageTags, $References, [hashtable]$Context)
    $documentId = [string](Get-ITGlueDocumentImageProperty $Article 'ITGID')
    $sourceImages = @(Get-ITGlueDocumentImageProperty $Article 'SourceImages')
    $source = 'PreservedSourceImages'
    if ($sourceImages.Count -eq 0) {
        if (-not $Context.ArticleBaseLoaded) {
            $Context.ArticleBaseLoaded = $true
            $basePath = Join-Path $Context.LogsPath 'ArticleBase.json'
            if (Test-Path -LiteralPath $basePath -PathType Leaf) {
                try {
                    foreach ($baseArticle in (Get-Content -LiteralPath $basePath -Raw | ConvertFrom-Json -Depth 100)) {
                        $baseId = [string](Get-ITGlueDocumentImageProperty $baseArticle 'ITGID')
                        $images = @(Get-ITGlueDocumentImageProperty $baseArticle 'SourceImages')
                        if ($baseId -match '^\d+$' -and $images.Count -gt 0) { $Context.SourceImages[$baseId] = @{Images=$images; Source='ArticleBase.json'} }
                    }
                } catch { Write-Verbose 'Unable to read original image references from ArticleBase.json; trying the source HTML or API.' }
            }
        }
        if (-not $Context.SourceImages.ContainsKey($documentId)) {
            $images = @()
            $path = [string](Get-ITGlueDocumentImageProperty $Article 'FullPath')
            if ($path -and (Test-Path -LiteralPath $path -PathType Leaf)) {
                $images = @(Get-ITGlueArticleSourceImages -Content (Get-Content -LiteralPath $path -Raw -Encoding utf8))
            }
            $Context.SourceImages[$documentId] = @{Images=$images; Source='ExportHtml'}
        }
        $sourceImages = @($Context.SourceImages[$documentId].Images)
        $source = $Context.SourceImages[$documentId].Source
    }
    if ($sourceImages.Count -eq 0) { return $null }
    $sequence = @($sourceImages | ForEach-Object {
        $html = [string](Get-ITGlueDocumentImageProperty $_ 'Html')
        [pscustomobject]@{Html=$html; References=(Get-ITGlueDocumentImageReferences @($html))}
    })
    $named = @($sequence | Where-Object { @($_.References.Names | Where-Object { $_ -in $References.Names }).Count -gt 0 })
    $item = $null
    if ($named.Count -eq 1) { $item = $named[0] }
    elseif ($ImageIndex -ge 0 -and $ImageIndex -lt $sequence.Count -and $ExportImageTags.Count -eq $sequence.Count) {
        for ($index = 0; $index -lt $sequence.Count; $index++) {
            $current = Get-ITGlueDocumentImageReferences @($ExportImageTags[$index])
            $original = $sequence[$index].References
            if ($current.Ids.Count -gt 0) {
                if (@($current.Ids | Where-Object { $_ -notin $original.Ids }).Count -gt 0) { return $null }
            } elseif ($current.Names.Count -gt 0 -and @($current.Names | Where-Object { $_ -in $original.Names }).Count -eq 0) { return $null }
        }
        $item = $sequence[$ImageIndex]
    }
    if ($null -eq $item -or ($item.References.Ids.Count -eq 0 -and $item.References.Names.Count -eq 0)) { return $null }
    return [pscustomobject]@{Html=$item.Html; Source=$source}
}

function Invoke-ITGlueDocumentImageMetadataRequest {
    param([hashtable]$Context, [string]$Resource)
    if (-not $Context.RequestGate) { $Context.RequestGate = Get-ITGluePasswordRequestGate }
    try {
        $response = Invoke-ITGlueCommandWithRetry -RequestGate $Context.RequestGate -MaxRetries 3 -OperationName "IT Glue image recovery $Resource" -Operation {
            Invoke-RestMethod -Method Get -Uri "$($Context.ApiBase)/$Resource" -Headers @{'x-api-key'=$Context.ApiKey} -ErrorAction Stop
        }
        return Get-ITGlueDocumentImageProperty $response 'data'
    } catch {
        $status = Get-ITGlueApiExceptionStatusCode $_
        # A 403 can apply to one restricted image/document; other documents may
        # still be readable. Its failed resource lookup is cached separately.
        if ($status -eq 401) { $Context.ApiUnavailable = $true }
        throw "IT Glue image recovery could not read $Resource (HTTP $status)."
    }
}

function Get-ITGlueDocumentImageSequence {
    param([hashtable]$Context, [string]$DocumentId)
    if (-not $Context.Documents.ContainsKey($DocumentId)) {
        # Cache failures too: a document with many missing images needs one lookup.
        $Context.Documents[$DocumentId] = @()
        $document = Invoke-ITGlueDocumentImageMetadataRequest $Context "documents/$DocumentId"
        if ([string](Get-ITGlueDocumentImageProperty $document 'id') -ne $DocumentId) { throw 'IT Glue returned a different document.' }
        $attributes = Get-ITGlueDocumentImageProperty $document 'attributes'
        $sections = @(Get-ITGlueDocumentImageProperty $attributes 'sections')
        if ($sections.Count -eq 0) { $sections = @(@{attributes=@{content=(Get-ITGlueDocumentImageProperty $attributes 'content')}}) }
        $sequence = [Collections.Generic.List[object]]::new()
        foreach ($section in ($sections | Sort-Object { Get-ITGlueDocumentImageProperty (Get-ITGlueDocumentImageProperty $_ 'attributes') 'sort' })) {
            $sectionAttributes = Get-ITGlueDocumentImageProperty $section 'attributes'
            $content = [string](Get-ITGlueDocumentImageProperty $sectionAttributes 'content')
            $renderedContent = [string](Get-ITGlueDocumentImageProperty $sectionAttributes 'rendered-content')
            if (-not $content) { $content = $renderedContent }
            $tags = @([regex]::Matches($content, '(?is)<img\b[^>]*>'))
            $renderedTags = @([regex]::Matches($renderedContent, '(?is)<img\b[^>]*>'))
            $tagIndex = 0
            $sectionIds = [Collections.Generic.List[string]]::new()
            foreach ($tag in $tags) {
                $sources = @($tag.Value)
                if ($renderedTags.Count -eq $tags.Count) { $sources += $renderedTags[$tagIndex].Value }
                $tagIndex++
                $references = Get-ITGlueDocumentImageReferences $sources
                $id = if ($references.Ids.Count -eq 1) { $references.Ids[0] } else { $null }
                if ($id) { $sectionIds.Add($id) }
                $sequence.Add([pscustomobject]@{Id=$id; Sources=$sources; Names=$references.Names; Metadata=$null})
            }
            foreach ($image in @(Get-ITGlueDocumentImageProperty $sectionAttributes 'document-images')) {
                if ($null -eq $image) { continue }
                $id = [string](Get-ITGlueDocumentImageProperty $image 'id')
                if ($id -notmatch '^\d+$') { continue }
                $imageAttributes = Get-ITGlueDocumentImageProperty $image 'attributes'
                if ($sectionIds.Contains($id)) {
                    foreach ($item in $sequence) { if ($item.Id -eq $id) { $item.Metadata = $image } }
                    continue
                }
                $sources = @('original-src', 'slim-src', 'thumbnail-src', 'inline-resource-url' | ForEach-Object { Get-ITGlueDocumentImageProperty $imageAttributes $_ })
                $references = Get-ITGlueDocumentImageReferences ($sources + @([string](Get-ITGlueDocumentImageProperty $imageAttributes 'name')))
                $sequence.Add([pscustomobject]@{Id=$id; Sources=$sources; Names=$references.Names; Metadata=$image})
            }
        }
        $Context.Documents[$DocumentId] = $sequence.ToArray()
    }
    return $Context.Documents[$DocumentId]
}

function Save-ITGlueDocumentImageRecovery {
    param($Article, $Record, [hashtable]$Context)
    $records = @(Get-ITGlueDocumentImageProperty $Article 'ImageRecoveries' | Where-Object { $_.RecoveryKey -ne $Record.RecoveryKey }) + @($Record)
    $Article | Add-Member -NotePropertyName ImageRecoveries -NotePropertyValue $records -Force
    $logDirectory = Join-Path $Context.LogsPath 'DocumentImageRecovery'
    $null = [IO.Directory]::CreateDirectory($logDirectory)
    $records | ConvertTo-Json -Depth 20 -AsArray | Set-Content -LiteralPath (Join-Path $logDirectory "$($Record.ITGDocumentId).json") -Encoding utf8
}

function Resolve-ITGlueDocumentImage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Article,
        [string[]]$SourceValues,
        [int]$ImageIndex = -1,
        [string[]]$ExportImageTags = @(),
        [Parameter(Mandatory)][hashtable]$Context
    )
    $result = [pscustomobject]@{File=$null; Record=$null; Reason=$null}
    $documentId = [string](Get-ITGlueDocumentImageProperty $Article 'ITGID')
    if ($documentId -notmatch '^\d+$') { $result.Reason = 'No numeric IT Glue document ID'; return $result }
    if (-not $Context.ApiKey -or -not $Context.ApiBase -or $Context.ApiUnavailable) { $result.Reason = 'IT Glue document-image API is unavailable or not configured'; return $result }
    $record = $null
    $temporaryPath = $null
    try {
        $references = Get-ITGlueDocumentImageReferences $SourceValues
        $referenceSource = 'CurrentHtml'
        if ($references.Ids.Count -eq 0) {
            $originalImage = Get-ITGlueArticleOriginalImage -Article $Article -ImageIndex $ImageIndex -ExportImageTags $ExportImageTags -References $references -Context $Context
            if ($originalImage) {
                $SourceValues = @($SourceValues) + @($originalImage.Html)
                $references = Get-ITGlueDocumentImageReferences $SourceValues
                $referenceSource = $originalImage.Source
            }
        }
        if (@($references.DocumentIds | Where-Object { $_ -ne $documentId }).Count -gt 0) { throw 'Image reference belongs to another IT Glue document' }
        $id = $null; $metadata = $null; $method = 'ImageId'
        if ($references.Ids.Count -eq 1) {
            $id = $references.Ids[0]
        } elseif ($references.Ids.Count -gt 1) {
            throw 'Image references contain conflicting image IDs'
        } else {
            $sequence = @(Get-ITGlueDocumentImageSequence $Context $documentId)
            $named = @($sequence | Where-Object { @($_.Names | Where-Object { $_ -in $references.Names }).Count -gt 0 } | Group-Object Id)
            if ($named.Count -eq 1 -and $named[0].Name -match '^\d+$') {
                $item = $named[0].Group[0]; $method = 'DocumentImageFilename'
            } else {
                if ($ImageIndex -lt 0 -or $ImageIndex -ge $sequence.Count -or $ExportImageTags.Count -ne $sequence.Count) { throw 'Cannot align exported images with IT Glue document sections' }
                for ($index = 0; $index -lt $sequence.Count; $index++) {
                    $exportReferences = Get-ITGlueDocumentImageReferences @($ExportImageTags[$index])
                    if ($exportReferences.Ids.Count -gt 0) {
                        if ($sequence[$index].Id -notin $exportReferences.Ids) { throw 'Export and API image order disagree' }
                    } elseif ($exportReferences.Names.Count -gt 0 -and @($sequence[$index].Names | Where-Object { $_ -in $exportReferences.Names }).Count -eq 0) {
                        throw 'Export and API image filenames disagree'
                    }
                }
                $item = $sequence[$ImageIndex]; $method = 'DocumentImageOrder'
            }
            $id = $item.Id; $metadata = $item.Metadata
        }
        if ($id -notmatch '^\d+$') { throw 'No unambiguous IT Glue document image could be identified' }
        if (-not $Context.Images.ContainsKey($id)) {
            $Context.Images[$id] = $null
            # Read the image endpoint for fresh original URLs. Section metadata is
            # a fallback for gallery images already returned with the document.
            try { $Context.Images[$id] = Invoke-ITGlueDocumentImageMetadataRequest $Context "document_images/$id" }
            catch { if ($metadata) { $Context.Images[$id] = $metadata } else { throw } }
        }
        $metadata = $Context.Images[$id]
        if ([string](Get-ITGlueDocumentImageProperty $metadata 'id') -ne $id) { throw 'IT Glue returned no matching document image' }
        $attributes = Get-ITGlueDocumentImageProperty $metadata 'attributes'
        $owner = [string](Get-ITGlueDocumentImageProperty $attributes 'document-id')
        if ($owner -and $owner -ne $documentId) { throw 'API image belongs to another IT Glue document' }
        if (-not $owner) {
            $members = @(Get-ITGlueDocumentImageSequence $Context $documentId | Where-Object Id -eq $id)
            if ($members.Count -eq 0) { throw 'Cannot verify gallery image membership in this document' }
        }
        $record = [pscustomobject]@{
            RecoveryKey="${documentId}:${ImageIndex}:$id"; ITGDocumentId=$documentId; ITGImageId=$id
            DownloadedViaApi=$false; RecoverySource='ITGlueDocumentImagesApi'; MatchMethod=$method
            ReferenceSource=$referenceSource
            OriginalSources=@($SourceValues | ForEach-Object { [regex]::Replace($_, '(?i)(https?://[^?\s"''<>]+)\?[^"''\s<>]+', '$1') })
            FilePath=$null; DownloadVariant=$null; DownloadUrl=$null
            DownloadedAt=$null; UsedCachedDownload=$false; HuduImageUrl=$null; Status='Pending'; Problem=$null
        }
        $directory = Join-Path $Context.CachePath $documentId
        $null = [IO.Directory]::CreateDirectory($directory)
        $cached = @(Get-ChildItem -LiteralPath $directory -File | Where-Object { $_.BaseName -eq $id -and $_.Extension -ne '.tmp' })
        $file = $cached | Where-Object { Invoke-ImageTest -FilePath $_.FullName } | Select-Object -First 1
        if ($file) { $record.UsedCachedDownload = $true }
        else {
            $downloadProblem = 'No usable image download URL was returned'
            foreach ($variant in @('original-src', 'slim-src', 'thumbnail-src')) {
                $url = [string](Get-ITGlueDocumentImageProperty $attributes $variant)
                $uri = $null
                if (-not [Uri]::TryCreate($url, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne 'https') { continue }
                $temporaryPath = Join-Path $directory "$id-$([guid]::NewGuid().ToString('N')).tmp"
                try {
                    # Download storage URLs without forwarding the IT Glue API key.
                    $null = Invoke-ITGlueCommandWithRetry -MaxRetries 2 -OperationName "Download IT Glue document image $id" -Operation {
                        Invoke-WebRequest -Method Get -Uri $url -OutFile $temporaryPath -TimeoutSec 60 -ErrorAction Stop
                    }
                    if (-not (Invoke-ImageTest -FilePath $temporaryPath)) { throw 'Downloaded content is not an image' }
                    $extension = Get-ImageTypeFromSignature $temporaryPath
                    if (-not $extension) { $extension = [IO.Path]::GetExtension([string](Get-ITGlueDocumentImageProperty $attributes 'name')).TrimStart('.') }
                    if ($extension -notmatch '^(png|jpe?g|gif|bmp|tiff?|webp|svg|ico|heic|avif)$') { throw 'Downloaded image format is not supported' }
                    $destination = Join-Path $directory "$id.$extension"
                    [IO.File]::Move($temporaryPath, $destination, $true)
                    $temporaryPath = $null
                    $file = Get-Item -LiteralPath $destination
                    $record.DownloadVariant = $variant
                    # Signed query strings are deliberately omitted from logs.
                    $record.DownloadUrl = $uri.GetLeftPart([UriPartial]::Path)
                    break
                } catch { $downloadProblem = "Unable to download a valid $variant image" }
                finally { if ($temporaryPath -and [IO.File]::Exists($temporaryPath)) { [IO.File]::Delete($temporaryPath) }; $temporaryPath = $null }
            }
            if (-not $file) { throw $downloadProblem }
        }
        $record.DownloadedViaApi = $true
        $record.FilePath = $file.FullName
        $record.DownloadedAt = $file.LastWriteTimeUtc.ToString('o')
        $record.Status = 'Downloaded'
        Save-ITGlueDocumentImageRecovery $Article $record $Context
        $result.File = $file; $result.Record = $record
    } catch {
        $result.Reason = $_.Exception.Message
        if ($record) {
            $record.Status = 'Failed'; $record.Problem = $result.Reason
            Save-ITGlueDocumentImageRecovery $Article $record $Context
            $result.Record = $record
        }
        Write-Verbose "Document $documentId image recovery: $($result.Reason)"
    }
    return $result
}
