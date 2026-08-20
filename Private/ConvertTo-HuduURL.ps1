# This will be used to remake the ITGlue Links to Hudu, and relies on the migration logs existing.

$ITGlueURLCandidates = @($ITGURL)

if ($environmentSettings.ITGCustomDomains) {
    $ITGlueURLCandidates += ($environmentSettings.ITGCustomDomains -split ",")
}

$ITGlueURLCandidates = @(
    $ITGlueURLCandidates |
        Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
        ForEach-Object {
            $candidate = ([string]$_).Trim().TrimEnd('/')
            $candidate
            if ($candidate -match '^https://') { $candidate -replace '^https://', 'http://' }
            if ($candidate -match '^http://') { $candidate -replace '^http://', 'https://' }
        } |
        Select-Object -Unique
)

$ConfiguredEscapedITGURL = ($ITGlueURLCandidates | ForEach-Object { [regex]::Escape($_) }) -join "|"
$AnyITGlueTenantURLPattern = 'https?://[^/"''\s<>]+\.itglue\.com'
if ([string]::IsNullOrWhiteSpace($ConfiguredEscapedITGURL)) {
    $EscapedITGURL = "(?:$AnyITGlueTenantURLPattern)"
} else {
    $EscapedITGURL = "(?:$ConfiguredEscapedITGURL|$AnyITGlueTenantURLPattern)"
}

$ITGlueUrlPrefixPattern = "(?:$EscapedITGURL)?"
$ITGlueURLReplacementCandidatePattern = "$EscapedITGURL|/[0-9]{1,20}/(?:docs|passwords|configurations|assets|domains|contacts)(?:/|(?=$|[?#""'']))|/?DOC-[0-9]{0,20}-[0-9]{0,20}"
$ITGlueURLReplacementRegexOptions = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor
    [System.Text.RegularExpressions.RegexOptions]::Singleline -bor
    [System.Text.RegularExpressions.RegexOptions]::CultureInvariant
$ITGlueURLReplacementCandidateRegex = [regex]::new($ITGlueURLReplacementCandidatePattern, $ITGlueURLReplacementRegexOptions)

# We want to grab all assets, passwords, websites, and companies, filter to fields and notes that have ITGlue URLs in them and prime for replacement.
# Named captures are used by Update-StringWithCaptureGroups, while the resolver still supports the older positional captures.
$RichRegexPatternToMatchSansAssets = '<a\b[^>]*?href\s*=\s*["'']?' + $ITGlueUrlPrefixPattern + '/(?<CompanyId>[0-9]{1,20})/(?<EntityType>docs|passwords|configurations|assets|contacts)/(?<EntityId>[0-9]{1,20})(?!(?:/[^"''<>]*)?/(?:images|files|attachments)(?=/|$))[^>]*>.*?</a>'
$RichRegexPatternToMatchWithAssets = '<a\b[^>]*?href\s*=\s*["'']?' + $ITGlueUrlPrefixPattern + '/(?<CompanyId>[0-9]{1,20})/(?<EntityType>assets)/.*?/(?<EntityId>[0-9]{1,20})[^>]*>.*?</a>'
$RichDomainsPatternToMatch = '<a\b[^>]*?href\s*=\s*["'']?' + $ITGlueUrlPrefixPattern + '/(?<CompanyId>[0-9]{1,20})/(?<EntityType>domains)(?:/(?<EntityId>[0-9]{1,20}))?(?:[^"''\s<>]*)?[^>]*>.*?</a>'
$ImgRegexPatternToMatch = $EscapedITGURL + '/(?<ImageRelativePath>(?<CompanyId>[0-9]{1,20})/docs/(?<ArticleId>[0-9]{1,20})/(?<EntityType>images)/(?<ImageId>[0-9]{1,20}).*?)(?=")'
$RichDocLocatorUrlPatternToMatch = '<a\b[^>]*?href\s*=\s*["'']?' + $ITGlueUrlPrefixPattern + '/(?<DocLocator>DOC-[0-9]{0,20}-[0-9]{0,20})(?:[^"''\s<>]*)?[^>]*>.*?</a>'
$RichDocLocatorRelativeURLPatternToMatch = '<a\b[^>]*?href\s*=\s*["'']?/(?<DocLocator>DOC-[0-9]{0,20}-[0-9]{0,20})(?:[^"''\s<>]*)?[^>]*>.*?</a>'

$TextRegexPatternToMatchSansAssets = $ITGlueUrlPrefixPattern + '/(?<CompanyId>[0-9]{1,20})/(?<EntityType>docs|passwords|configurations|contacts)/(?<EntityId>[0-9]{1,20})(?!(?:/[^"''<>]*)?/(?:images|files|attachments)(?=/|$))'
$TextRegexPatternToMatchWithAssets = $ITGlueUrlPrefixPattern + '/(?<CompanyId>[0-9]{1,20})/(?<EntityType>assets)/.*?/(?<EntityId>[0-9]{1,20})'
$TextDomainsPatternToMatch = $ITGlueUrlPrefixPattern + '/(?<CompanyId>[0-9]{1,20})/(?<EntityType>domains)(?:/(?<EntityId>[0-9]{1,20}))?(?:[^\s<>"'']*)?'
$TextDocLocatorUrlPatternToMatch = $ITGlueUrlPrefixPattern + '/(?<DocLocator>DOC-[0-9]{0,20}-[0-9]{0,20})(?:[^\s<>"'']*)?'
$RichBareRegexPatternToMatchSansAssets = '(?<!["''=])' + $TextRegexPatternToMatchSansAssets
$RichBareRegexPatternToMatchWithAssets = '(?<!["''=])' + $TextRegexPatternToMatchWithAssets
$RichBareDomainsPatternToMatch = '(?<!["''=])' + $TextDomainsPatternToMatch
$RichBareDocLocatorUrlPatternToMatch = '(?<!["''=])' + $TextDocLocatorUrlPatternToMatch

