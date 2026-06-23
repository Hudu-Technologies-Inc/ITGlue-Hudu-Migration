# This will be used to remake the ITGlue Links to Hudu, and relies on the articles logs existing.


$EscapedITGURL = [regex]::Escape($ITGURL)

if ($environmentSettings.ITGCustomDomains) {
    $combinedEscapedURLs = ($environmentSettings.ITGCustomDomains -split "," | ForEach-Object { [regex]::Escape($_) }) -join "|"
    $EscapedITGURL = "(?:$EscapedITGURL|$combinedEscapedURLs)"
}


# We want to grab all assets, passwords, websites, and companies, filter to fields and notes that have ITGlue URLs in them and prime for replacement.
# Following capture Groups
# 0 = Entire match found
# 1,5 = A/a (not important)
# 2 = ITGlue Company ID (Important for LOCATOR)
# 3 = type of Entity (Important for location)
# 4 = ITGlue Entity ID

$RichRegexPatternToMatchSansAssets = "<(A|a) href=\S$EscapedITGURL/([0-9]{1,20})/(docs|passwords|configurations|assets)/([0-9]{1,20})\S.*?</(A|a)>"
$RichRegexPatternToMatchWithAssets = "<(A|a) href=\S$EscapedITGURL/([0-9]{1,20})/(assets)/.*?/([0-9]{1,20})\S.*?</(A|a)>"
$ImgRegexPatternToMatch = @"
$EscapedITGURL/([0-9]{1,20}/docs/([0-9]{1,20})/(images)/([0-9]{1,20}).*?)(?=")
"@
$RichDocLocatorUrlPatternToMatch = @"
<(A|a) href=\S$EscapedITGURL/(DOC-.*?)(?=")\S.*?</(A|a)>
"@
$RichDocLocatorRelativeURLPatternToMatch = @"
<(A|a) href=\S/(DOC-.*?)(?=")\S.*?</(A|a)>
"@

$TextRegexPatternToMatchSansAssets = "$EscapedITGURL/([0-9]{1,20})/(docs|passwords|configurations)/([0-9]{1,20})"
$TextRegexPatternToMatchWithAssets = "$EscapedITGURL/([0-9]{1,20})/(assets)/.*?/([0-9]{1,20})"
$TextDocLocatorUrlPatternToMatch = "$EscapedITGURL/(DOC-[0-9]{0,20}-[0-9]{0,20}).*(?= )"

function Remove-ITGlueUrlSuffixJunk {
    param(
        [AllowEmptyString()]
        [string]$Url
    )

    if ([string]::IsNullOrWhiteSpace($Url)) { return $Url }

    $DecodedUrl = [System.Net.WebUtility]::HtmlDecode($Url)
    if ($DecodedUrl -match '[?#].*(version=|documentMode=|preview(?:=|&|$)|edit(?:=|&|$))') {
        return ($DecodedUrl -split '[?#]', 2)[0]
    }

    return $DecodedUrl
}

function Get-HuduUrlRewriteTarget {
    param(
        $MatchedItem,
        [string]$FallbackName
    )

    if (-not $MatchedItem) { return $null }
    $Item = @($MatchedItem | Select-Object -First 1)[0]
    if (-not $Item) { return $null }

    $HuduObject = $Item.HuduObject
    if (-not $HuduObject -and $Item.HuduCompanyObject) { $HuduObject = $Item.HuduCompanyObject }
    if (-not $HuduObject -and $Item.HuduCompany) { $HuduObject = $Item.HuduCompany }

    $HuduUrl = $HuduObject.url
    if (-not $HuduUrl -and $Item.url) { $HuduUrl = $Item.url }
    if (-not $HuduUrl -and $HuduBaseDomain -and $Item.HuduID) {
        $HuduUrl = "$($HuduBaseDomain.TrimEnd('/'))/companies/$($Item.HuduID)"
    }

    if (-not $HuduUrl) { return $null }

    $HuduName = $HuduObject.name
    if (-not $HuduName) { $HuduName = $Item.Name }
    if (-not $HuduName) { $HuduName = $FallbackName }

    [pscustomobject]@{
        Url  = $HuduUrl.replace('http://','https://')
        Name = $HuduName
    }
}

function Test-ITGlueHrefCandidate {
    param(
        [AllowEmptyString()]
        [string]$Href
    )

    if ([string]::IsNullOrWhiteSpace($Href)) { return $false }

    $DecodedHref = [System.Net.WebUtility]::HtmlDecode($Href)
    if ($DecodedHref -match "^$EscapedITGURL(?:/|$)") { return $true }
    if ($DecodedHref -match '^/?DOC-[0-9]{1,20}-[0-9]{1,20}(?:[?#].*)?$') { return $true }
    if ($DecodedHref -match '^/[0-9]{1,20}/(docs|passwords|configurations|assets|domains)(?:/|[?#]|$)') { return $true }

    return $false
}

function Resolve-ITGlueHrefToHuduTarget {
    param(
        [string]$Href
    )

    if (-not (Test-ITGlueHrefCandidate -Href $Href)) { return $null }

    $CleanHref = Remove-ITGlueUrlSuffixJunk -Url $Href
    if ([string]::IsNullOrWhiteSpace($CleanHref)) { return $null }

    if ($CleanHref -match '^/?(?<Locator>DOC-[0-9]{1,20}-[0-9]{1,20})$') {
        return Get-HuduUrlRewriteTarget -MatchedItem ($MatchedArticles | Where-Object { $_.ITGLocator -eq $Matches.Locator }) -FallbackName $Matches.Locator
    }

    $Path = [regex]::Replace($CleanHref, "^$EscapedITGURL", '')
    if ($Path -notmatch '^/') { return $null }

    if ($Path -notmatch '^/(?<CompanyId>[0-9]{1,20})/(?<Resource>docs|passwords|configurations|assets|domains)(?:/(?<Rest>[^?#]*))?$') {
        return $null
    }

    $CompanyId = $Matches.CompanyId
    $Resource = $Matches.Resource
    $Rest = $Matches.Rest
    $IdMatches = [regex]::Matches($Rest, '[0-9]{1,20}')
    $ResourceId = if ($IdMatches.Count -gt 0) { $IdMatches[$IdMatches.Count - 1].Value } else { $null }

    switch ($Resource) {
        'docs' {
            if ($ResourceId) {
                return Get-HuduUrlRewriteTarget -MatchedItem ($MatchedArticles | Where-Object { $_.ITGID -eq $ResourceId }) -FallbackName "Document $ResourceId"
            }
        }
        'passwords' {
            if ($ResourceId) {
                $PasswordMatch = @($MatchedPasswords | Where-Object { $_.ITGID -eq $ResourceId })
                if (-not $PasswordMatch -or $PasswordMatch.Count -lt 1) {
                    $PasswordMatch = @($MatchedAssetPasswords | Where-Object { $_.ITGID -eq $ResourceId })
                }
                return Get-HuduUrlRewriteTarget -MatchedItem $PasswordMatch -FallbackName "Password $ResourceId"
            }
        }
        'configurations' {
            if ($ResourceId) {
                return Get-HuduUrlRewriteTarget -MatchedItem ($MatchedConfigurations | Where-Object { $_.ITGID -eq $ResourceId }) -FallbackName "Configuration $ResourceId"
            }
        }
        'assets' {
            if ($ResourceId) {
                return Get-HuduUrlRewriteTarget -MatchedItem ($MatchedAssets | Where-Object { $_.ITGID -eq $ResourceId }) -FallbackName "Asset $ResourceId"
            }
        }
        'domains' {
            if ($ResourceId) {
                return Get-HuduUrlRewriteTarget -MatchedItem ($MatchedWebsites | Where-Object { $_.ITGID -eq $ResourceId }) -FallbackName "Domain $ResourceId"
            }

            return Get-HuduUrlRewriteTarget -MatchedItem ($MatchedCompanies | Where-Object { $_.ITGID -eq $CompanyId }) -FallbackName "Company $CompanyId"
        }
    }

    return $null
}

function Update-HuduRichTextITGlueHrefs {
    param(
        [AllowEmptyString()]
        [string]$Content
    )

    if ([string]::IsNullOrWhiteSpace($Content)) { return $Content }

    $HrefPattern = '(?i)(?<Prefix>\bhref\s*=\s*)(?<Quote>["''])(?<Href>.*?)(\k<Quote>)'

    [regex]::Replace(
        $Content,
        $HrefPattern,
        [System.Text.RegularExpressions.MatchEvaluator]{
            param($Match)

            $OriginalHref = $Match.Groups['Href'].Value
            $IsITGlueHref = Test-ITGlueHrefCandidate -Href $OriginalHref
            $CleanHref = if ($IsITGlueHref) {
                Remove-ITGlueUrlSuffixJunk -Url $OriginalHref
            } else {
                [System.Net.WebUtility]::HtmlDecode($OriginalHref)
            }
            $Target = Resolve-ITGlueHrefToHuduTarget -Href $OriginalHref

            $ReplacementHref = if ($Target -and $Target.Url) {
                $Target.Url
            } elseif ($IsITGlueHref -and $CleanHref -ne [System.Net.WebUtility]::HtmlDecode($OriginalHref)) {
                $CleanHref
            } else {
                $null
            }

            if (-not $ReplacementHref) { return $Match.Value }

            $EncodedHref = [System.Net.WebUtility]::HtmlEncode($ReplacementHref)
            return "$($Match.Groups['Prefix'].Value)$($Match.Groups['Quote'].Value)$EncodedHref$($Match.Groups['Quote'].Value)"
        }
    )
}

function Update-StringWithCaptureGroups {
    [cmdletbinding()]
    param (
      [Parameter(Mandatory=$true, Position=0)]
      [string]$inputString,
      [Parameter(Mandatory=$true, Position=1)]
      [string]$pattern,
      [Parameter(Mandatory=$true, Position=2)]
      [string]$type
    )

    if ($type -eq 'rich') {
        $inputString = Update-HuduRichTextITGlueHrefs -Content $inputString
    }
  
    $regex = [regex]::new($pattern)
    
    $matchesPattern = $regex.Matches($inputString)

    Write-Host "Found $($matchesPattern.count) matches to replace"
  
    foreach ($match in $matchesPattern) {

        # Compare the 3rd Group to identify where to find the new content

        switch ($match.groups[3].value) {

            "docs" {
                Write-Host "Found an $($match.groups[3].value) URL to replace for ITGID $($match.groups[4].value)..." -ForegroundColor 'Blue'
                $HuduUrl = ($MatchedArticles |Where-Object {$_.ITGID -eq $match.groups[4].value}).HuduObject.url
                $HuduName = ($MatchedArticles |Where-Object {$_.ITGID -eq $match.groups[4].value}).HuduObject.name
                if ($HuduUrl -and $HuduName) {
                Write-Host "Matched $($match.groups[3].value) URL to Hudu doc: $HuduName" -ForegroundColor 'Cyan'
                } else { Remove-Variable HuduName,HuduURL; Write-Warning "The matched regex did not resolve to a Hudu article" }
               
            }

            "a" {
                Write-Host "Found a DOC Locator link for locator $($match.groups[2].value)" -ForegroundColor 'Blue'
                $HuduUrl = ($MatchedArticles |Where-Object {$_.ITGLocator -eq $match.groups[2].value}).HuduObject.url
                $HuduName = ($MatchedArticles |Where-Object {$_.ITGLocator -eq $match.groups[2].value}).HuduObject.name
                if ($HuduURL -and $HuduName) {
                    Write-Host "Matched $($match.groups[2].value) Locator to Hudu doc: $HuduName" -ForegroundColor 'Cyan'
                } else { Remove-Variable HuduName,HuduURL; Write-Warning "The matched regex did not resolve to a Hudu article" }

            }

            "passwords" {
                Write-Host "Found an $($match.groups[3].value) URL to replace" -ForegroundColor 'Blue'
                $HuduUrl = ($MatchedPasswords |Where-Object {$_.ITGID -eq $match.groups[4].value}).HuduObject.url
                $HuduName = ($MatchedPasswords |Where-Object {$_.ITGID -eq $match.groups[4].value}).HuduObject.name
                if ($HuduUrl -and $HuduName) {
                Write-Host "Matched $($match.groups[3].value) URL to Hudu Passsword: $HuduName" -ForegroundColor 'Cyan'
                } else { Remove-Variable HuduName,HuduURL; Write-Warning "The matched regex did not resolve to a Hudu article" }
            }

            "configurations" {
                Write-Host "Found an $($match.groups[3].value) URL to replace" -ForegroundColor 'Blue'
                $HuduUrl = ($MatchedConfigurations |Where-Object {$_.ITGID -eq $match.groups[4].value}).HuduObject.url
                $HuduName = ($MatchedConfigurations |Where-Object {$_.ITGID -eq $match.groups[4].value}).HuduObject.name
                if ($HuduUrl -and $HuduName) {
                Write-Host "Matched $($match.groups[3].value) URL to Hudu Asset: $HuduName" -ForegroundColor 'Cyan'
                } else { Remove-Variable HuduName,HuduURL; Write-Warning "The matched regex did not resolve to a Hudu article" }
            }

            "assets" {
                Write-Host "Found an $($match.groups[3].value) URL to replace" -ForegroundColor 'Blue'
                $HuduUrl = ($MatchedAssets |Where-Object {$_.ITGID -eq $match.groups[4].value}).HuduObject.url
                $HuduName = ($MatchedAssets |Where-Object {$_.ITGID -eq $match.groups[4].value}).HuduObject.name
                if ($HuduUrl -and $HuduName) {
                Write-Host "Matched $($match.groups[3].value) URL to Hudu Asset: $HuduName" -ForegroundColor 'Cyan'
                } else { Remove-Variable HuduName,HuduURL; Write-Warning "The matched regex did not resolve to a Hudu article" }
            }

            "images" {
                Write-Host "Found an external image using a Direct ITGlue link" -ForegroundColor 'Blue'
                $OriginalArticle = ($MatchedArticles | Where-Object {$_.ITGID -eq $match.groups[2].value}).Path
                $ImagePath = $match.groups[1].value.replace('/','\')
                $FullImagePath = Join-Path -Path $OriginalArticle -ChildPath $ImagePath
                $ImageItem = Get-Item -Path "$FullImagePath*" -ErrorAction SilentlyContinue
                if ($ImageItem) {
                    Return [pscustomobject]@{
                        "path" = $ImageItem.FullName
                        "url" = $match.Groups[1]
                    }
                }
                else { return $false}
                }
            default {
                if ($match.groups[1].value -like 'DOC-*') {
                    Write-Host "Found a DOC Locator link for locator $($match.groups[1].value)" -ForegroundColor 'Blue'
                    $HuduUrl = ($MatchedArticles |Where-Object {$_.ITGLocator -eq $match.groups[1].value}).HuduObject.url
                    $HuduName = ($MatchedArticles |Where-Object {$_.ITGLocator -eq $match.groups[1].value}).HuduObject.name
                    if ($HuduURL -and $HuduName) {
                        Write-Host "Matched $($match.groups[1].value) Locator to Hudu doc: $HuduName" -ForegroundColor 'Cyan'
                    } else { Remove-Variable HuduName,HuduURL; Write-Warning "The matched regex did not resolve to a Hudu article" }
                }
            }



        }
    
        if ($HuduUrl) {
            $HuduUrl = $HuduUrl.replace("http://","https://")
            if ($type -eq 'rich') {
            $ReplacementString = @"
            <A HREF="$HuduUrl">$HuduName</A>
"@
            }
            else {
                $ReplacementString = $HuduUrl
            }

            $inputString = $inputString -replace [regex]::Escape([string]$match.Value),[string]$ReplacementString
        }

      

    }
  
    return $inputString
  }
  

function ConvertTo-HuduURL {
    param(
        $Content
    )
    $NewContent = Update-StringWithCaptureGroups -inputString $Content -pattern $RegexPatternToMatchSansAssets
    $NewContent = Update-StringWithCaptureGroups -inputString $NewContent -pattern $RegexPatternToMatchWithAssets

    return $NewContent

}
