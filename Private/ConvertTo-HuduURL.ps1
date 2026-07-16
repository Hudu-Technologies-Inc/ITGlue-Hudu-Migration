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

$EscapedITGURL = ($ITGlueURLCandidates | ForEach-Object { [regex]::Escape($_) }) -join "|"
if ([string]::IsNullOrWhiteSpace($EscapedITGURL)) {
    $EscapedITGURL = '(?!)'
} else {
    $EscapedITGURL = "(?:$EscapedITGURL)"
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
    if ($imageMapByLeaf.Count -lt 1 -or [string]::IsNullOrWhiteSpace($Content)) {
        return [pscustomobject]@{
            Content      = $Content
            Changed      = $false
            Replacements = @()
        }
    }

    $pattern = Get-HardcodedITGlueImagePattern
    $replacements = [System.Collections.ArrayList]@()

    $updatedContent = [regex]::Replace(
        $Content,
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

    if ($IncludeHardcodedImages -and $ImageMap -and $Content -imatch (Get-HardcodedITGlueImagePattern)) {
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