$script:HuduURLReplacementLookup = $null
$script:HuduURLRegexCache = @{}

function Reset-HuduURLReplacementLookup {
    $script:HuduURLReplacementLookup = $null
}

function Test-ITGlueURLReplacementCandidate {
    param(
        [AllowNull()]
        [string]$Content
    )

    if ([string]::IsNullOrWhiteSpace($Content)) {
        return $false
    }

    return $ITGlueURLReplacementCandidateRegex.IsMatch($Content)
}

function Get-HuduURLRegex {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Pattern
    )

    if (-not $script:HuduURLRegexCache.ContainsKey($Pattern)) {
        $script:HuduURLRegexCache[$Pattern] = [regex]::new($Pattern, $ITGlueURLReplacementRegexOptions)
    }

    return $script:HuduURLRegexCache[$Pattern]
}

function Get-MatchGroupValue {
    param(
        [Parameter(Mandatory = $true)]
        [System.Text.RegularExpressions.Match]$Match,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $group = $Match.Groups[$Name]
    if ($group -and $group.Success) {
        return $group.Value
    }

    return $null
}

function Get-HuduURLReplacementRecord {
    param(
        [Parameter(Mandatory = $true)]
        $Source,

        [string]$EntityType
    )

    $huduObject = $Source.HuduObject ?? $Source.HuduCompanyObject ?? $Source
    $url = $huduObject.url
    $name = $huduObject.name ?? $Source.Name ?? $Source.CompanyName

    if ([string]::IsNullOrWhiteSpace([string]$url)) {
        if ($EntityType -eq 'domains' -and -not [string]::IsNullOrWhiteSpace([string]$huduObject.id)) {
            $url = "/websites/$($huduObject.id)"
        } elseif ($Source.PSObject.Properties['HuduCompanyObject'] -and -not [string]::IsNullOrWhiteSpace([string]$huduObject.id)) {
            $url = "/companies/$($huduObject.id)"
        }
    }

    if ([string]::IsNullOrWhiteSpace([string]$url)) {
        return $null
    }

    return [pscustomobject]@{
        Url    = [string]$url
        Name   = [string]$name
        Source = $Source
    }
}

function Add-HuduURLReplacementRecord {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Lookup,

        [Parameter(Mandatory = $true)]
        [string]$EntityType,

        [AllowNull()]
        $Item
    )

    foreach ($source in @($Item)) {
        if (-not $source) {
            continue
        }

        $record = Get-HuduURLReplacementRecord -Source $source -EntityType $EntityType
        if (-not $record) {
            continue
        }

        if (-not [string]::IsNullOrWhiteSpace([string]$source.ITGID)) {
            $Lookup[$EntityType]["$($source.ITGID)"] = $record
        }

        if ($EntityType -eq 'docs' -and -not [string]::IsNullOrWhiteSpace([string]$source.ITGLocator)) {
            $Lookup.DocLocators["$($source.ITGLocator)"] = $record
        }
    }
}

function Initialize-HuduURLReplacementLookup {
    param(
        [switch]$Force
    )

    if ($script:HuduURLReplacementLookup -and -not $Force) {
        return $script:HuduURLReplacementLookup
    }

    $lookup = @{
        docs           = @{}
        passwords      = @{}
        configurations = @{}
        assets         = @{}
        contacts       = @{}
        domains        = @{}
        CompanyDomains = @{}
        DocLocators    = @{}
    }

    Add-HuduURLReplacementRecord -Lookup $lookup -EntityType 'docs' -Item $MatchedArticles
    Add-HuduURLReplacementRecord -Lookup $lookup -EntityType 'passwords' -Item $MatchedPasswords
    Add-HuduURLReplacementRecord -Lookup $lookup -EntityType 'configurations' -Item $MatchedConfigurations
    Add-HuduURLReplacementRecord -Lookup $lookup -EntityType 'assets' -Item $MatchedAssets
    Add-HuduURLReplacementRecord -Lookup $lookup -EntityType 'contacts' -Item $MatchedContacts
    Add-HuduURLReplacementRecord -Lookup $lookup -EntityType 'domains' -Item $MatchedWebsites

    foreach ($company in @($MatchedCompanies)) {
        if (-not $company -or [string]::IsNullOrWhiteSpace([string]$company.ITGID)) {
            continue
        }

        $record = Get-HuduURLReplacementRecord -Source $company
        if ($record) {
            $lookup.CompanyDomains["$($company.ITGID)"] = $record
        }
    }

    $script:HuduURLReplacementLookup = $lookup
    return $script:HuduURLReplacementLookup
}

