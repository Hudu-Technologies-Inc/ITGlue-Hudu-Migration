# Loaded only by the optional standalone repair script.
. "$PSScriptRoot/Resolve-ITGlueDocumentImage.ps1"
. "$PSScriptRoot/ArticleContentLocalCache.ps1"

function New-ITGlueLegacyScreenshotRecoveryContext {
    param([string]$ApiBase, [string]$ApiKey, [string]$MigrationLogsPath, [string]$TenantBase,
        [string]$JWTAuthToken, [string]$JWTBaseUri,
        [Microsoft.PowerShell.Commands.WebRequestSession]$WebSession)
    $context = New-ITGlueDocumentImageRecoveryContext -ApiBase $ApiBase -ApiKey $ApiKey -MigrationLogsPath $MigrationLogsPath -LegacyScreenshotUrlResolver {
        param($RecoveryContext, $DocumentId, $StepId)
        Get-ITGlueLegacyScreenshotUrls $RecoveryContext $DocumentId $StepId
    }
    $context.TenantBase = $TenantBase
    $context.JWTAuthToken = ($JWTAuthToken -replace '^\s*Bearer\s+', '').Trim()
    $context.JWTBaseUri = if ($JWTBaseUri) { $JWTBaseUri.TrimEnd('/') } else { $context.ApiBase }
    $context.WebSession = $WebSession
    $context.JWTImages = @{}; $context.JWTEditorImages = @{}; $context.JWTEditorProblems = @{}
    $context.WebImages = @{}; $context.JWTUnavailable = $false
    return $context
}

function Get-ITGlueLegacySignedUrls {
    param($Value)
    if ($null -eq $Value) { return }
    if ($Value -is [string]) {
        if ($Value.TrimStart() -match '^[\[{]') {
            try {
                $decoded = ConvertFrom-Json -InputObject $Value -ErrorAction Stop
                if ($decoded -isnot [string]) { Get-ITGlueLegacySignedUrls $decoded; return }
            } catch { }
        }
        $text = $Value.Replace('\/', '/').Replace('\u0026', '&')
        foreach ($match in [regex]::Matches($text, '(?i)https?://[^\s"''<>]+')) {
            $url = [Net.WebUtility]::HtmlDecode($match.Value)
            $uri = $null
            if ([Uri]::TryCreate($url, [UriKind]::Absolute, [ref]$uri) -and $uri.Scheme -eq 'https' -and
                $uri.AbsolutePath -match '/document/steps/screenshots/') { $url }
        }
    } elseif ($Value -is [Collections.IDictionary]) {
        foreach ($entry in $Value.Values) { Get-ITGlueLegacySignedUrls $entry }
    } elseif ($Value -is [Collections.IEnumerable]) {
        foreach ($entry in $Value) { Get-ITGlueLegacySignedUrls $entry }
    } else {
        foreach ($property in $Value.PSObject.Properties) {
            if ($property.Value -is [string] -or $property.Value -is [pscustomobject] -or
                $property.Value -is [Collections.IDictionary] -or $property.Value -is [array]) {
                Get-ITGlueLegacySignedUrls $property.Value
            }
        }
    }
}

function Get-ITGlueLegacyDocumentEditorUri {
    param([hashtable]$Context, [string]$DocumentId)
    $documentUri = $null; $tenantUri = $null
    if ($DocumentId -notmatch '^\d+$' -or
        -not [Uri]::TryCreate([string]$Context.DocumentUrls[$DocumentId], [UriKind]::Absolute, [ref]$documentUri) -or
        -not [Uri]::TryCreate($Context.TenantBase, [UriKind]::Absolute, [ref]$tenantUri) -or
        $tenantUri.Scheme -ne 'https' -or $tenantUri.UserInfo -or $tenantUri.Query -or $tenantUri.Fragment -or
        $documentUri.Scheme -ne 'https' -or $documentUri.Authority -ine $tenantUri.Authority -or $documentUri.UserInfo) {
        throw 'Cannot verify the tenant document URL for JWT screenshot recovery'
    }
    $path = $documentUri.AbsolutePath
    if ($path -match "^/(?<organization>\d+)/docs/$([regex]::Escape($DocumentId))/?$" -or
        $path -match "^/DOC-(?<organization>\d+)-$([regex]::Escape($DocumentId))/?$") {
        # Read the published version that the migration represents. The public
        # API's legacy content contains filenames but omits these signed URLs.
        return "$($tenantUri.GetLeftPart([UriPartial]::Authority))/$($Matches.organization)/docs/$DocumentId/versions/published"
    }
    throw 'Cannot identify the organization in the verified ITGlue document URL'
}

