function Get-HuduEmbeddableUploadMediaKind {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $extension = [IO.Path]::GetExtension($Path).ToLowerInvariant()
    if ($extension -in @('.mp4', '.m4v', '.webm', '.ogv', '.mov', '.mkv')) { return 'Video' }
    if ($extension -in @('.mp3', '.m4a', '.aac', '.wav', '.ogg', '.oga', '.opus', '.flac', '.weba')) { return 'Audio' }

    return $null
}

function Get-HuduStandaloneArticleFileKind {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $mediaKind = Get-HuduEmbeddableUploadMediaKind -Path $Path
    if ($mediaKind) { return $mediaKind }

    $extension = [IO.Path]::GetExtension($Path).ToLowerInvariant()
    if ($extension -in @('.jpeg', '.jpg', '.png', '.gif', '.webp', '.heic')) { return 'Image' }

    return $null
}

function Normalize-HuduStandaloneArticleFileName {
    param(
        [AllowNull()]
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Name)) { return '' }

    $leafName = [IO.Path]::GetFileName($Name.Trim())
    try {
        $leafName = [System.Uri]::UnescapeDataString($leafName)
    } catch {
        # Keep the original leaf name if the export contains malformed escape sequences.
    }

    return $leafName.Trim().ToLowerInvariant()
}

function Get-ITGlueArticleStandaloneFile {
    param(
        [Parameter(Mandatory = $true)]
        $Article,

        [Parameter(Mandatory = $true)]
        [string]$ExportPath,

        [string[]]$Kinds = @('Audio', 'Video'),

        [switch]$RequireTitleFileName
    )

    $articleId = [string]($Article.ITGID ?? $Article.id)
    if ([string]::IsNullOrWhiteSpace($articleId)) { return $null }

    $articleAttachmentPath = Join-Path -Path $ExportPath -ChildPath "attachments\documents\$articleId"
    if (-not (Test-Path -LiteralPath $articleAttachmentPath -PathType Container)) { return $null }

    $candidateFiles = @(
        Get-ChildItem -LiteralPath $articleAttachmentPath -Recurse -File -ErrorAction SilentlyContinue |
            ForEach-Object {
                $kind = Get-HuduStandaloneArticleFileKind -Path $_.FullName
                if ($kind -and $Kinds -contains $kind) {
                    [pscustomobject]@{
                        File = $_
                        Kind = $kind
                    }
                }
            }
    )
    if ($candidateFiles.Count -lt 1) { return $null }

    $articleFileName = [IO.Path]::GetFileName([string]$Article.name)
    $normalizedArticleFileName = Normalize-HuduStandaloneArticleFileName -Name $articleFileName
    $matchingMediaFiles = if (-not [string]::IsNullOrWhiteSpace($articleFileName)) {
        @($candidateFiles | Where-Object {
            (Normalize-HuduStandaloneArticleFileName -Name $_.File.Name) -eq $normalizedArticleFileName
        })
    } else {
        @()
    }

    if ($RequireTitleFileName) {
        if ($matchingMediaFiles.Count -eq 1) { return $matchingMediaFiles[0] }
        if ($candidateFiles.Count -eq 1) {
            Write-Verbose "Using the only standalone attachment '$($candidateFiles[0].File.Name)' for image article '$($Article.name)' even though the exported filename does not exactly match the article title."
            return $candidateFiles[0]
        }
        return $null
    }

    if ($matchingMediaFiles.Count -eq 1) { return $matchingMediaFiles[0] }
    if ($candidateFiles.Count -eq 1) { return $candidateFiles[0] }

    return $null
}

function Get-ITGlueArticleStandaloneMediaFile {
    param(
        [Parameter(Mandatory = $true)]
        $Article,

        [Parameter(Mandatory = $true)]
        [string]$ExportPath
    )

    $standaloneFile = Get-ITGlueArticleStandaloneFile -Article $Article -ExportPath $ExportPath -Kinds @('Audio', 'Video')
    if ($standaloneFile) { return $standaloneFile.File }

    return $null
}