function ConvertTo-HuduRelativeURL {
    param(
        [AllowNull()]
        [string]$Url
    )

    if ([string]::IsNullOrWhiteSpace($Url)) {
        return $Url
    }

    $relativeUrl = $Url.Trim() -replace '^http://', 'https://'
    $baseCandidates = @(
        $HuduBaseDomain
        $settings.HuduBaseDomain
        $environmentSettings.HuduBaseDomain
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }

    if ($baseCandidates.Count -eq 0 -and (Get-Command -Name Get-HuduBaseURL -ErrorAction SilentlyContinue)) {
        $previousErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Stop'
            $baseCandidates += Get-HuduBaseURL
        } catch {
        } finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }
    }

    foreach ($base in ($baseCandidates | Select-Object -Unique)) {
        $baseUrl = ([string]$base).Trim().TrimEnd('/') -replace '^http://', 'https://'
        $relativeUrl = [regex]::Replace($relativeUrl, "(?i)^$([regex]::Escape($baseUrl))(?=/|$)", '')
    }

    if ([string]::IsNullOrWhiteSpace($relativeUrl)) {
        return '/'
    }

    return $relativeUrl
}

function Resolve-HuduURLReplacement {
    param(
        [Parameter(Mandatory = $true)]
        [System.Text.RegularExpressions.Match]$Match
    )

    $lookup = Initialize-HuduURLReplacementLookup

    $docLocator = Get-MatchGroupValue -Match $Match -Name 'DocLocator'
    if ([string]::IsNullOrWhiteSpace($docLocator)) {
        foreach ($group in $Match.Groups) {
            if ($group.Success -and $group.Value -like 'DOC-*') {
                $docLocator = $group.Value
                break
            }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($docLocator)) {
        return $lookup.DocLocators["$docLocator"]
    }

    $entityType = Get-MatchGroupValue -Match $Match -Name 'EntityType'
    $entityId = Get-MatchGroupValue -Match $Match -Name 'EntityId'

    if ([string]::IsNullOrWhiteSpace($entityType)) {
        $entityTypes = @('docs', 'passwords', 'configurations', 'assets')
        for ($i = 1; $i -lt $Match.Groups.Count; $i++) {
            if ($entityTypes -contains $Match.Groups[$i].Value) {
                $entityType = $Match.Groups[$i].Value
                if (($i + 1) -lt $Match.Groups.Count) {
                    $entityId = $Match.Groups[$i + 1].Value
                }
                break
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($entityType) -or [string]::IsNullOrWhiteSpace($entityId)) {
        if ($entityType -eq 'domains') {
            $companyId = Get-MatchGroupValue -Match $Match -Name 'CompanyId'
            if (-not [string]::IsNullOrWhiteSpace($companyId)) {
                return $lookup.CompanyDomains["$companyId"]
            }
        }

        return $null
    }

    if ($entityType -eq 'domains') {
        $domainRecord = $lookup.domains["$entityId"]
        if ($domainRecord) {
            return $domainRecord
        }

        $companyId = Get-MatchGroupValue -Match $Match -Name 'CompanyId'
        if (-not [string]::IsNullOrWhiteSpace($companyId)) {
            return $lookup.CompanyDomains["$companyId"]
        }
    }

    return $lookup[$entityType]["$entityId"]
}

function Resolve-ITGlueImageMatch {
    param(
        [Parameter(Mandatory = $true)]
        [System.Text.RegularExpressions.Match]$Match
    )

    $articleId = Get-MatchGroupValue -Match $Match -Name 'ArticleId'
    $imageRelativePath = Get-MatchGroupValue -Match $Match -Name 'ImageRelativePath'

    if ([string]::IsNullOrWhiteSpace($articleId) -and $Match.Groups.Count -gt 2) {
        $articleId = $Match.Groups[2].Value
    }

    if ([string]::IsNullOrWhiteSpace($imageRelativePath) -and $Match.Groups.Count -gt 1) {
        $imageRelativePath = $Match.Groups[1].Value
    }

    $originalArticle = ($MatchedArticles | Where-Object { $_.ITGID -eq $articleId } | Select-Object -First 1).Path
    if ([string]::IsNullOrWhiteSpace([string]$originalArticle) -or [string]::IsNullOrWhiteSpace($imageRelativePath)) {
        return $false
    }

    $imagePath = $imageRelativePath.Replace('/', '\')
    $fullImagePath = Join-Path -Path $originalArticle -ChildPath $imagePath
    $imageItem = Get-Item -Path ([System.Management.Automation.WildcardPattern]::Escape($fullImagePath) + '*') -ErrorAction SilentlyContinue

    if ($imageItem) {
        return [pscustomobject]@{
            path = $imageItem.FullName
            url  = $imageRelativePath
        }
    }

    return $false
}

function Get-ITGlueAttachmentIdFromUrl {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object[]]$Values
    )

    foreach ($value in @($Values)) {
        if ([string]::IsNullOrWhiteSpace([string]$value)) {
            continue
        }

        $decoded = [System.Net.WebUtility]::HtmlDecode(([string]$value).Trim())
        $match = [regex]::Match($decoded, '(?i)(?:^|[\\/])attachments[\\/](?<AttachmentId>\d{1,20})(?=$|[\\/?#&])')
        if ($match.Success) {
            return $match.Groups['AttachmentId'].Value
        }
    }

    return $null
}

function Find-ITGlueAttachmentFileById {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$AttachmentId,

        [AllowNull()]
        [object[]]$AttachmentFiles
    )

    if ([string]::IsNullOrWhiteSpace($AttachmentId)) {
        return $null
    }

    $escapedAttachmentId = [regex]::Escape($AttachmentId)
    $fileMatches = @(
        @($AttachmentFiles) |
            Where-Object { $_ -and $_.PSIsContainer -ne $true } |
            Where-Object {
                $_.BaseName -eq $AttachmentId -or
                $_.Name -match "^$escapedAttachmentId(?:\D|$)" -or
                $_.FullName -match "[\\/]$escapedAttachmentId(?:[\\/._ -]|$)"
            } |
            Sort-Object @{
                Expression = {
                    if ($_.BaseName -eq $AttachmentId) { 0 }
                    elseif ($_.Name -match "^$escapedAttachmentId(?:\D|$)") { 1 }
                    else { 2 }
                }
            }, FullName
    )

    return $fileMatches | Select-Object -First 1
}

function Normalize-ITGlueAttachmentImageFileName {
    param(
        [AllowNull()]
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return ''
    }

    return ([IO.Path]::GetFileName($Name).Trim()).ToLowerInvariant()
}

function Get-ITGlueAttachmentImageMetadataName {
    param(
        [AllowNull()]
        $Attachment
    )

    @(
        $Attachment.attributes.'file-name'
        $Attachment.attributes.file_name
        $Attachment.attributes.name
        $Attachment.attributes.attachment.file_name
        $Attachment.attributes.attachment.'file-name'
        $Attachment.attributes.'attachment-file-name'
        $Attachment.attributes.'attachment-file_name'
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -First 1
}

function Get-ITGlueAttachmentImageMetadataForResource {
    param(
        [AllowNull()]
        [string]$ResourceType,

        [AllowNull()]
        [string]$ResourceId
    )

    if ([string]::IsNullOrWhiteSpace($ResourceType) -or [string]::IsNullOrWhiteSpace($ResourceId)) {
        return @()
    }

    if ([string]::IsNullOrWhiteSpace($ITGKey)) {
        return @()
    }

    if (-not $script:ITGlueAttachmentImageMetadataCache) {
        $script:ITGlueAttachmentImageMetadataCache = @{}
    }

    $cacheKey = "$ResourceType/$ResourceId"
    if ($script:ITGlueAttachmentImageMetadataCache.ContainsKey($cacheKey)) {
        return $script:ITGlueAttachmentImageMetadataCache[$cacheKey]
    }

    $apiBase = @($ITGAPIEndpoint, $settings.ITGAPIEndpoint, $environmentSettings.ITGAPIEndpoint) |
        Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
        Select-Object -First 1

    if ([string]::IsNullOrWhiteSpace($apiBase)) {
        return @()
    }

    $uri = "$($apiBase.TrimEnd('/'))/$ResourceType/$ResourceId/relationships/attachments?page%5Bsize%5D=1000"
    try {
        $response = Invoke-RestMethod -Method GET -Uri $uri -Headers @{ 'x-api-key' = $ITGKey } -ErrorAction Stop
        $attachments = @($response.data)
    } catch {
        Write-Warning "Unable to retrieve IT Glue attachments for $ResourceType/$ResourceId while resolving article image attachments. $($_.Exception.Message)"
        $attachments = @()
    }

    $script:ITGlueAttachmentImageMetadataCache[$cacheKey] = $attachments
    return $attachments
}

function Find-ITGlueAttachmentImageMetadataById {
    param(
        [AllowNull()]
        [string]$AttachmentId,

        [AllowNull()]
        [string]$ResourceType,

        [AllowNull()]
        [string]$ResourceId
    )

    if ([string]::IsNullOrWhiteSpace($AttachmentId)) {
        return $null
    }

    $attachments = @(Get-ITGlueAttachmentImageMetadataForResource -ResourceType $ResourceType -ResourceId $ResourceId)
    return $attachments | Where-Object { [string]$_.id -eq [string]$AttachmentId } | Select-Object -First 1
}

function Find-ITGlueAttachmentFileByName {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$AttachmentName,

        [AllowNull()]
        [string]$ResourceId,

        [AllowNull()]
        [object[]]$AttachmentFiles
    )

    $normalizedName = Normalize-ITGlueAttachmentImageFileName -Name $AttachmentName
    if ([string]::IsNullOrWhiteSpace($normalizedName)) {
        return $null
    }

    $normalizedStem = Normalize-ITGlueAttachmentImageFileName -Name ([IO.Path]::GetFileNameWithoutExtension($AttachmentName))
    $normalizedRelativePath = ([string]$AttachmentName).Trim().Replace('/', '\').Trim('\').ToLowerInvariant()
    $resourcePathPattern = if ([string]::IsNullOrWhiteSpace($ResourceId)) { $null } else { "[\\/]$([regex]::Escape($ResourceId))[\\/]" }

    $fileMatches = @(
        @($AttachmentFiles) |
            Where-Object { $_ -and $_.PSIsContainer -ne $true } |
            Where-Object {
                $fileName = Normalize-ITGlueAttachmentImageFileName -Name $_.Name
                $fileStem = Normalize-ITGlueAttachmentImageFileName -Name $_.BaseName
                $fullName = ([string]$_.FullName).Replace('/', '\').ToLowerInvariant()
                $fullName.EndsWith("\$normalizedRelativePath") -or
                $fileName -eq $normalizedName -or
                ($normalizedStem -and $fileStem -eq $normalizedStem)
            } |
            Sort-Object @{
                Expression = {
                    $fullName = ([string]$_.FullName).Replace('/', '\').ToLowerInvariant()
                    if ($fullName.EndsWith("\$normalizedRelativePath")) { 0 }
                    elseif ($resourcePathPattern -and $_.FullName -match $resourcePathPattern) { 1 }
                    else { 2 }
                }
            }, FullName
    )

    return $fileMatches | Select-Object -First 1
}

function Resolve-ITGlueAttachmentImageFile {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object[]]$SourceValues,

        [AllowNull()]
        [string]$ExportPath,

        [AllowNull()]
        [object[]]$AttachmentFiles,

        [AllowNull()]
        [string]$ResourceType,

        [AllowNull()]
        [string]$ResourceId
    )

    $attachmentId = Get-ITGlueAttachmentIdFromUrl -Values $SourceValues
    if ([string]::IsNullOrWhiteSpace($attachmentId)) {
        return $null
    }

    $foundFile = Find-ITGlueAttachmentFileById -AttachmentId $attachmentId -AttachmentFiles $AttachmentFiles
    if ($foundFile) {
        return $foundFile
    }

    $attachmentMetadata = Find-ITGlueAttachmentImageMetadataById -AttachmentId $attachmentId -ResourceType $ResourceType -ResourceId $ResourceId
    $attachmentName = Get-ITGlueAttachmentImageMetadataName -Attachment $attachmentMetadata
    if (-not [string]::IsNullOrWhiteSpace([string]$attachmentName)) {
        $foundFile = Find-ITGlueAttachmentFileByName -AttachmentName $attachmentName -ResourceId $ResourceId -AttachmentFiles $AttachmentFiles
        if ($foundFile) {
            return $foundFile
        }
    }

    if ([string]::IsNullOrWhiteSpace($ExportPath)) {
        return $null
    }

    $attachmentRoot = Join-Path -Path $ExportPath -ChildPath 'attachments'
    if (-not (Test-Path -LiteralPath $attachmentRoot -PathType Container -ErrorAction SilentlyContinue)) {
        return $null
    }

    if (-not $script:ITGlueAttachmentImageFileCache) {
        $script:ITGlueAttachmentImageFileCache = @{}
    }

    $attachmentRootKey = (Get-Item -LiteralPath $attachmentRoot).FullName
    if (-not $script:ITGlueAttachmentImageFileCache.ContainsKey($attachmentRootKey)) {
        $script:ITGlueAttachmentImageFileCache[$attachmentRootKey] = @(
            Get-ChildItem -LiteralPath $attachmentRoot -Recurse -File -Force -ErrorAction SilentlyContinue
        )
    }

    $allAttachmentFiles = $script:ITGlueAttachmentImageFileCache[$attachmentRootKey]

    if (-not [string]::IsNullOrWhiteSpace([string]$attachmentName)) {
        $foundFile = Find-ITGlueAttachmentFileByName -AttachmentName $attachmentName -ResourceId $ResourceId -AttachmentFiles $allAttachmentFiles
        if ($foundFile) {
            return $foundFile
        }
    }

    return Find-ITGlueAttachmentFileById -AttachmentId $attachmentId -AttachmentFiles $allAttachmentFiles
}

function Set-HtmlAnchorHref {
    param(
        [Parameter(Mandatory = $true)]
        [string]$AnchorHtml,

        [Parameter(Mandatory = $true)]
        [string]$Href
    )

    if ($AnchorHtml -notmatch '^\s*<a\b') {
        return $null
    }

    return [regex]::Replace(
        $AnchorHtml,
        '(\bhref\s*=\s*)(["'']?)([^"''\s>]*)\2',
        [System.Text.RegularExpressions.MatchEvaluator]{
            param([System.Text.RegularExpressions.Match]$hrefMatch)

            $quote = $hrefMatch.Groups[2].Value
            if ([string]::IsNullOrEmpty($quote)) {
                $quote = '"'
            }

            "$($hrefMatch.Groups[1].Value)$quote$Href$quote"
        },
        $ITGlueURLReplacementRegexOptions,
        [timespan]::FromSeconds(1)
    )
}

function Update-StringWithCaptureGroups {
    [cmdletbinding()]
    param (
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$inputString,

        [Parameter(Mandatory = $true, Position = 1)]
        [string]$pattern,

        [Parameter(Mandatory = $true, Position = 2)]
        [string]$type
    )

    if ([string]::IsNullOrWhiteSpace($inputString)) {
        return $inputString
    }

    $regex = Get-HuduURLRegex -Pattern $pattern

    if ($type -ne 'img' -and -not $regex.IsMatch($inputString)) {
        return $inputString
    }

    if ($type -eq 'img') {
        $imageMatch = $regex.Match($inputString)
        if (-not $imageMatch.Success) {
            return $false
        }

        return Resolve-ITGlueImageMatch -Match $imageMatch
    }

    $replacementCount = 0
    $evaluator = [System.Text.RegularExpressions.MatchEvaluator]{
        param([System.Text.RegularExpressions.Match]$match)

        $replacement = Resolve-HuduURLReplacement -Match $match
        if (-not $replacement) {
            return $match.Value
        }

        $huduUrl = ConvertTo-HuduRelativeURL -Url $replacement.Url

        if ([string]::IsNullOrWhiteSpace($huduUrl)) {
            return $match.Value
        }

        $replacementCount++
        if ($type -eq 'rich') {
            $updatedAnchor = Set-HtmlAnchorHref -AnchorHtml $match.Value -Href $huduUrl
            if ($updatedAnchor) {
                return $updatedAnchor
            }

            $huduName = if ([string]::IsNullOrWhiteSpace($replacement.Name)) { $huduUrl } else { [System.Net.WebUtility]::HtmlEncode($replacement.Name) }
            return "<A HREF=`"$huduUrl`">$huduName</A>"
        }

        return $huduUrl
    }

    $updatedString = $regex.Replace($inputString, $evaluator)
    if ($replacementCount -gt 0) {
        Write-Host "Replaced $replacementCount IT Glue link(s)."
    }

    return $updatedString
}

function Convert-ITGlueLinksToHudu {
    param(
        [AllowNull()]
        [string]$Content,

        [ValidateSet('rich', 'plain')]
        [string]$Type = 'rich'
    )

    if (-not (Test-ITGlueURLReplacementCandidate -Content $Content)) {
        return $Content
    }

    $newContent = $Content

    if ($Type -eq 'rich') {
        foreach ($pattern in @(
            $RichRegexPatternToMatchSansAssets
            $RichRegexPatternToMatchWithAssets
            $RichDomainsPatternToMatch
            $RichDocLocatorUrlPatternToMatch
            $RichDocLocatorRelativeURLPatternToMatch
            $RichBareRegexPatternToMatchSansAssets
            $RichBareRegexPatternToMatchWithAssets
            $RichBareDomainsPatternToMatch
            $RichBareDocLocatorUrlPatternToMatch
        )) {
            $newContent = Update-StringWithCaptureGroups -inputString $newContent -pattern $pattern -type 'rich'
        }
    } else {
        foreach ($pattern in @(
            $TextRegexPatternToMatchSansAssets
            $TextRegexPatternToMatchWithAssets
            $TextDomainsPatternToMatch
            $TextDocLocatorUrlPatternToMatch
        )) {
            $newContent = Update-StringWithCaptureGroups -inputString $newContent -pattern $pattern -type 'plain'
        }
    }

    return $newContent
}

function Get-HardcodedImageMapByLeaf {
    param(
        [AllowNull()]
        $ImageMap
    )

    $imageMapByLeaf = @{}
    if (-not $ImageMap) {
        return $imageMapByLeaf
    }

    foreach ($kvp in $ImageMap.GetEnumerator()) {
        $leaf = Split-Path $kvp.Key -Leaf
        if ([string]::IsNullOrWhiteSpace($leaf)) {
            continue
        }

        if (-not $imageMapByLeaf.ContainsKey($leaf)) {
            $imageMapByLeaf[$leaf] = ConvertTo-HuduRelativeURL -Url $kvp.Value
        }

        $leafWithoutExtension = [System.IO.Path]::GetFileNameWithoutExtension($leaf)
        if (-not [string]::IsNullOrWhiteSpace($leafWithoutExtension) -and -not $imageMapByLeaf.ContainsKey($leafWithoutExtension)) {
            $imageMapByLeaf[$leafWithoutExtension] = ConvertTo-HuduRelativeURL -Url $kvp.Value
        }
    }

    return $imageMapByLeaf
}

function Get-HardcodedITGlueImagePattern {
    $imagePathPattern = '(?:documents/[^"''\s<>]*/images|[0-9]{1,20}/docs/[0-9]{1,20}(?:/[^"''<>]*?)?/images)'
    return '(?:' + $ITGlueUrlPrefixPattern + '/)?' + $imagePathPattern + '/(?<leaf>[^"''\s<>]+)'
}

function Convert-HardcodedITGlueImagesToHudu {
    param(
        [AllowNull()]
        [string]$Content,

        [AllowNull()]
        $ImageMap
    )

    $imageMapByLeaf = Get-HardcodedImageMapByLeaf -ImageMap $ImageMap
    $imageMapByUrl = Get-HardcodedImageMapByUrl -ImageMap $ImageMap
    if (($imageMapByLeaf.Count + $imageMapByUrl.Count) -lt 1 -or [string]::IsNullOrWhiteSpace($Content)) {
        return [pscustomobject]@{
            Content      = $Content
            Changed      = $false
            Replacements = @()
        }
    }

    $pattern = Get-HardcodedITGlueImagePattern
    $replacements = [System.Collections.ArrayList]@()

    $updatedContent = $Content

    foreach ($candidateUrl in @($imageMapByUrl.Keys | Sort-Object Length -Descending)) {
        if ([string]::IsNullOrWhiteSpace([string]$candidateUrl) -or -not $updatedContent.Contains([string]$candidateUrl)) {
            continue
        }

        $replacementUrl = $imageMapByUrl[$candidateUrl]
        $candidatePattern = [regex]::Escape($candidateUrl)
        $count = [regex]::Matches($updatedContent, $candidatePattern).Count
        if ($count -lt 1) {
            continue
        }

        $updatedContent = [regex]::Replace(
            $updatedContent,
            $candidatePattern,
            [System.Text.RegularExpressions.MatchEvaluator]{ param($match) $replacementUrl },
            $ITGlueURLReplacementRegexOptions
        )

        $null = $replacements.Add([pscustomobject]@{
            OriginalUrl    = $candidateUrl
            ReplacementUrl = $replacementUrl
            Count          = $count
            MatchType      = 'ImageMapUrl'
        })
    }

    $updatedContent = [regex]::Replace(
        $updatedContent,
        $pattern,
        [System.Text.RegularExpressions.MatchEvaluator]{
            param([System.Text.RegularExpressions.Match]$match)

            $leaf = $match.Groups['leaf'].Value
            if (-not $imageMapByLeaf.ContainsKey($leaf)) {
                return $match.Value
            }

            $replacementUrl = $imageMapByLeaf[$leaf]
            $null = $replacements.Add([pscustomobject]@{
                OriginalUrl    = $match.Value
                ReplacementUrl = $replacementUrl
                Leaf           = $leaf
            })
            return $replacementUrl
        },
        $ITGlueURLReplacementRegexOptions
    )

    return [pscustomobject]@{
        Content      = $updatedContent
        Changed      = ($updatedContent -ne $Content)
        Replacements = @($replacements)
    }
}

function ConvertTo-RelativeUrlMap {
    param(
        [AllowNull()]
        [hashtable]$UrlMap
    )

    $relativeMap = @{}
    if (-not $UrlMap) {
        return $relativeMap
    }

    foreach ($key in $UrlMap.Keys) {
        if ([string]::IsNullOrWhiteSpace([string]$key) -or [string]::IsNullOrWhiteSpace([string]$UrlMap[$key])) {
            continue
        }

        $relativeMap[[string]$key] = ConvertTo-HuduRelativeURL -Url $UrlMap[$key]
    }

    return $relativeMap
}

function Get-HardcodedImageUrlReplacementCandidates {
    param(
        [AllowNull()]
        [string]$OriginalUrl
    )

    if ([string]::IsNullOrWhiteSpace($OriginalUrl)) {
        return @()
    }

    $candidates = [System.Collections.ArrayList]@()
    $addCandidate = {
        param([AllowNull()][string]$Candidate)

        if ([string]::IsNullOrWhiteSpace($Candidate)) {
            return
        }

        $candidateText = [string]$Candidate
        $null = $candidates.Add($candidateText)

        $encodedCandidate = [System.Net.WebUtility]::HtmlEncode($candidateText)
        if ($encodedCandidate -and $encodedCandidate -ne $candidateText) {
            $null = $candidates.Add($encodedCandidate)
        }

        $decodedCandidate = [System.Net.WebUtility]::HtmlDecode($candidateText)
        if ($decodedCandidate -and $decodedCandidate -ne $candidateText) {
            $null = $candidates.Add($decodedCandidate)
        }
    }

    & $addCandidate $OriginalUrl

    try {
        $parsedUrl = [Uri]$OriginalUrl
        if ($parsedUrl.IsAbsoluteUri) {
            & $addCandidate $parsedUrl.PathAndQuery
            & $addCandidate $parsedUrl.AbsolutePath
        }
    } catch {}

    $attachmentId = Get-ITGlueAttachmentIdFromUrl -Values @($OriginalUrl)
    if (-not [string]::IsNullOrWhiteSpace($attachmentId)) {
        $attachmentPaths = @(
            "/attachments/$attachmentId"
            "/attachments/$attachmentId`?preview=1"
            "/attachments/$attachmentId`?preview=true"
        )

        foreach ($attachmentPath in $attachmentPaths) {
            & $addCandidate $attachmentPath
            foreach ($baseUrl in @($ITGURL, $settings.ITGURL, $environmentSettings.ITGURL)) {
                if (-not [string]::IsNullOrWhiteSpace([string]$baseUrl)) {
                    & $addCandidate "$(([string]$baseUrl).TrimEnd('/'))$attachmentPath"
                }
            }
        }
    }

    @($candidates | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique | Sort-Object Length -Descending)
}

function Get-HardcodedImageMapByUrl {
    param(
        [AllowNull()]
        $ImageMap
    )

    $imageMapByUrl = @{}
    if (-not $ImageMap) {
        return $imageMapByUrl
    }

    foreach ($kvp in $ImageMap.GetEnumerator()) {
        if ([string]::IsNullOrWhiteSpace([string]$kvp.Key) -or [string]::IsNullOrWhiteSpace([string]$kvp.Value)) {
            continue
        }

        foreach ($candidate in @(Get-HardcodedImageUrlReplacementCandidates -OriginalUrl ([string]$kvp.Key))) {
            if (-not $imageMapByUrl.ContainsKey($candidate)) {
                $imageMapByUrl[$candidate] = ConvertTo-HuduRelativeURL -Url $kvp.Value
            }
        }
    }

    return $imageMapByUrl
}

function Test-HardcodedImageMapUrlCandidate {
    param(
        [AllowNull()]
        [string]$Content,

        [AllowNull()]
        $ImageMap
    )

    if ([string]::IsNullOrWhiteSpace($Content) -or -not $ImageMap) {
        return $false
    }

    $imageMapByUrl = Get-HardcodedImageMapByUrl -ImageMap $ImageMap
    foreach ($candidate in @($imageMapByUrl.Keys)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$candidate) -and $Content.Contains([string]$candidate)) {
            return $true
        }
    }

    return $false
}

