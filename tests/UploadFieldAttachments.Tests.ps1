#requires -Version 7.2
# Offline export fixtures and mocked Hudu uploads; no API credentials or network.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$resolverPath = (Resolve-Path "$PSScriptRoot/../Public/Add-UploadFieldAttachments.ps1").Path
$repoRoot = Split-Path $PSScriptRoot -Parent
$tokens = $null; $parseErrors = $null
$entryAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'Add-HuduAttachmentsViaAPI.ps1'), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw 'Attachment entry point failed to parse.' }
$entryBlock = @($entryAst.EndBlock.Statements | Where-Object { $_.Extent.Text -like '*Public/Add-UploadFieldAttachments.ps1*' })
if ($entryBlock.Count -ne 1) { throw 'Cannot identify the real upload-field entry-point block.' }
$entryBlockCode = $entryBlock[0].Extent.Text.Replace('$PSScriptRoot', "'$($repoRoot.Replace("'", "''"))'")
$checks = 0
function Assert-Upload {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    $script:checks++
}

$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([char[]]@('\', '/'))
$fixtureRoot = Join-Path $tempBase "itglue-uploads-$([guid]::NewGuid().ToString('N'))"
$exportRoot = Join-Path $fixtureRoot 'export [photos]'
$null = New-Item -ItemType Directory -Path $exportRoot -Force
function New-ExportFile {
    param([string]$RelativePath, [long]$Size = 10)
    $path = Join-Path $exportRoot $RelativePath
    $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
    $stream = [IO.File]::Open($path, [IO.FileMode]::Create)
    try { $stream.SetLength($Size) } finally { $stream.Dispose() }
    return $path
}
function New-UploadValue {
    param([string]$Name, [string]$Id, $Size = $null, [string]$Type = 'photos', [string]$Record = '3637018')
    $value = @{name=$Name; url="https://example.invalid/2770433/assets/69396-$Type/records/$Record/files/${Id}?download=1"}
    if ($null -ne $Size) { $value.size = $Size }
    return [pscustomobject]$value
}
function New-UploadAsset {
    param($Files, [int]$HuduId = 42, [string]$Record = '3637018', [string]$Field = 'upload-photos')
    return [pscustomobject]@{
        ITGID = $Record
        HuduID = $HuduId
        ITGObject = [pscustomobject]@{
            attributes = [pscustomobject]@{traits=[pscustomobject]@{
                $Field = $Files
                notes = 'Ordinary text'
                tags = @('one', 'two')
                empty = $null
            }}
        }
    }
}
function Invoke-UploadFixture {
    param([array]$Assets, [long]$Limit = 100MB, [switch]$UseOnce, [switch]$ThroughEntryPoint, [string[]]$ExistingNames = @(), [hashtable]$Failures = @{})
    $ITGlueExportPath = $exportRoot
    $MatchedAssets = $Assets
    $MaxHuduUploadBytes = $Limit
    $uploadCalls = [System.Collections.Generic.List[object]]::new()
    $onceCalls = [System.Collections.Generic.List[string]]::new()
    $manualActions = [System.Collections.Generic.List[string]]::new()
    function New-HuduUpload {
        [CmdletBinding()]
        param($uploadable_id, [string]$filePath, $uploadable_type)
        $leaf = [IO.Path]::GetFileName($filePath)
        $uploadCalls.Add([pscustomobject]@{Id=$uploadable_id; Path=$filePath; Type=$uploadable_type})
        switch ($Failures[$leaf]) {
            'throw' { throw 'Simulated upload failure' }
            'error' { Write-Error 'Simulated non-terminating API error'; return }
            'null' { return $null }
            'empty-wrapper' { return @{upload=$null} }
            'raw' { return [pscustomobject]@{id=$uploadCalls.Count; url="https://hudu.invalid/uploads/$leaf"} }
        }
        return @{upload=[pscustomobject]@{id=$uploadCalls.Count; url="https://hudu.invalid/uploads/$leaf"}}
    }
    if ($UseOnce) {
        function Add-HuduUploadOnce {
            [CmdletBinding()]
            param($uploadable_id, [string]$filePath, $uploadable_type)
            $leaf = [IO.Path]::GetFileName($filePath)
            $onceCalls.Add($leaf)
            if ($leaf -in $ExistingNames) {
                return @{Upload=@{id=9000; url="https://hudu.invalid/uploads/$leaf"}; Status='SKIPPED: Already uploaded'}
            }
            $response = New-HuduUpload @PSBoundParameters
            return @{Upload=$response.upload; Status='Uploaded Successfully'}
        }
    }
    function Add-OversizedAttachmentManualAction {
        param($FoundFile, $FoundAsset, $UploadType, $FieldName)
        $manualActions.Add($FoundFile.FullName)
    }
    $script:AttachmentUrlMap = @{}
    if ($ThroughEntryPoint) {
        foreach ($functionName in @('Add-AttachmentUrlMapEntry', 'Resolve-HuduUploadUrl')) {
            $definition = $entryAst.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName}, $true)
            . ([scriptblock]::Create($definition.Extent.Text))
        }
        $UploadFieldsArePresent = $false
        # The existing URL-map helpers read optional response properties using
        # the migration's default (non-strict) PowerShell member access.
        try {
            Set-StrictMode -Off
            . ([scriptblock]::Create($entryBlockCode)) 3>$null 6>$null
        } finally { Set-StrictMode -Version Latest }
    } else {
        . $resolverPath 3>$null 6>$null
    }
    return @{
        Matched = $MatchedUploadFields
        Unresolved = $UnresolvedUploadFields
        Calls = $uploadCalls.ToArray()
        OnceCalls = $onceCalls.ToArray()
        ManualActions = $manualActions.ToArray()
        UrlMap = @{} + $script:AttachmentUrlMap
    }
}

try {
    # The reported four-photo array and its actual exported ID-name format.
    $photos = @'
[
  {"name":"IMG_1070.JPG","size":2618869,"url":"https://example.invalid/2770433/assets/69396-photos/records/3637018/files/40478374"},
  {"name":"IMG_1071.JPG","size":2819580,"url":"https://example.invalid/2770433/assets/69396-photos/records/3637018/files/40478375"},
  {"name":"IMG_1072.JPG","size":994484,"url":"https://example.invalid/2770433/assets/69396-photos/records/3637018/files/40478376"},
  {"name":"IMG_1073.JPG","size":3983201,"url":"https://example.invalid/2770433/assets/69396-photos/records/3637018/files/40478377"}
]
'@ | ConvertFrom-Json
    $photoPaths = foreach ($photo in $photos) {
        $id = ($photo.url -split '/')[-1]
        New-ExportFile "photos-upload-photos/$id-$($photo.name)" $photo.size
    }
    $null = New-ExportFile 'photos-upload-photos/40478330-IMG_1075.JPG' 123
    $asset = New-UploadAsset -Files $photos
    $result = Invoke-UploadFixture @($asset)
    Assert-Upload ($result.Matched.Count -eq 4 -and $result.Unresolved.Count -eq 0 -and $result.Calls.Count -eq 4) 'The reported four-photo array did not upload every photo.'
    Assert-Upload (@($result.Calls | Where-Object { $_.Path -notin $photoPaths -or $_.Id -ne 42 -or $_.Type -ne 'Asset' }).Count -eq 0) 'A photo resolved to the wrong file or Hudu asset.'
    Assert-Upload (@($result.Matched.Values.ITGFileUrl | Select-Object -Unique).Count -eq 4) 'Per-file logs lost URLs needed by attachment link replacement.'
    Assert-Upload (@($result.Matched.Values.FieldIndex | Select-Object -Unique).Count -eq 4) 'Multiple files overwrote one another in the field log.'
    Push-Location $tempBase
    try { $result = Invoke-UploadFixture @($asset) -ThroughEntryPoint }
    finally { Pop-Location }
    Assert-Upload ($result.Matched.Count -eq 4 -and $result.Calls.Count -eq 4) 'The real entry point skipped saved upload fields when the preparation flag was false, or depended on the working directory.'
    Assert-Upload ($result.UrlMap.Count -eq 4 -and @($photos | Where-Object { -not $result.UrlMap.ContainsKey($_.url) -or $result.UrlMap[$_.url] -notlike 'https://hudu.invalid/uploads/*' }).Count -eq 0) 'The real entry point did not map every original photo URL to its Hudu upload.'

    # UUID originals, rewritten export names, underscore and ID-only filenames.
    # A same-name file in the expected field must not beat a global file-ID match.
    $uuid = '98d7a0bf-a49f-4953-bc1a-c5acc6f6a690.jpg'
    $renamedPath = New-ExportFile 'other-uploads/1739104373_rewritten-photo.jpg' 79180
    $idOnlyPath = New-ExportFile 'photos-upload-photos/1739104381.jpeg' 97265
    $null = New-ExportFile "photos-upload-photos/$uuid" 79180
    $uuidValues = @(
        New-UploadValue $uuid '1739104373' 79180 -Record '68880853'
        New-UploadValue 'aa6e42ea-b5c8-4e41-92ac-defd486240af.jpg' '1739104381' 97265 -Record '68880853'
    )
    $result = Invoke-UploadFixture @((New-UploadAsset $uuidValues -Record '68880853'))
    Assert-Upload ($result.Matched.Count -eq 2 -and $renamedPath -in $result.Calls.Path -and $idOnlyPath -in $result.Calls.Path) 'File IDs failed to resolve UUID uploads with rewritten names.'

    # Legacy singleton objects and nested per-record attachment folders.
    $normalizedPath = New-ExportFile 'attachments/photos/3637018/nested [photos]/resume-and-rack-20261029163000.JPG' 15
    $null = New-ExportFile 'photos-upload-photos/Resume & Rack.jpg' 15
    $result = Invoke-UploadFixture @((New-UploadAsset (New-UploadValue 'Résumé & Rack.jpg' '700001')))
    Assert-Upload ($result.Matched.Count -eq 1 -and $result.Calls[0].Path -eq $normalizedPath) 'A singleton upload failed normalization or nested record-folder resolution.'
    $encodedPath = New-ExportFile 'photos-upload-photos/Encoded Photo [1].jpg'
    $result = Invoke-UploadFixture @((New-UploadAsset (New-UploadValue 'Encoded%20Photo%20%5B1%5D.jpg' '700002')))
    Assert-Upload ($result.Matched.Count -eq 1 -and $result.Calls[0].Path -eq $encodedPath) 'URL-encoded original names failed to match literal export paths.'

    # Hashtable traits and attachment values, multiple fields, and a one-item array.
    $firstValue = New-UploadValue 'Dictionary Photo.jpg' '710001'
    $secondValue = New-UploadValue 'Diagram.png' '710002'
    $dictionaryAsset = @{
        HuduID=43; ITGID='3637018'; ITGObject=@{attributes=@{traits=@{
            'upload-photos'=@(@{name=$firstValue.name; url=$firstValue.url})
            'upload-diagrams'=@{name=$secondValue.name; url=$secondValue.url}
            'empty-field'=@(); 'other-value'=@{id=1}
        }}}
    }
    $null = New-ExportFile 'photos-upload-photos/710001-Dictionary Photo.jpg'
    $null = New-ExportFile 'photos-upload-diagrams/710002-Diagram.png'
    $result = Invoke-UploadFixture @($dictionaryAsset)
    Assert-Upload ($result.Matched.Count -eq 2 -and @($result.Matched.Values.FieldName | Select-Object -Unique).Count -eq 2) 'Dictionary traits, one-item arrays, or multiple upload fields failed.'

    # Layout slugs contain hyphens; field-specific folders outrank other fields/types.
    $hyphenPath = New-ExportFile 'network-devices-upload-photos/Shared rack.jpg' 20
    $null = New-ExportFile 'network-devices-upload-diagrams/Shared rack.jpg' 20
    $null = New-ExportFile 'network-upload-photos/Shared rack.jpg' 20
    $result = Invoke-UploadFixture @((New-UploadAsset (New-UploadValue 'Shared rack.jpg' '720001' 20 -Type 'network-devices')))
    Assert-Upload ($result.Matched.Count -eq 1 -and $result.Calls[0].Path -eq $hyphenPath) 'A hyphenated layout slug or field folder was confused with another export folder.'
    $typePath = New-ExportFile 'network-devices-upload-diagrams/Type fallback.jpg' 20
    $null = New-ExportFile 'network-upload-photos/Type fallback.jpg' 20
    $result = Invoke-UploadFixture @((New-UploadAsset (New-UploadValue 'Type fallback.jpg' '720002' 20 -Type 'network-devices') -Field 'upload-other'))
    Assert-Upload ($result.Matched.Count -eq 1 -and $result.Calls[0].Path -eq $typePath) 'Layout-wide fallback split a hyphenated type name.'

    # Size breaks filename ties; tied candidates remain unresolved with diagnostics.
    $null = New-ExportFile 'photos-upload-photos/site-a/Duplicate.jpg' 25
    $sizePath = New-ExportFile 'photos-upload-photos/site-b/Duplicate.jpg' 26
    $result = Invoke-UploadFixture @((New-UploadAsset (New-UploadValue 'Duplicate.jpg' '730001' 26)))
    Assert-Upload ($result.Matched.Count -eq 1 -and $result.Calls[0].Path -eq $sizePath) 'Expected byte size did not disambiguate duplicate filenames.'
    $null = New-ExportFile 'photos-upload-photos/site-a/Ambiguous.jpg' 30
    $null = New-ExportFile 'photos-upload-photos/site-b/Ambiguous.jpg' 30
    $result = Invoke-UploadFixture @((New-UploadAsset (New-UploadValue 'Ambiguous.jpg' '730002' 30)))
    $unresolved = @($result.Unresolved.Values)[0]
    Assert-Upload ($result.Calls.Count -eq 0 -and $result.Unresolved.Count -eq 1 -and $unresolved.CandidatePaths.Count -eq 2) 'An ambiguous name match uploaded an arbitrary file or lost candidate paths.'
    $null = New-ExportFile 'photos-upload-photos/site-a/730003-Renamed.jpg' 30
    $null = New-ExportFile 'photos-upload-photos/site-b/730003-Renamed.jpg' 30
    $result = Invoke-UploadFixture @((New-UploadAsset (New-UploadValue 'Original.jpg' '730003' 30)))
    Assert-Upload ($result.Calls.Count -eq 0 -and $result.Unresolved.Count -eq 1) 'An ambiguous file-ID match uploaded an arbitrary file.'

    # Similar names, wrong IDs, and different extensions are insufficient evidence.
    $null = New-ExportFile 'photos-upload-photos/999001-Wrong ID.jpg' 40
    $null = New-ExportFile 'photos-upload-photos/Partially matched name.jpg' 40
    $null = New-ExportFile 'photos-upload-photos/Different format.png' 40
    $rejected = @(
        New-UploadValue 'Wrong ID.jpg' '740001' 40
        New-UploadValue 'matched name.jpg' '740002' 40
        New-UploadValue 'Different format.jpg' '740003' 40
        New-UploadValue 'Missing.jpg' '740004'
    )
    $result = Invoke-UploadFixture @((New-UploadAsset $rejected))
    Assert-Upload ($result.Calls.Count -eq 0 -and $result.Unresolved.Count -eq 4) 'Weak name matches were accepted or unresolved array items overwrote one another.'
    Assert-Upload (@($result.Unresolved.Values | Where-Object { $_.Problem -ne 'No matching exported file' }).Count -eq 0) 'Missing-file diagnostic reasons were lost.'

    # Literal original numeric prefixes and Unicode names must remain usable.
    $numericPath = New-ExportFile 'photos-upload-photos/20240101-report.pdf'
    $unicodePath = New-ExportFile 'photos-upload-photos/写真-ラック.jpg'
    $result = Invoke-UploadFixture @((New-UploadAsset @(
        New-UploadValue '20240101-report.pdf' '750001'
        New-UploadValue '写真 ラック.jpg' '750002'
    )))
    Assert-Upload ($result.Matched.Count -eq 2 -and $numericPath -in $result.Calls.Path -and $unicodePath -in $result.Calls.Path) 'Numeric original names or non-Latin normalized names failed to match.'

    # One upload failure must not stop the remaining photos, even for Write-Error.
    $failures = @{'40478374-IMG_1070.JPG'='throw'; '40478375-IMG_1071.JPG'='error'; '40478376-IMG_1072.JPG'='null'}
    $result = Invoke-UploadFixture @($asset) -Failures $failures
    Assert-Upload ($result.Calls.Count -eq 4 -and $result.Matched.Count -eq 1 -and $result.Unresolved.Count -eq 3) 'An upload error stopped the array or was recorded as success.'
    Assert-Upload (@($result.Unresolved.Values | Where-Object { -not $_.FilePath -or $_.MatchScore -le 0 -or $_.Problem -notlike 'Upload failed:*' }).Count -eq 0) 'Failed uploads lost resolved paths, match scores, or failure reasons.'
    $result = Invoke-UploadFixture @($asset) -UseOnce -Failures $failures
    Assert-Upload ($result.OnceCalls.Count -eq 4 -and $result.Matched.Count -eq 1 -and $result.Unresolved.Count -eq 3) 'Errors from the idempotency helper stopped subsequent photos or were marked successful.'
    $result = Invoke-UploadFixture @($asset) -Failures @{'40478374-IMG_1070.JPG'='empty-wrapper'; '40478375-IMG_1071.JPG'='null'; '40478376-IMG_1072.JPG'='raw'}
    Assert-Upload ($result.Matched.Count -eq 2 -and $result.Unresolved.Count -eq 2) 'Empty upload responses were treated as success or raw upload objects were rejected.'

    # Every resolved item still goes through the existing idempotency helper.
    $result = Invoke-UploadFixture @($asset) -UseOnce -ExistingNames @('40478374-IMG_1070.JPG', '40478375-IMG_1071.JPG')
    Assert-Upload ($result.OnceCalls.Count -eq 4 -and $result.Calls.Count -eq 2 -and $result.Matched.Count -eq 4) 'The array path bypassed existing-upload checks or lost already-uploaded results.'
    Assert-Upload (@($result.Matched.Values | Where-Object UploadStatus -eq 'SKIPPED: Already uploaded').Count -eq 2) 'Idempotency status was lost from per-file results.'

    $large = @(
        New-UploadValue 'Large A.jpg' '760001' 21
        New-UploadValue 'Large B.jpg' '760002' 22
        New-UploadValue 'Small.jpg' '760003' 5
    )
    $null = New-ExportFile 'photos-upload-photos/760001-Large A.jpg' 21
    $null = New-ExportFile 'photos-upload-photos/760002-Large B.jpg' 22
    $null = New-ExportFile 'photos-upload-photos/760003-Small.jpg' 5
    $result = Invoke-UploadFixture @((New-UploadAsset $large)) -Limit 20
    Assert-Upload ($result.Matched.Count -eq 1 -and $result.Unresolved.Count -eq 2 -and $result.ManualActions.Count -eq 2 -and $result.Calls.Count -eq 1) 'Oversized photos were uploaded, lost manual actions, or prevented later small uploads.'
    $result = Invoke-UploadFixture @((New-UploadAsset @()), (New-UploadAsset $photos -HuduId 0))
    Assert-Upload ($result.Matched.Count -eq 0 -and $result.Unresolved.Count -eq 0 -and $result.Calls.Count -eq 0) 'Empty upload arrays or assets without a Hudu ID were processed.'

    Write-Output "Passed $checks upload-field attachment checks (offline)."
} finally {
    $cleanupPath = [IO.Path]::GetFullPath($fixtureRoot)
    if (-not $cleanupPath.StartsWith("$tempBase$([IO.Path]::DirectorySeparatorChar)", [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($cleanupPath) -notmatch '^itglue-uploads-[a-f0-9]{32}$') {
        throw "Refusing cleanup outside the test fixture directory: $cleanupPath"
    }
    Remove-Item -LiteralPath $cleanupPath -Recurse -Force
}
