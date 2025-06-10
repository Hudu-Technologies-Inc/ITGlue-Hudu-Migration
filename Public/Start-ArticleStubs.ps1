if ($ImportArticles -eq $true) {
    if ($GlobalKBFolder -in ('y','yes','ye')) {
        if (-not ($GlobalKBFolder = Get-HuduFolders -name $InternalCompany)) {
            $GlobalKBFolder = (New-HuduFolder -Name $InternalCompany).folder
        }
    } 
else {
    $GlobalKBFolder = $null
}

    $ITGDocuments = Import-CSV -Path (Join-Path -path $ITGLueExportPath -ChildPath "documents.csv")
    [string]$ITGDocumentsPath = Join-Path -path $ITGLueExportPath -ChildPath "Documents"
    $files = Get-ChildItem -Path $ITGDocumentsPath -recurse
    # First lets find each article in the file system and then create blank stubs for them all so we can match relations later
    $MatchedArticles = Foreach ($doc in $ITGDocuments) {
        Write-Host "Starting $($doc.name)" -ForegroundColor Green
        $dir = $files | Where-Object { $_.PSIsContainer -eq $true -and $_.Name -match $doc.locator }
        $RelativePath = ($dir.FullName).Substring($ITGDocumentsPath.Length)
        $folders = $RelativePath -split '\\'
        $FilenameFromFolder = ($folders[$folders.count - 1] -split ' ', 2)[1]
        $Filename = $FilenameFromFolder
        $pathtest = Test-Path -LiteralPath "$($dir.Fullname)\$($filename).html"
        if ($pathtest -eq $false) {
            $filename = $doc.name
            $pathtest = Test-Path -LiteralPath "$($dir.Fullname)\$($filename).html"
            if ($pathtest -eq $false) {
                $filename = $FilenameFromFolder -replace '_', '$1,$2'
                $pathtest = Test-Path -LiteralPath "$($dir.Fullname)\$($filename).html"
                if ($pathtest -eq $false) {
                    Write-Host "Not Found $($dir.Fullname)\$($filename).html this article will need to be migrated manually" -foregroundcolor red
                    continue
                }
            }

        }
        $company = $MatchedCompanies | where-object -filter { $_.CompanyName -eq $doc.organization }
        if (($company | Measure-Object).count -eq 1) {
            $art_folder_id = $null
            if ($company.InternalCompany -eq $false) {
                if (($folders | Measure-Object).count -gt 2) {
                    # Make / Check Folders
                    $art_folder_id = (Initialize-HuduFolder $folders[1..$($folders.count - 2)] -company_id $company.HuduID).id
                }
                $ArticleSplat = @{
                    name       = $doc.name
                    content    = "Migration in progress"
                    company_id = $company.HuduID
                    folder_id  = $art_folder_id
                }	
            } else {
                if (($folders | Measure-Object).count -gt 2) {
                    # Make / Check Folders
                    $folders = $folders[1..$($folders.count - 2)]
                    if ($GlobalKBFolder) {
                        $folders = @($GlobalKBFolder.name) + $folders
                    }
                    $art_folder_id = (Initialize-HuduFolder $folders).id
                }
                else {
                    # Check for GlobalKB Folder being set
                    if ($GlobalKBFolder) {
                        $art_folder_id = $GlobalKBFolder.id
                    }
                }
                $ArticleSplat = @{
                    name      = $doc.name
                    content   = "Migration in progress"
                    folder_id = $art_folder_id
                }	
            }
    
        } else {
            Write-Host "Company $($doc.organization) Not Found Please migrate $($doc.name) manually"
            continue
        }
        $NewArticle = (New-HuduArticle @ArticleSplat).article
        if ($company.InternalCompany -eq $false) {
            Write-Host "Article created in $($company.CompanyName)"
        } else {
            Write-Host "Article created in GlobaL KB"
        }
        [PSCustomObject]@{
            "Name"       = $doc.name
            "Filename"   = $Filename
            "Path"       = $($dir.Fullname)
            "FullPath"   = "$($dir.Fullname)\$($filename).html"
            "ITGID"      = $doc.id
            "ITGLocator" = $doc.locator
            "HuduID"     = $NewArticle.ID
            "HuduObject" = $NewArticle
            "Folders"    = $folders
            "Imported"   = "Stub-Created"
            "Company"    = $company
        }

    }