function Get-ITGlueLegacyScreenshotUrls {
    param([hashtable]$Context, [string]$DocumentId, [string]$StepId)
    $urls = @(); $source = 'JWTApi'; $jwtProblem = ''
    if ($Context.JWTAuthToken -and -not $Context.JWTUnavailable) {
        if (-not $Context.JWTImages.ContainsKey($DocumentId)) {
            $Context.JWTImages[$DocumentId] = @()
            $jwtUri = $null; $apiUri = $null
            if (-not [Uri]::TryCreate($Context.JWTBaseUri, [UriKind]::Absolute, [ref]$jwtUri) -or $jwtUri.Scheme -ne 'https' -or
                -not [Uri]::TryCreate($Context.ApiBase, [UriKind]::Absolute, [ref]$apiUri) -or
                $jwtUri.UserInfo -or $jwtUri.Query -or $jwtUri.Fragment -or
                ($jwtUri.Host -ine $apiUri.Host -and $jwtUri.Host -notmatch '^(?:api(?:\.(?:eu|au))?|itg-api-[a-z0-9-]+)\.itglue\.com$')) {
                throw 'JWT endpoint must be the configured API host or an HTTPS ITGlue API host'
            }
            $headers = @{Authorization="Bearer $($Context.JWTAuthToken)"}
            try {
                # Same bearer authentication as the checklist helpers. A JWT is
                # not a browser cookie and is never forwarded to S3 downloads.
                $response = Invoke-ITGlueCommandWithRetry -MaxRetries 2 -OperationName "Read IT Glue JWT document $DocumentId" -Operation {
                    Invoke-RestMethod -Method Get -Uri "$($Context.JWTBaseUri)/documents/$DocumentId" -Headers $headers -MaximumRedirection 0 -TimeoutSec 60 -ErrorAction Stop
                }
                $data = Get-ITGlueDocumentImageProperty $response 'data'
                if ([string](Get-ITGlueDocumentImageProperty $data 'id') -ne $DocumentId) { throw 'JWT response did not identify the requested document' }
                $Context.JWTImages[$DocumentId] = @(Get-ITGlueLegacySignedUrls $data | Select-Object -Unique)
            } catch {
                $status = Get-ITGlueApiExceptionStatusCode $_
                if ($status -eq 401) { $Context.JWTUnavailable = $true }
                $jwtProblem = "JWT document lookup failed (HTTP $status); the token may be expired or lack access"
            } finally { $headers.Clear() }
        }
        $urls = @($Context.JWTImages[$DocumentId] | Where-Object { $StepId -in (Get-ITGlueDocumentImageReferences @($_)).StepIds })
        if ($urls.Count -eq 0 -and -not $Context.JWTUnavailable) {
            $source = 'JWTDocumentEditor'
            if (-not $Context.JWTEditorImages.ContainsKey($DocumentId)) {
                $Context.JWTEditorImages[$DocumentId] = @()
                $headers = @{Authorization="Bearer $($Context.JWTAuthToken)"; Accept='application/json'}
                try {
                    $editorUrl = Get-ITGlueLegacyDocumentEditorUri $Context $DocumentId
                    $response = Invoke-ITGlueCommandWithRetry -MaxRetries 2 -OperationName "Read IT Glue published document $DocumentId" -Operation {
                        Invoke-RestMethod -Method Get -Uri $editorUrl -Headers $headers -MaximumRedirection 0 -TimeoutSec 60 -ErrorAction Stop
                    }
                    if ([string](Get-ITGlueDocumentImageProperty $response 'id') -ne $DocumentId -or
                        (Get-ITGlueDocumentImageProperty $response 'version') -ne 'published') {
                        throw 'Document editor response did not identify the requested published document'
                    }
                    $Context.JWTEditorImages[$DocumentId] = @(Get-ITGlueLegacySignedUrls (Get-ITGlueDocumentImageProperty $response 'sections') | Select-Object -Unique)
                } catch {
                    $status = Get-ITGlueApiExceptionStatusCode $_
                    if ($status -eq 401) { $Context.JWTUnavailable = $true }
                    $Context.JWTEditorProblems[$DocumentId] = if ($status) { "JWT published-document lookup failed (HTTP $status)" } else { 'Cannot verify the tenant URL or the published-document response for JWT screenshot recovery' }
                } finally { $headers.Clear() }
            }
            $urls = @($Context.JWTEditorImages[$DocumentId] | Where-Object { $StepId -in (Get-ITGlueDocumentImageReferences @($_)).StepIds })
            if ($urls.Count -gt 0) { $jwtProblem = '' }
            elseif ($Context.JWTEditorProblems.ContainsKey($DocumentId)) { $jwtProblem = $Context.JWTEditorProblems[$DocumentId] }
        }
        if ($urls.Count -eq 0 -and -not $jwtProblem) { $jwtProblem = 'The JWT document response did not expose a signed URL for this legacy screenshot' }
    }
    if ($urls.Count -eq 0 -and $Context.WebSession) {
        $source = 'AuthenticatedWebDocument'
        if (-not $Context.WebImages.ContainsKey($DocumentId)) {
            $Context.WebImages[$DocumentId] = @()
            $documentUri = $null; $tenantUri = $null
            $url = [string]$Context.DocumentUrls[$DocumentId]
            if (-not [Uri]::TryCreate($url, [UriKind]::Absolute, [ref]$documentUri) -or
                -not [Uri]::TryCreate($Context.TenantBase, [UriKind]::Absolute, [ref]$tenantUri) -or
                $documentUri.Scheme -ne 'https' -or $documentUri.Host -ine $tenantUri.Host -or
                $documentUri.AbsolutePath -notmatch "/(?:\d+/docs/$([regex]::Escape($DocumentId))|DOC-\d+-$([regex]::Escape($DocumentId)))(?:/|$)") {
                throw 'Cannot verify the tenant document URL for authenticated screenshot recovery'
            }
            $page = Invoke-ITGlueCommandWithRetry -MaxRetries 2 -OperationName "Read IT Glue web document $DocumentId" -Operation {
                Invoke-WebRequest -Method Get -Uri $url -WebSession $Context.WebSession -TimeoutSec 60 -ErrorAction Stop
            }
            $Context.WebImages[$DocumentId] = @(Get-ITGlueLegacySignedUrls ([string]$page.Content) | Select-Object -Unique)
        }
        $urls = @($Context.WebImages[$DocumentId] | Where-Object { $StepId -in (Get-ITGlueDocumentImageReferences @($_)).StepIds })
    }
    if ($urls.Count -eq 0) {
        if ($jwtProblem) { throw $jwtProblem }
        if ($Context.JWTUnavailable) { throw 'The ITGlue JWT was rejected; supply a fresh token' }
        if ($Context.WebSession) { throw 'The authenticated page returned no screenshot URL; the web session may be expired' }
        throw 'No signed screenshot URL is available; supply an ITGlue JWT or an authenticated web session'
    }
    foreach ($variant in @('original', 'slim', 'thumbnail')) {
        foreach ($url in $urls) {
            if (([Uri]$url).AbsolutePath -match "/$variant/") { [pscustomobject]@{Variant=$variant; Url=$url; Source=$source} }
        }
    }
}