function Test-HuduHostedImageAnchorCandidate {
    param(
        [AllowNull()]
        [string]$Content,

        [bool]$IncludeUploads = $false
    )

    if ([string]::IsNullOrWhiteSpace($Content)) {
        return $false
    }

    $uploadPattern = if ($IncludeUploads) { '|uploads' } else { '' }
    return $Content -imatch '<img\b[^>]*\bsrc\s*=\s*["''](?:https?://[^"''\s<>]+)?/(?:public_photo[s]?' + $uploadPattern + ')/'
}

function Test-HuduContentLinkReplacementCandidate {
    param(
        [AllowNull()]
        [string]$Content,

        [ValidateSet('rich', 'plain')]
        [string]$Type = 'rich',

        [AllowNull()]
        $ImageMap,

        [AllowNull()]
        [hashtable]$AttachmentUrlMap,

        [AllowNull()]
        [hashtable]$AttachmentUrlLookup,

        [switch]$IncludeHardcodedImages,
        [switch]$IncludeAttachments,
        [switch]$IncludeHostedImageAnchors,
        [switch]$IncludeUploads
    )

    if ([string]::IsNullOrWhiteSpace($Content)) {
        return $false
    }

    if (Test-ITGlueURLReplacementCandidate -Content $Content) {
        return $true
    }

    if ($IncludeHardcodedImages -and $ImageMap -and (
            $Content -imatch (Get-HardcodedITGlueImagePattern) -or
            (Test-HardcodedImageMapUrlCandidate -Content $Content -ImageMap $ImageMap)
        )) {
        return $true
    }

    if ($IncludeAttachments -and $AttachmentUrlMap -and $AttachmentUrlMap.Count -gt 0 -and $Content -imatch '/(?:files|attachments)/\d{1,20}') {
        return $true
    }

    if ($IncludeHostedImageAnchors -and (Test-HuduHostedImageAnchorCandidate -Content $Content -IncludeUploads:$IncludeUploads)) {
        return $true
    }

    return $false
}