function ConvertTo-HuduMediaEmbedRelativeUrl {
    param(
        [AllowNull()]
        [string]$Url
    )

    if ([string]::IsNullOrWhiteSpace($Url)) { return $null }

    if (Get-Command -Name ConvertTo-HuduRelativeURL -ErrorAction SilentlyContinue) {
        return ConvertTo-HuduRelativeURL -Url $Url
    }

    $trimmedUrl = $Url.Trim()
    if ($trimmedUrl.StartsWith('/')) { return $trimmedUrl }

    if (-not [string]::IsNullOrWhiteSpace([string]$HuduBaseDomain)) {
        return [regex]::Replace(
            $trimmedUrl,
            "(?i)^$([regex]::Escape(([string]$HuduBaseDomain).TrimEnd('/')))(?=/|$)",
            ''
        )
    }

    return $trimmedUrl
}

function Get-HuduStandaloneObjectPropertyValue {
    param(
        [AllowNull()]
        [object]$Object,

        [Parameter(Mandatory = $true)]
        [string[]]$Names
    )

    if ($null -eq $Object) { return $null }

    if ($Object -is [System.Collections.IDictionary]) {
        foreach ($name in $Names) {
            if ($Object.Contains($name) -and $null -ne $Object[$name]) {
                return $Object[$name]
            }
        }
    }

    foreach ($name in $Names) {
        if ($null -ne $Object.PSObject.Properties[$name] -and $null -ne $Object.$name) {
            return $Object.$name
        }
    }

    return $null
}

function Get-HuduStandaloneFolderObject {
    param(
        [AllowNull()]
        [object]$Folder
    )

    if ($null -eq $Folder) { return $null }
    if ($Folder -is [System.Collections.IDictionary] -and $Folder.Contains('folder') -and $null -ne $Folder['folder']) {
        return $Folder['folder']
    }
    if ($null -ne $Folder.PSObject.Properties['folder'] -and $null -ne $Folder.folder) {
        return $Folder.folder
    }

    return $Folder
}

function Get-HuduStandaloneFolderId {
    param(
        [AllowNull()]
        [object]$Folder
    )

    return Get-HuduStandaloneObjectPropertyValue -Object (Get-HuduStandaloneFolderObject -Folder $Folder) -Names @('id', 'Id')
}

function Get-HuduStandaloneFolderParentId {
    param(
        [AllowNull()]
        [object]$Folder
    )

    return Get-HuduStandaloneObjectPropertyValue -Object (Get-HuduStandaloneFolderObject -Folder $Folder) -Names @('parent_folder_id', 'ParentFolderId', 'parentId')
}

function Get-HuduStandaloneFolderCompanyId {
    param(
        [AllowNull()]
        [object]$Folder
    )

    return Get-HuduStandaloneObjectPropertyValue -Object (Get-HuduStandaloneFolderObject -Folder $Folder) -Names @('company_id', 'CompanyId')
}

function Get-HuduStandaloneFolderType {
    param(
        [AllowNull()]
        [object]$Folder
    )

    return [string](Get-HuduStandaloneObjectPropertyValue -Object (Get-HuduStandaloneFolderObject -Folder $Folder) -Names @('folder_type', 'FolderType'))
}

function Test-HuduStandaloneSameFolderParent {
    param(
        [AllowNull()]
        [object]$A,

        [AllowNull()]
        [object]$B
    )

    $aIsRoot = $null -eq $A -or [string]$A -eq '' -or [string]$A -eq '0'
    $bIsRoot = $null -eq $B -or [string]$B -eq '' -or [string]$B -eq '0'

    if ($aIsRoot -or $bIsRoot) { return $aIsRoot -and $bIsRoot }

    return [string]$A -eq [string]$B
}

function Add-HuduStandalonePhotoFoldersToCache {
    param(
        [AllowNull()]
        [array]$Folders
    )

    if ($null -eq $script:StandaloneImageArticlePhotoFolders) {
        $script:StandaloneImageArticlePhotoFolders = @()
    }

    foreach ($folder in @($Folders)) {
        $folderObject = Get-HuduStandaloneFolderObject -Folder $folder
        if ($null -eq $folderObject) { continue }

        $folderId = Get-HuduStandaloneFolderId -Folder $folderObject
        if ($null -ne $folderId) {
            $existingIndex = -1
            for ($i = 0; $i -lt $script:StandaloneImageArticlePhotoFolders.Count; $i++) {
                $existingId = Get-HuduStandaloneFolderId -Folder $script:StandaloneImageArticlePhotoFolders[$i]
                if ([string]$existingId -eq [string]$folderId) {
                    $existingIndex = $i
                    break
                }
            }

            if ($existingIndex -ge 0) {
                $script:StandaloneImageArticlePhotoFolders[$existingIndex] = $folderObject
                continue
            }
        }

        $script:StandaloneImageArticlePhotoFolders += @($folderObject)
    }
}