function Set-ITGlueLegacyScreenshotTagUrl {
    param([string]$Content, [int]$ImageIndex, [string]$Url)
    $tags = @([regex]::Matches($Content, '(?is)<img\b(?:[^>"'']|"[^"]*"|''[^'']*'')*>'))
    if ($ImageIndex -lt 0 -or $ImageIndex -ge $tags.Count) { throw 'The target image no longer exists in the current article' }
    $tag = $tags[$ImageIndex]
    $encodedUrl = [Net.WebUtility]::HtmlEncode($Url)
    $updated = [regex]::Replace($tag.Value, '(?i)(?<prefix>(?<![\w-])(?:src|data-src-original|data-original)\s*=\s*)(?:"[^"]*"|''[^'']*''|[^\s>]+)', {
        param($match) $match.Groups['prefix'].Value + '"' + $encodedUrl + '"'
    })
    if ($updated -notmatch '(?i)(?<![\w-])src\s*=') { $updated = [regex]::Replace($updated, '(?i)^<img\b', ('<img src="' + $encodedUrl + '"')) }
    return $Content.Substring(0, $tag.Index) + $updated + $Content.Substring($tag.Index + $tag.Length)
}

function Get-ITGlueLegacyHtmlLayout {
    param([string]$Content)
    $keys = [Collections.Generic.List[string]]::new()
    $offsets = [Collections.Generic.List[int]]::new()
    $images = [Collections.Generic.List[object]]::new()
    $endOffset = $Content.Length
    $pattern = '(?is)<!--.*?-->|<(?:head|script|style)\b[^>]*>.*?</(?:head|script|style)\s*>|<(?:[^>"'']|"[^"]*"|''[^'']*'')*>|[^<]+|<'
    foreach ($token in [regex]::Matches($Content, $pattern)) {
        $value = $token.Value
        if ($value.StartsWith('<')) {
            if ($value -match '(?is)^<(?:head|script|style)\b' -or $value.StartsWith('<!')) { continue }
            if ($value -notmatch '^<(?<closing>/?)\s*(?<name>[a-zA-Z0-9:-]+)') { continue }
            $name = $Matches.name.ToLowerInvariant(); $closing = $Matches.closing
            if ($name -eq 'img') {
                $images.Add([pscustomobject]@{Index=$images.Count; Boundary=$keys.Count; Offset=$token.Index; Length=$token.Length; Html=$value; References=(Get-ITGlueDocumentImageReferences @($value))})
                continue
            }
            if ($name -in @('html', 'body', 'meta', 'link')) {
                if ($closing -and $name -in @('html', 'body')) { $endOffset = [Math]::Min($endOffset, $token.Index) }
                continue
            }
            $keys.Add("tag:$closing$name"); $offsets.Add($token.Index)
        } else {
            $text = ([regex]::Replace([Net.WebUtility]::HtmlDecode($value), '\s+', ' ')).Trim()
            if ($text) { $keys.Add("text:$text"); $offsets.Add($token.Index) }
        }
    }
    return [pscustomobject]@{Content=$Content; Keys=$keys.ToArray(); Offsets=$offsets.ToArray(); Images=$images.ToArray(); EndOffset=$endOffset}
}

