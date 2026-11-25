#requires -Version 7.2
# Exercise the real article-body phase with offline DOM/API doubles.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$repoRoot = Split-Path $PSScriptRoot -Parent
. "$repoRoot/Public/ArticleContentLocalCache.ps1"
. "$repoRoot/Public/Normalize-String.ps1"
. "$repoRoot/Public/Normalize-And-ConvertImage.ps1"
$checks = 0
function Assert-ArticlePreparation {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    $script:checks++
}

$mainSource = Get-Content -LiteralPath "$repoRoot/ITGlue-Hudu-Migration.ps1" -Raw
$start = $mainSource.IndexOf('############################### Documents / Articles Bodies ###############################')
$end = $mainSource.IndexOf('############################### Passwords ###############################', $start)
Assert-ArticlePreparation ($start -ge 0 -and $end -gt $start) 'Could not locate article-body preparation.'
$bodyPhase = [scriptblock]::Create($mainSource.Substring($start, $end - $start))
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) "itglue-article-preparation-$([guid]::NewGuid().ToString('N'))"
$lock = $null
try {
    $debugFolder = $fixtureRoot
    $MigrationLogs = Join-Path $fixtureRoot 'logs'
    $ITGlueExportPath = Join-Path $fixtureRoot 'export'
    $WorkingDirectory = Join-Path $fixtureRoot 'normalized-images'
    $null = [IO.Directory]::CreateDirectory($MigrationLogs)
    $null = [IO.Directory]::CreateDirectory((Join-Path $ITGlueExportPath 'images'))
    $null = [IO.Directory]::CreateDirectory((Join-Path $fixtureRoot 'ArticleContent'))
    foreach ($name in @('validation.png', 'unknown-format', 'healthy.png')) {
        [IO.File]::WriteAllText((Join-Path $ITGlueExportPath "images/$name"), 'fixture image')
    }
    $ITGURL = 'https://itglue.invalid'
    $HuduBaseDomain = 'https://hudu.invalid'
    $ITGAPIEndpoint = 'https://api.invalid'
    $ITGKey = 'offline'
    $ImportArticles = $true
    $ResumeFound = $false
    $ManualActions = [Collections.ArrayList]::new()
    $ImageMap = @{}
    $domCalls = [Collections.Generic.List[int]]::new()
    $uploads = [Collections.Generic.List[object]]::new()
    $jobs = [Collections.Generic.List[string]]::new()
    function Start-MigrationJob { param($Name) $jobs.Add($Name) }
    function Write-TimedMessage { param($Timeout, $Message, $DefaultResponse) }
    function New-ITGlueDocumentImageRecoveryContext { param($ApiBase, $ApiKey, $MigrationLogsPath) @{} }
    function Get-ITGlueArticleSourceImages { param($Content) @() }
    function Get-ITGlueDocumentImageReferences { param($SourceValues) @{ Ids = @(); StepIds = @() } }
    function Write-ErrorObjectsToFile { param($ErrorObject, $name) }
    function Invoke-ImageTest {
        [CmdletBinding()]
        param($FilePath)
        if ([IO.Path]::GetFileName($FilePath) -eq 'validation.png') { throw 'Simulated image validation error' }
        $true
    }
    # Keep the real normalization/copy path. An extensionless unrecognized image
    # triggers its actual "Unable to determine image type" exception.
    function Get-ImageType {
        param($FilePath)
        if ([IO.Path]::GetExtension($FilePath)) { 'png' }
    }
    function New-HuduPublicPhoto {
        [CmdletBinding()]
        param($FilePath, $record_id, $record_type)
        $uploads.Add(@{ Path = $FilePath; ArticleId = $record_id })
        @{ public_photo = @{ url = "$HuduBaseDomain/public_photo/healthy" } }
    }
    function New-Object {
        [CmdletBinding()]
        param($ComObject)
        if ($ComObject -ne 'HTMLFile') { throw "Unexpected object: $ComObject" }
        $domCalls.Add([int]$Article.HuduID)
        $dom = [pscustomobject]@{ Images = @(); Links = @(); documentelement = [pscustomobject]@{ outerhtml = '' } }
        $dom | Add-Member -MemberType ScriptMethod -Name write -Value {
            param($Bytes)
            $source = [Text.Encoding]::Unicode.GetString($Bytes)
            $this.documentelement.outerhtml = $source
            $this.Images = @([regex]::Matches($source, '<img src="([^"]+)"\s*/?>') | ForEach-Object {
                [pscustomobject]@{ src = $_.Groups[1].Value; outerHTML = $_.Value; innerHTML = '' }
            })
        }
        $dom
    }

    $MatchedArticles = @(foreach ($id in 101..107) {
        $sourcePath = Join-Path $ITGlueExportPath "$id.html"
        $content = if ($id -eq 102) {
            '<p>Keep this article text</p><img src="images/validation.png"><img src="images/unknown-format"><img src="images/healthy.png">'
        } elseif ($id -eq 107) { '' } else { "<p>Article $id</p>" }
        if ($id -ne 103) { [IO.File]::WriteAllText($sourcePath, $content) }
        [pscustomobject]@{
            HuduID = $id; ITGID = $id + 1000; ITGLocator = "DOC-$id"; Name = "Article $id"
            FullPath = $sourcePath; Imported = 'Stub-Created'
            Company = @{ HuduID = 1; CompanyName = 'Offline company' }
            HuduObject = @{ url = "$HuduBaseDomain/kba/$id"; content = 'Do not use Hudu fallback' }
        }
    })
    $blockedCachePath = Join-Path $fixtureRoot 'ArticleContent/105.html'
    [IO.File]::WriteAllText($blockedCachePath, 'locked')
    $lock = [IO.File]::Open($blockedCachePath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)

    # The migration normally continues after unhandled statement errors. Use the
    # same preference, so the regression cannot be hidden by a global Stop.
    $ErrorActionPreference = 'Continue'
    try { Set-StrictMode -Off; . $bodyPhase 3> (Join-Path $fixtureRoot 'fresh-warnings.txt') 6>$null }
    finally { Set-StrictMode -Version Latest; $ErrorActionPreference = 'Stop' }
    Assert-ArticlePreparation ($jobs.Count -eq 1) 'Fresh article preparation did not run.'
    foreach ($id in @(101, 102, 104, 106, 107)) {
        $article = $MatchedArticles | Where-Object HuduID -eq $id
        Assert-ArticlePreparation ($article.Imported -eq 'Content-Prepared-Locally' -and (Test-Path -LiteralPath $article.LocalContentPath)) "Article $id was lost after an earlier failure."
    }
    Assert-ArticlePreparation ($ManualActions.Count -eq 2 -and @($ManualActions | Where-Object Notes -eq 'Image validation or conversion failed').Count -eq 2) 'Image validation/conversion failures were not recorded individually.'
    Assert-ArticlePreparation ($ManualActions[1].Data -like '*Unable to determine image type*') 'The real normalization failure was not exercised.'
    Assert-ArticlePreparation ($uploads.Count -eq 1 -and $uploads[0].ArticleId -eq 102) 'An image failure prevented a later image in the same article from uploading.'
    Assert-ArticlePreparation ((Get-HuduArticleLocalContent $MatchedArticles[1]) -like '*Keep this article text*') 'An image failure discarded the article body.'
    Assert-ArticlePreparation ($ArticleErrors.Count -eq 2 -and ($ArticleErrors.MigrationObject.HuduID -join ',') -eq '103,105') 'Source/cache failures were not isolated to their articles.'
    foreach ($id in @(103, 105)) {
        $article = $MatchedArticles | Where-Object HuduID -eq $id
        Assert-ArticlePreparation ($null -eq $article.PSObject.Properties['LocalContentPath'] -and $article.Imported -eq 'Stub-Created') "Failed article $id was marked prepared."
    }
    Assert-ArticlePreparation ((Get-HuduArticleLocalContent $MatchedArticles[6]) -eq 'Empty Document in IT Glue Export - Please Check IT Glue') 'A genuinely empty export lost its existing placeholder behavior.'
    $savedArticles = @(Get-Content -LiteralPath (Join-Path $MigrationLogs 'Articles.json') -Raw | ConvertFrom-Json)
    $savedErrors = @(Get-Content -LiteralPath (Join-Path $MigrationLogs 'ArticleErrors.json') -Raw | ConvertFrom-Json)
    Assert-ArticlePreparation ($savedArticles.Count -eq 7 -and $savedErrors.Count -eq 2) 'A preparation failure prevented the recovery snapshots from being saved.'

    # Recover blank metadata, a deleted cache, and an empty cache on resume.
    # Ready articles must retain their HTML/timestamps and avoid duplicate uploads.
    $lock.Dispose(); $lock = $null
    [IO.File]::WriteAllText($MatchedArticles[2].FullPath, '<p>Recovered source</p>')
    [IO.File]::Delete($MatchedArticles[3].LocalContentPath)
    [IO.File]::WriteAllText($MatchedArticles[5].LocalContentPath, '')
    $readyTimestamp = $MatchedArticles[1].LocalContentPreparedAt
    $readyContent = Get-HuduArticleLocalContent $MatchedArticles[1]
    $domCalls.Clear()
    $ResumeFound = $true
    try { Set-StrictMode -Off; . $bodyPhase 3> (Join-Path $fixtureRoot 'resume-warnings.txt') 6>$null }
    finally { Set-StrictMode -Version Latest }
    Assert-ArticlePreparation (($domCalls -join ',') -eq '103,104,105,106') 'Resume did not limit preparation to missing/empty local content.'
    Assert-ArticlePreparation (@($MatchedArticles | Where-Object Imported -eq 'Content-Prepared-Locally').Count -eq 7) 'Resume left recoverable articles unprepared.'
    Assert-ArticlePreparation ($MatchedArticles[1].LocalContentPreparedAt -eq $readyTimestamp -and (Get-HuduArticleLocalContent $MatchedArticles[1]) -ceq $readyContent -and $uploads.Count -eq 1) 'Resume changed a prepared article or repeated its image upload.'
    Assert-ArticlePreparation (@($ArticleErrors).Count -eq 0 -and $MatchedArticles[2].HuduID -eq 103 -and $MatchedArticles[2].Company.HuduID -eq 1) 'Resume retained resolved errors or changed article/company identity.'

    $domCalls.Clear()
    try { Set-StrictMode -Off; . $bodyPhase 6>$null }
    finally { Set-StrictMode -Version Latest }
    Assert-ArticlePreparation ($domCalls.Count -eq 0 -and $jobs.Count -eq 2) 'A complete resume unnecessarily prepared article bodies.'
    [IO.File]::Delete($MatchedArticles[3].LocalContentPath)
    $ImportArticles = $false
    try { Set-StrictMode -Off; . $bodyPhase 6>$null }
    finally { Set-StrictMode -Version Latest }
    Assert-ArticlePreparation ($domCalls.Count -eq 0 -and $jobs.Count -eq 2) 'Disabled article imports still rebuilt local content.'
    Write-Output "Passed $checks article content preparation checks (offline; image/article failures and partial resume)."
} finally {
    if ($lock) { $lock.Dispose() }
    $resolvedFixtureRoot = [IO.Path]::GetFullPath($fixtureRoot)
    $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $resolvedFixtureRoot.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolvedFixtureRoot) -notmatch '^itglue-article-preparation-[a-f0-9]{32}$') {
        throw "Refusing fixture cleanup outside the expected temp directory: $resolvedFixtureRoot"
    }
    if ([IO.Directory]::Exists($resolvedFixtureRoot)) { [IO.Directory]::Delete($resolvedFixtureRoot, $true) }
}