function Get-HuduStandalonePhotoFoldersForCache {
    param(
        [AllowNull()]
        [object]$CompanyId
    )

    if (-not (Get-Command -Name Get-HuduFolders -ErrorAction SilentlyContinue)) { return @() }

    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($folderType in @('article', 'photo')) {
        try {
            $folders = if ($null -ne $CompanyId) {
                Get-HuduFolders -CompanyId ([int]$CompanyId) -folderType $folderType
            } else {
                Get-HuduFolders -folderType $folderType
            }

            foreach ($folder in @($folders)) { $results.Add($folder) }
        } catch {
            Write-Verbose "Could not load $folderType folders for standalone image photo conversion: $($_.Exception.Message)"
        }
    }

    if ($results.Count -lt 1) {
        try {
            $folders = if ($null -ne $CompanyId) {
                Get-HuduFolders -CompanyId ([int]$CompanyId)
            } else {
                Get-HuduFolders
            }

            foreach ($folder in @($folders)) { $results.Add($folder) }
        } catch {
            Write-Verbose "Could not load folders for standalone image photo conversion: $($_.Exception.Message)"
        }
    }

    return $results.ToArray()
}

function Initialize-HuduStandalonePhotoFolderCache {
    param(
        [AllowNull()]
        [object]$CompanyId
    )

    if ($null -eq $script:StandaloneImageArticlePhotoFolders) {
        $script:StandaloneImageArticlePhotoFolders = @()
    }
    if ($null -eq $script:StandaloneImageArticlePhotoFolderCacheKeys) {
        $script:StandaloneImageArticlePhotoFolderCacheKeys = @{}
    }

    $cacheKey = if ($null -ne $CompanyId) { "company:$CompanyId" } else { 'global' }
    if ($script:StandaloneImageArticlePhotoFolderCacheKeys.ContainsKey($cacheKey)) { return }

    Add-HuduStandalonePhotoFoldersToCache -Folders @(Get-HuduStandalonePhotoFoldersForCache -CompanyId $CompanyId)
    $script:StandaloneImageArticlePhotoFolderCacheKeys[$cacheKey] = $true
}

function Find-HuduStandaloneFolderInCache {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [AllowNull()]
        [object]$CompanyId,

        [AllowNull()]
        [object]$ParentFolderId,

        [string]$FolderType
    )

    $matches = @(
        @($script:StandaloneImageArticlePhotoFolders) |
            Where-Object {
                $folder = Get-HuduStandaloneFolderObject -Folder $_
                if ($null -eq $folder) {
                    $false
                } else {
                    $candidateParentId = Get-HuduStandaloneFolderParentId -Folder $folder
                    $candidateCompanyId = Get-HuduStandaloneFolderCompanyId -Folder $folder
                    $candidateType = Get-HuduStandaloneFolderType -Folder $folder

                    $folder.name -eq $Name -and
                    [string]$candidateCompanyId -eq [string]$CompanyId -and
                    (Test-HuduStandaloneSameFolderParent -A $candidateParentId -B $ParentFolderId) -and
                    (
                        [string]::IsNullOrWhiteSpace($FolderType) -or
                        $candidateType -ieq $FolderType
                    )
                }
            }
    )

    if ($matches.Count -gt 1) {
        Write-Warning "Multiple $($FolderType ?? 'matching') folder matches found for '$Name' under parent '$($ParentFolderId ?? 'ROOT')'. Using first match."
    }

    return $matches | Select-Object -First 1
}