function Update-HuduContentLinks {
    param(
        [AllowNull()]
        [string]$Content,

        [ValidateSet('rich', 'plain')]
        [string]$Type = 'rich',

        [AllowNull()]
        $ImageMap,

        [AllowNull()]
        [hashtable]$AttachmentUrlMap,

        [AllowNull()]
        [hashtable]$AttachmentUrlLookup,

        [switch]$IncludeHardcodedImages,
        [switch]$IncludeAttachments,
        [switch]$IncludeHostedImageAnchors,
        [switch]$IncludeUploads
    )

    $newContent = $Content
    $replacementSets = [System.Collections.ArrayList]@()

    $itgContent = Convert-ITGlueLinksToHudu -Content $newContent -Type $Type
    if ($itgContent -ne $newContent) {
        $null = $replacementSets.Add([pscustomobject]@{
            Type    = 'ITGlueLinks'
            Changed = $true
        })
        $newContent = $itgContent
    }

    if ($Type -eq 'rich' -and $IncludeHardcodedImages) {
        $hardcodedImages = Convert-HardcodedITGlueImagesToHudu -Content $newContent -ImageMap $ImageMap
        if ($hardcodedImages.Changed) {
            $null = $replacementSets.Add([pscustomobject]@{
                Type         = 'HardcodedImages'
                Changed      = $true
                Replacements = $hardcodedImages.Replacements
            })
            $newContent = $hardcodedImages.Content
        }
    }

    if ($IncludeAttachments -and (Get-Command -Name Update-ContentWithAttachmentUrlLookup -ErrorAction SilentlyContinue)) {
        if (-not $AttachmentUrlLookup -and $AttachmentUrlMap -and $AttachmentUrlMap.Count -gt 0 -and (Get-Command -Name New-AttachmentUrlReplacementLookup -ErrorAction SilentlyContinue)) {
            $relativeAttachmentUrlMap = ConvertTo-RelativeUrlMap -UrlMap $AttachmentUrlMap
            $AttachmentUrlLookup = New-AttachmentUrlReplacementLookup -UrlMap $relativeAttachmentUrlMap
        }

        $attachments = if ($AttachmentUrlLookup -and $AttachmentUrlLookup.Count -gt 0) {
            Update-ContentWithAttachmentUrlLookup -Content $newContent -Lookup $AttachmentUrlLookup
        } else {
            [pscustomobject]@{
                Content      = $newContent
                Changed      = $false
                Replacements = @()
            }
        }

        if ($attachments.Changed) {
            $null = $replacementSets.Add([pscustomobject]@{
                Type         = 'AttachmentLinks'
                Changed      = $true
                Replacements = $attachments.Replacements
            })
            $newContent = $attachments.Content
        }
    }

    if ($Type -eq 'rich' -and $IncludeHostedImageAnchors -and (Get-Command -Name Set-HuduImageAnchorsReplaced -ErrorAction SilentlyContinue)) {
        $anchoredContent = Set-HuduImageAnchorsReplaced -Html $newContent -IncludeUploads:$IncludeUploads
        if ($anchoredContent -ne $newContent) {
            $null = $replacementSets.Add([pscustomobject]@{
                Type    = 'HostedImageAnchors'
                Changed = $true
            })
            $newContent = $anchoredContent
        }
    }

    return [pscustomobject]@{
        Content         = $newContent
        Changed         = ($newContent -ne $Content)
        ReplacementSets = @($replacementSets)
    }
}

function ConvertTo-HuduURL {
    param(
        $Content
    )

    return Convert-ITGlueLinksToHudu -Content $Content -Type 'rich'
}