function Test-ITGlueLegacyImageReference {
    param($Source, $Reference)
    if ($Source.Ids.Count -gt 0) { return @($Source.Ids | Where-Object { $_ -in $Reference.Ids }).Count -gt 0 }
    if ($Source.StepIds.Count -gt 0) { return @($Source.StepIds | Where-Object { $_ -in $Reference.StepIds }).Count -gt 0 }
    if ($Source.Names.Count -gt 0) { return @($Source.Names | Where-Object { $_ -in $Reference.Names }).Count -gt 0 }
    return $true
}

function New-ITGlueLegacyPlacementPlan {
    param($Article, [object[]]$Sequence, [hashtable]$Context)
    $sourceImages = @(Get-ITGlueDocumentImageProperty $Article 'SourceImages')
    $snapshotPath = Join-Path $Context.LogsPath "LegacyScreenshotSources/$($Article.ITGID).html"
    $paths = @($snapshotPath, (Get-ITGlueDocumentImageProperty $Article 'FullPath'),
        (Get-ITGlueDocumentImageProperty $Article 'LocalContentPath'),
        (Join-Path (Split-Path $Context.LogsPath -Parent) "ArticleContent/$($Article.HuduID).html"))
    $layout = $null
    foreach ($path in $paths) {
        if (-not $path -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        $candidate = Get-ITGlueLegacyHtmlLayout (Get-Content -LiteralPath $path -Raw -Encoding utf8)
        if ($candidate.Images.Count -eq 0 -or ($sourceImages.Count -gt 0 -and $candidate.Images.Count -ne $sourceImages.Count)) { continue }
        $layout = $candidate
        if ($sourceImages.Count -eq 0) { $sourceImages = @(Get-ITGlueArticleSourceImages $candidate.Content) }
        break
    }
    $indices = @{}; $nameCounts = @{}
    foreach ($item in $Sequence) {
        foreach ($name in $item.Names) { $nameCounts[$name] = 1 + [int]$nameCounts[$name] }
    }
    $ordered = $Sequence.Count -eq $sourceImages.Count -and $Sequence.Count -gt 0
    for ($index=0; $ordered -and $index -lt $Sequence.Count; $index++) {
        $source = Get-ITGlueDocumentImageReferences @([string]$sourceImages[$index].Html)
        $item = $Sequence[$index]
        $legacy = (Get-ITGlueDocumentImageProperty $item.Metadata 'type') -eq 'legacy-step-screenshots'
        $reference = [pscustomobject]@{Ids=@(if (-not $legacy) { $item.Id }); StepIds=@(if ($legacy) { $item.Id }); Names=$item.Names}
        $ordered = Test-ITGlueLegacyImageReference $source $reference
        # For repeated filenames, check the step's text against the corresponding
        # source section as well, when both are available.
        $sectionContent = [string](Get-ITGlueDocumentImageProperty (Get-ITGlueDocumentImageProperty $item.Metadata 'attributes') 'section-content')
        if ($ordered -and $layout -and $sectionContent -and @($item.Names | Where-Object { $nameCounts[$_] -gt 1 }).Count -gt 0) {
            $stepText = ((Get-ITGlueLegacyHtmlLayout $sectionContent).Keys | Where-Object { $_.StartsWith('text:') } | ForEach-Object { $_.Substring(5) }) -join ' '
            $start = if ($index -gt 0) { $layout.Images[$index-1].Boundary } else { 0 }
            $stop = $layout.Images[$index].Boundary
            $preceding = if ($stop -gt $start) { ($layout.Keys[$start..($stop-1)] | Where-Object { $_.StartsWith('text:') } | ForEach-Object { $_.Substring(5) }) -join ' ' } else { '' }
            if ($stepText -and -not $preceding.Contains($stepText)) { $ordered = $false }
        }
    }
    for ($index=0; $index -lt $Sequence.Count; $index++) {
        $item = $Sequence[$index]
        if ((Get-ITGlueDocumentImageProperty $item.Metadata 'type') -ne 'legacy-step-screenshots') { continue }
        if ($ordered) { $indices[$item.Id] = $index; continue }
        $matching = @($sourceImages | Where-Object { @($_.FileNames | Where-Object { $_ -in $item.Names }).Count -gt 0 })
        if ($matching.Count -eq 1 -and @($item.Names | Where-Object { $nameCounts[$_] -gt 1 }).Count -eq 0) { $indices[$item.Id] = [int]$matching[0].Index }
    }
    return [pscustomobject]@{SourceImages=$sourceImages; Layout=$layout; SnapshotPath=$snapshotPath; StepIndices=$indices; NameCounts=$nameCounts; Ordered=$ordered}
}

function Get-ITGlueLegacyScreenshotTarget {
    param([string]$Content, $Step, $Plan, $Article)
    $live = Get-ITGlueLegacyHtmlLayout $Content
    $name = [string](Get-ITGlueDocumentImageProperty (Get-ITGlueDocumentImageProperty $Step.Metadata 'attributes') 'name')
    $sourceIndex = if ($Plan.StepIndices.ContainsKey($Step.Id)) { [int]$Plan.StepIndices[$Step.Id] } else { -1 }
    $direct = @($live.Images | Where-Object { $Step.Id -in $_.References.StepIds })
    if ($direct.Count -eq 1) { return [pscustomobject]@{Kind='Existing'; Index=$direct[0].Index; SourceIndex=$sourceIndex; Method='StepId'; Html=$null; Offset=0} }
    $matching = @($live.Images | Where-Object { $name.ToLowerInvariant() -in $_.References.Names })
    if ($matching.Count -eq 1 -and $Plan.NameCounts[$name] -eq 1) { return [pscustomobject]@{Kind='Existing'; Index=$matching[0].Index; SourceIndex=$sourceIndex; Method='UniqueFilename'; Html=$null; Offset=0} }
    if ($sourceIndex -lt 0) {
        if ($Plan.SourceImages.Count -eq 0) { throw 'Original source image references are unavailable; cannot restore missing screenshot positions' }
        throw "Cannot map legacy step $($Step.Id) to the preserved source images; filenames or section order disagree"
    }
    $sameStructure = $null -ne $Plan.Layout -and $Plan.Layout.Keys.Count -eq $live.Keys.Count
    for ($index=0; $sameStructure -and $index -lt $live.Keys.Count; $index++) { if ($Plan.Layout.Keys[$index] -cne $live.Keys[$index]) { $sameStructure=$false } }
    if ($sameStructure) {
        $sourceImage = $Plan.Layout.Images[$sourceIndex]
        $sameSlots = $live.Images.Count -eq $Plan.Layout.Images.Count
        for ($index=0; $sameSlots -and $index -lt $live.Images.Count; $index++) {
            if ($live.Images[$index].Boundary -ne $Plan.Layout.Images[$index].Boundary) { $sameSlots=$false }
        }
        if ($sameSlots -and (Test-ITGlueLegacyImageReference $live.Images[$sourceIndex].References (Get-ITGlueDocumentImageReferences @($Plan.SourceImages[$sourceIndex].Html)))) {
            return [pscustomobject]@{Kind='Existing'; Index=$sourceIndex; SourceIndex=$sourceIndex; Method='SourceStructure'; Html=$null; Offset=0}
        }
        $boundary = $sourceImage.Boundary
        $atBoundary = @($live.Images | Where-Object Boundary -eq $boundary)
        $sourceSlots = @($Plan.Layout.Images | Where-Object Boundary -eq $boundary)
        if ($sourceSlots.Count -eq 1 -and $atBoundary.Count -eq 1 -and (Test-ITGlueLegacyImageReference $atBoundary[0].References (Get-ITGlueDocumentImageReferences @($sourceImage.Html)))) {
            return [pscustomobject]@{Kind='Existing'; Index=$atBoundary[0].Index; SourceIndex=$sourceIndex; Method='SourceStructure'; Html=$null; Offset=0}
        }
        $offset = if ($boundary -lt $live.Offsets.Count) { $live.Offsets[$boundary] } else { $live.EndOffset }
        foreach ($existing in $atBoundary) {
            $knownIndex = -1
            foreach ($record in @(Get-ITGlueDocumentImageProperty $Article 'ImageRecoveries')) {
                $url = [string](Get-ITGlueDocumentImageProperty $record 'HuduImageUrl')
                $stepId = [string](Get-ITGlueDocumentImageProperty $record 'ITGStepId')
                if ($url -and $existing.Html.Contains([Net.WebUtility]::HtmlEncode($url)) -and $Plan.StepIndices.ContainsKey($stepId)) { $knownIndex=$Plan.StepIndices[$stepId]; break }
            }
            if ($knownIndex -lt 0) { throw 'An existing image at the original screenshot position cannot be identified safely' }
            if ($knownIndex -eq $sourceIndex) { return [pscustomobject]@{Kind='Existing'; Index=$existing.Index; SourceIndex=$sourceIndex; Method='RecoveryLog'; Html=$null; Offset=0} }
            if ($knownIndex -gt $sourceIndex) { $offset=[Math]::Min($offset, $existing.Offset) }
        }
        return [pscustomobject]@{Kind='Insert'; Index=-1; SourceIndex=$sourceIndex; Method='RestoredSourceStructure'; Html=$sourceImage.Html; Offset=$offset}
    }
    if ($live.Images.Count -eq $Plan.SourceImages.Count -and $sourceIndex -lt $live.Images.Count) {
        $candidate=$live.Images[$sourceIndex]
        $compatible=$true
        for ($index=0; $index -lt $live.Images.Count; $index++) {
            if ($live.Images[$index].References.Names.Count -gt 0 -and -not (Test-ITGlueLegacyImageReference $live.Images[$index].References (Get-ITGlueDocumentImageReferences @($Plan.SourceImages[$index].Html)))) {
                $known = @(Get-ITGlueDocumentImageProperty $Article 'ImageRecoveries' | Where-Object {
                    $url=[string](Get-ITGlueDocumentImageProperty $_ 'HuduImageUrl'); $url -and $live.Images[$index].Html.Contains([Net.WebUtility]::HtmlEncode($url))
                })
                if ($known.Count -eq 0 -and $live.Images[$index].Html -notmatch '(?i)src\s*=\s*["'']/images/') { $compatible=$false; break }
            }
        }
        if ($compatible -and (Test-ITGlueLegacyImageReference $candidate.References (Get-ITGlueDocumentImageReferences @($Plan.SourceImages[$sourceIndex].Html)))) {
            return [pscustomobject]@{Kind='Existing'; Index=$candidate.Index; SourceIndex=$sourceIndex; Method='PreservedImageOrder'; Html=$null; Offset=0}
        }
    }
    if (-not $Plan.Layout) { throw 'Original HTML layout is unavailable; cannot restore image tags removed from Hudu' }
    throw 'Current article text or structure differs from the saved source; cannot restore a removed image safely'
}

function Invoke-ITGlueLegacyScreenshotRepair {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][object[]]$Articles, [Parameter(Mandatory)][hashtable]$Context,
        [string[]]$DocumentId = @(), [switch]$DownloadOnly)
    foreach ($article in $Articles) {
        $id = [string](Get-ITGlueDocumentImageProperty $article 'ITGID')
        if ($DocumentId.Count -gt 0 -and $id -notin $DocumentId) { continue }
        if ($id -notmatch '^\d+$') {
            [pscustomobject]@{DocumentId=$id; StepId=$null; Filename=$null; Status='Failed'; Problem='No numeric ITGlue document ID'}
            continue
        }
        $pending = [Collections.Generic.List[object]]::new()
        try {
            $sequence = @(Get-ITGlueDocumentImageSequence $Context $id)
            $steps = @($sequence | Where-Object { (Get-ITGlueDocumentImageProperty $_.Metadata 'type') -eq 'legacy-step-screenshots' })
            if ($steps.Count -eq 0) { continue }
            $plan = New-ITGlueLegacyPlacementPlan -Article $article -Sequence $sequence -Context $Context
            $content = ''; $startingContent = ''; $live = $null; $updateAllowed = $false
            if (-not $DownloadOnly) {
                $response = Get-HuduArticles -Id $article.HuduID -ErrorAction Stop
                $live = (Get-ITGlueDocumentImageProperty $response 'article') ?? $response
                if ([string](Get-ITGlueDocumentImageProperty $live 'id') -ne [string]$article.HuduID) { throw 'Hudu returned no matching article' }
                $content = [string](Get-ITGlueDocumentImageProperty $live 'content')
                $startingContent = $content
                $updateAllowed = $PSCmdlet.ShouldProcess("Hudu article $($article.HuduID)", 'Repair missing legacy step screenshots')
            }
            foreach ($step in $steps) {
                $record = $null
                try {
                    $filename = [string](Get-ITGlueDocumentImageProperty (Get-ITGlueDocumentImageProperty $step.Metadata 'attributes') 'name')
                    $previous = @(Get-ITGlueDocumentImageProperty $article 'ImageRecoveries' | Where-Object { [string](Get-ITGlueDocumentImageProperty $_ 'ITGStepId') -eq $step.Id -and (Get-ITGlueDocumentImageProperty $_ 'HuduImageUrl') }) | Select-Object -Last 1
                    $alreadyPlaced = $false
                    if ($previous) {
                        $escapedUrl = [regex]::Escape([string]$previous.HuduImageUrl)
                        $placedPattern = '(?i)(?<![\w-])src\s*=\s*(?:"' + $escapedUrl + '"|''' + $escapedUrl + '''|' + $escapedUrl + '(?=[\s>]))'
                        $alreadyPlaced = @(Get-ITGlueArticleSourceImages $content | Where-Object { [Net.WebUtility]::HtmlDecode($_.Html) -match $placedPattern }).Count -gt 0
                    }
                    if ($alreadyPlaced) {
                        [pscustomobject]@{DocumentId=$id; StepId=$step.Id; Filename=$filename; Status='AlreadyPlaced'; Problem=$null}
                        continue
                    }
                    $targetIndex = if ($plan.StepIndices.ContainsKey($step.Id)) { [int]$plan.StepIndices[$step.Id] } else { -1 }
                    $target = $null
                    if (-not $DownloadOnly) {
                        $target = Get-ITGlueLegacyScreenshotTarget -Content $content -Step $step -Plan $plan -Article $article
                        $targetIndex = if ($target.SourceIndex -ge 0) { $target.SourceIndex } else { $target.Index }
                        if ($plan.Layout -and -not (Test-Path -LiteralPath $plan.SnapshotPath)) {
                            $null = [IO.Directory]::CreateDirectory((Split-Path $plan.SnapshotPath -Parent))
                            Set-Content -LiteralPath $plan.SnapshotPath -Value $plan.Layout.Content -Encoding utf8 -NoNewline
                        }
                    }
                    $resolved = Resolve-ITGlueDocumentImage -Article $article -SourceValues @($filename) -ImageIndex $targetIndex -LegacyStepId $step.Id -Context $Context
                    if (-not $resolved.File) { throw $resolved.Reason }
                    $record = $resolved.Record
                    $record | Add-Member -NotePropertyName ITGFileName -NotePropertyValue $filename -Force
                    if ($plan.StepIndices.ContainsKey($step.Id)) { $record | Add-Member -NotePropertyName OriginalImageIndex -NotePropertyValue ([int]$plan.StepIndices[$step.Id]) -Force }
                    if ($DownloadOnly -or -not $updateAllowed) {
                        if ($previous) {
                            $record.HuduImageUrl = $previous.HuduImageUrl
                            $record.Status = Get-ITGlueDocumentImageProperty $previous 'Status'
                            $record.Problem = Get-ITGlueDocumentImageProperty $previous 'Problem'
                            Save-ITGlueDocumentImageRecovery $article $record $Context
                        }
                        [pscustomobject]@{DocumentId=$id; StepId=$step.Id; Filename=$filename; Status='Downloaded'; Problem=$null}
                        continue
                    }
                    $url = if ($previous) { [string]$previous.HuduImageUrl } else { '' }
                    if (-not $url) {
                        $photo = New-HuduPublicPhoto -FilePath $resolved.File.FullName -record_id $article.HuduID -record_type Article -ErrorAction Stop
                        $photo = (Get-ITGlueDocumentImageProperty $photo 'public_photo') ?? $photo
                        $url = [string](Get-ITGlueDocumentImageProperty $photo 'url')
                        if (-not $url) { throw 'Hudu returned no public photo URL' }
                    }
                    $record | Add-Member -NotePropertyName OriginalImageIndex -NotePropertyValue $target.SourceIndex -Force
                    $record | Add-Member -NotePropertyName PlacementMethod -NotePropertyValue $target.Method -Force
                    $record.HuduImageUrl = $url; $record.Status = 'Uploaded'
                    Save-ITGlueDocumentImageRecovery $article $record $Context
                    if ($target.Kind -eq 'Insert') {
                        $imageHtml = Set-ITGlueLegacyScreenshotTagUrl -Content $target.Html -ImageIndex 0 -Url $url
                        $content = $content.Insert($target.Offset, $imageHtml)
                    } else {
                        $content = Set-ITGlueLegacyScreenshotTagUrl -Content $content -ImageIndex $target.Index -Url $url
                    }
                    $pending.Add($record)
                } catch {
                    if ($record) { $record.Problem = 'Screenshot could not be placed in Hudu'; Save-ITGlueDocumentImageRecovery $article $record $Context }
                    [pscustomobject]@{DocumentId=$id; StepId=$step.Id; Filename=$filename; Status='Failed'; Problem=$_.Exception.Message}
                }
            }
            if ($pending.Count -gt 0) {
                $freshResponse = Get-HuduArticles -Id $article.HuduID -ErrorAction Stop
                $freshArticle = (Get-ITGlueDocumentImageProperty $freshResponse 'article') ?? $freshResponse
                if ([string](Get-ITGlueDocumentImageProperty $freshArticle 'id') -ne [string]$article.HuduID -or
                    [string](Get-ITGlueDocumentImageProperty $freshArticle 'content') -cne $startingContent) { throw 'Article content changed during repair; retry to preserve the newer edits' }
                $response = Set-HuduArticle -Id $article.HuduID -Content $content -ErrorAction Stop
                $updated = (Get-ITGlueDocumentImageProperty $response 'article') ?? $response
                if ([string](Get-ITGlueDocumentImageProperty $updated 'id') -ne [string]$article.HuduID) { throw 'Hudu did not confirm the article update' }
                $article.HuduObject = $updated
                $null = Set-HuduArticleLocalContent -Article $article -Content $content -MigrationLogsPath $Context.LogsPath -DebugFolderPath (Split-Path $Context.LogsPath -Parent)
                $article | Add-Member -NotePropertyName LocalContentCommittedAt -NotePropertyValue ([datetime]::UtcNow.ToString('o')) -Force
                foreach ($record in $pending) {
                    $record.Status = 'Placed'; $record.Problem = $null
                    Save-ITGlueDocumentImageRecovery $article $record $Context
                    [pscustomobject]@{DocumentId=$id; StepId=$record.ITGStepId; Filename=$record.ITGFileName; Status='Placed'; Problem=$null}
                }
            }
        } catch {
            foreach ($record in $pending) { $record.Problem = 'Article update failed; the uploaded photo can be reused on retry'; Save-ITGlueDocumentImageRecovery $article $record $Context }
            [pscustomobject]@{DocumentId=$id; StepId=$null; Filename=$null; Status='Failed'; Problem=$_.Exception.Message}
        }
    }
}