function Resolve-HuduStandalonePhotoFolderName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [AllowNull()]
        [object]$CompanyId,

        [AllowNull()]
        [object]$ParentFolderId
    )

    $existingPhoto = Find-HuduStandaloneFolderInCache -Name $Name -CompanyId $CompanyId -ParentFolderId $ParentFolderId -FolderType 'photo'
    if ($existingPhoto) {
        return [pscustomobject]@{
            Name                = $Name
            ExistingPhotoFolder = $existingPhoto
        }
    }

    $sameNameCollision = Find-HuduStandaloneFolderInCache -Name $Name -CompanyId $CompanyId -ParentFolderId $ParentFolderId
    if (-not $sameNameCollision) {
        return [pscustomobject]@{
            Name                = $Name
            ExistingPhotoFolder = $null
        }
    }

    for ($i = 0; $i -lt 100; $i++) {
        $candidateName = if ($i -eq 0) { "$Name (Photos)" } else { "$Name (Photos) $($i + 1)" }
        $candidatePhoto = Find-HuduStandaloneFolderInCache -Name $candidateName -CompanyId $CompanyId -ParentFolderId $ParentFolderId -FolderType 'photo'
        if ($candidatePhoto) {
            return [pscustomobject]@{
                Name                = $candidateName
                ExistingPhotoFolder = $candidatePhoto
            }
        }

        $candidateCollision = Find-HuduStandaloneFolderInCache -Name $candidateName -CompanyId $CompanyId -ParentFolderId $ParentFolderId
        if (-not $candidateCollision) {
            return [pscustomobject]@{
                Name                = $candidateName
                ExistingPhotoFolder = $null
            }
        }
    }

    throw "Could not find an available photo folder name for '$Name'."
}

function Get-HuduStandaloneArticleFolderChain {
    param(
        [Parameter(Mandatory = $true)]
        $Article
    )

    $folderId = Get-HuduStandaloneObjectPropertyValue -Object $Article.HuduObject -Names @('folder_id', 'FolderId')
    if ($null -eq $folderId) {
        $folderId = Get-HuduStandaloneObjectPropertyValue -Object $Article -Names @('folder_id', 'FolderId', 'article_folder_id')
    }
    if ($null -eq $folderId -or [string]::IsNullOrWhiteSpace([string]$folderId) -or [string]$folderId -eq '0') {
        return @()
    }

    $folderById = @{}
    foreach ($folder in @($script:StandaloneImageArticlePhotoFolders)) {
        $folderObject = Get-HuduStandaloneFolderObject -Folder $folder
        $id = Get-HuduStandaloneFolderId -Folder $folderObject
        if ($null -ne $folderObject -and $null -ne $id) {
            $folderById[[string]$id] = $folderObject
        }
    }

    $chain = @()
    $seen = @{}
    $currentId = [string]$folderId
    while (-not [string]::IsNullOrWhiteSpace($currentId) -and $folderById.ContainsKey($currentId)) {
        if ($seen.ContainsKey($currentId)) {
            Write-Warning "Folder parent loop detected at folder ID $currentId."
            break
        }

        $seen[$currentId] = $true
        $folder = $folderById[$currentId]
        $chain = @($folder) + $chain
        $currentId = [string](Get-HuduStandaloneFolderParentId -Folder $folder)
    }

    return $chain
}

function Resolve-HuduStandaloneImagePhotoFolder {
    param(
        [Parameter(Mandatory = $true)]
        $Article,

        [Parameter(Mandatory = $true)]
        [int]$CompanyId
    )

    if (-not (Get-Command -Name Get-HuduFolders -ErrorAction SilentlyContinue) -or -not (Get-Command -Name New-HuduFolder -ErrorAction SilentlyContinue)) {
        return $null
    }

    Initialize-HuduStandalonePhotoFolderCache -CompanyId $CompanyId
    Initialize-HuduStandalonePhotoFolderCache -CompanyId $null

    $chain = @(Get-HuduStandaloneArticleFolderChain -Article $Article)
    if ($chain.Count -lt 1) { return $null }

    $photoParentId = $null
    $photoPathSegments = [System.Collections.Generic.List[string]]::new()

    foreach ($articleFolder in $chain) {
        $articleFolderObject = Get-HuduStandaloneFolderObject -Folder $articleFolder
        if ($null -eq $articleFolderObject -or [string]::IsNullOrWhiteSpace([string]$articleFolderObject.name)) {
            continue
        }

        $nameResolution = Resolve-HuduStandalonePhotoFolderName -Name ([string]$articleFolderObject.name) -CompanyId $CompanyId -ParentFolderId $photoParentId
        $photoFolderName = $nameResolution.Name

        if ($nameResolution.ExistingPhotoFolder) {
            $existingId = Get-HuduStandaloneFolderId -Folder $nameResolution.ExistingPhotoFolder
            if ($null -eq $existingId) { return $null }
            $photoParentId = [int]$existingId
            $photoPathSegments.Add([string](Get-HuduStandaloneFolderObject -Folder $nameResolution.ExistingPhotoFolder).name)
            continue
        }

        $createParams = @{
            Name       = $photoFolderName
            folderType = 'photo'
            CompanyId  = $CompanyId
        }
        if ($photoParentId -is [int]) {
            $createParams.ParentFolderId = [int]$photoParentId
        }

        try {
            $created = New-HuduFolder @createParams
        } catch {
            Write-Warning "Could not create photo folder '$photoFolderName' for standalone image article '$($Article.name)': $($_.Exception.Message)"
            return $null
        }

        $createdFolder = Get-HuduStandaloneFolderObject -Folder $created
        $createdId = Get-HuduStandaloneFolderId -Folder $createdFolder
        if ($null -eq $createdId) {
            $createdData = Get-HuduStandaloneObjectPropertyValue -Object $created -Names @('data')
            if ($createdData) {
                $createdFolder = Get-HuduStandaloneFolderObject -Folder (@($createdData) | Select-Object -First 1)
                $createdId = Get-HuduStandaloneFolderId -Folder $createdFolder
            }
        }
        if ($null -eq $createdId) {
            Write-Warning "New-HuduFolder returned no folder ID for standalone image article photo folder '$photoFolderName'."
            return $null
        }

        $photoParentId = [int]$createdId
        $photoPathSegments.Add([string]$photoFolderName)
        Add-HuduStandalonePhotoFoldersToCache -Folders @($createdFolder)
    }

    if ($photoParentId -isnot [int]) { return $null }

    return [pscustomobject]@{
        FolderId = [int]$photoParentId
        Path     = ($photoPathSegments -join '/')
    }
}

function Resolve-HuduStandaloneImagePhotoCompanyId {
    param(
        [Parameter(Mandatory = $true)]
        $Article,

        [AllowNull()]
        $MatchedCompanies
    )

    $articleCompanyId = [int]($Article.Company.HuduID ?? $Article.HuduObject.company_id ?? $Article.company_id ?? 0)
    if ($articleCompanyId -gt 0) { return $articleCompanyId }

    $primaryCompanyMatches = @(
        @($MatchedCompanies) | Where-Object {
            $true -eq $_.InternalCompany -and [int]($_.HuduID ?? $_.HuduCompanyObject.id ?? 0) -gt 0
        }
    )

    if ($primaryCompanyMatches.Count -eq 1) {
        return [int]($primaryCompanyMatches[0].HuduID ?? $primaryCompanyMatches[0].HuduCompanyObject.id)
    }

    return 1
}

function New-HuduArticleStandaloneMediaEmbed {
    param(
        [Parameter(Mandatory = $true)]
        $Article,

        [Parameter(Mandatory = $true)]
        [string]$ExportPath
    )

    $mediaFile = Get-ITGlueArticleStandaloneMediaFile -Article $Article -ExportPath $ExportPath
    if (-not $mediaFile) { return $null }

    $articleId = [int]($Article.HuduID ?? $Article.id ?? 0)
    if ($articleId -lt 1) { return $null }

    $mediaKind = Get-HuduEmbeddableUploadMediaKind -Path $mediaFile.FullName
    if ([string]::IsNullOrWhiteSpace($mediaKind)) { return $null }

    if ($MaxHuduUploadBytes -and $mediaFile.Length -gt $MaxHuduUploadBytes) {
        Write-Warning "Skipping standalone media embed for '$($Article.name)' because '$($mediaFile.Name)' is larger than the Hudu upload size limit."
        return $null
    }

    $upload = if (Get-Command -Name Find-HuduExistingUpload -ErrorAction SilentlyContinue) {
        Find-HuduExistingUpload -FileName $mediaFile.Name -UploadableId $articleId -UploadableType 'Article'
    } else {
        $null
    }

    if (-not $upload -and (Get-Command -Name Add-HuduUploadOnce -ErrorAction SilentlyContinue)) {
        $uploadResult = Add-HuduUploadOnce -FilePath $mediaFile.FullName -UploadableId $articleId -UploadableType 'Article'
        $upload = $uploadResult.Upload
    }

    if (-not $upload) { return $null }

    $uploadUrl = if (Get-Command -Name Resolve-HuduUploadUrl -ErrorAction SilentlyContinue) {
        Resolve-HuduUploadUrl -Upload $upload
    } else {
        $upload.url ?? $upload.file_url ?? $upload.download_url
    }

    $relativeUrl = ConvertTo-HuduMediaEmbedRelativeUrl -Url $uploadUrl
    if ([string]::IsNullOrWhiteSpace($relativeUrl)) { return $null }

    $encodedTitle = [System.Net.WebUtility]::HtmlEncode([string]($Article.name ?? $mediaFile.Name))
    $encodedUrl = [System.Net.WebUtility]::HtmlEncode($relativeUrl)

    if ($mediaKind -eq 'Video') {
        return [pscustomobject]@{
            Content = "<video src='$encodedUrl' controls='controls' width='640'>$encodedTitle</video>"
            File    = $mediaFile
            Url     = $relativeUrl
            Kind    = $mediaKind
        }
    }

    return [pscustomobject]@{
        Content = "<audio src='$encodedUrl' controls='controls'>$encodedTitle</audio>"
        File    = $mediaFile
        Url     = $relativeUrl
        Kind    = $mediaKind
    }
}

function New-HuduArticleStandaloneImagePhoto {
    param(
        [Parameter(Mandatory = $true)]
        $Article,

        [Parameter(Mandatory = $true)]
        [string]$ExportPath,

        [AllowNull()]
        $MatchedCompanies
    )

    $standaloneFile = Get-ITGlueArticleStandaloneFile -Article $Article -ExportPath $ExportPath -Kinds @('Image') -RequireTitleFileName
    if (-not $standaloneFile) {
        $articleIdForDiagnostics = [string]($Article.ITGID ?? $Article.id)
        $articleAttachmentPath = Join-Path -Path $ExportPath -ChildPath "attachments\documents\$articleIdForDiagnostics"
        if (Test-Path -LiteralPath $articleAttachmentPath -PathType Container) {
            $imageCandidates = @(
                Get-ChildItem -LiteralPath $articleAttachmentPath -Recurse -File -ErrorAction SilentlyContinue |
                    Where-Object { (Get-HuduStandaloneArticleFileKind -Path $_.FullName) -eq 'Image' }
            )
            if ($imageCandidates.Count -gt 1) {
                Write-Warning "Skipping standalone image photo conversion for '$($Article.name)' because multiple image attachments were found and none uniquely matched the article title: $((@($imageCandidates | Select-Object -First 10 -ExpandProperty Name)) -join ', ')"
            } else {
                Write-Warning "Skipping standalone image photo conversion for '$($Article.name)' because no supported image attachment matched the article title."
            }
        } else {
            Write-Warning "Skipping standalone image photo conversion for '$($Article.name)' because attachment folder '$articleAttachmentPath' was not found."
        }
        return $null
    }

    if (-not (Get-Command -Name New-HuduPhoto -ErrorAction SilentlyContinue)) {
        Write-Warning "Skipping standalone image photo conversion for '$($Article.name)' because New-HuduPhoto is unavailable."
        return $null
    }

    $imageFile = $standaloneFile.File
    $articleId = [int]($Article.HuduID ?? $Article.id ?? 0)
    if ($articleId -lt 1) { return $null }

    if ($MaxHuduUploadBytes -and $imageFile.Length -gt $MaxHuduUploadBytes) {
        Write-Warning "Skipping standalone image photo conversion for '$($Article.name)' because '$($imageFile.Name)' is larger than the Hudu upload size limit."
        return $null
    }

    $companyId = Resolve-HuduStandaloneImagePhotoCompanyId -Article $Article -MatchedCompanies $MatchedCompanies
    $photoFolder = Resolve-HuduStandaloneImagePhotoFolder -Article $Article -CompanyId $companyId
    $photoParams = @{
        Path           = $imageFile.FullName
        Caption        = [string]($Article.name ?? $imageFile.Name)
        Photoable_Type = 'Company'
        Photoable_Id   = $companyId
        CompanyId      = $companyId
    }

    if ($photoFolder -and $photoFolder.FolderId -gt 0) {
        $photoParams.FolderId = [int]$photoFolder.FolderId
    }

    $photoResponse = New-HuduPhoto @photoParams
    $photo = $photoResponse.photo ?? $photoResponse
    if (-not $photo) { return $null }

    return [pscustomobject]@{
        Kind                   = 'Image'
        File                   = $imageFile
        Photo                  = $photo
        PhotoId                = $photo.id
        ArticleId              = $articleId
        PhotoableType          = 'Company'
        PhotoableId            = $companyId
        FolderId               = $photoFolder.FolderId
        FolderPath             = $photoFolder.Path
        ArchiveOriginalArticle = $true
        Content                = "Converted standalone image article to Hudu photo: $($imageFile.Name)"
    }
}
