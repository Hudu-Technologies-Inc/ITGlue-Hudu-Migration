
############################### Documents / Articles ###############################
. $PSScriptRoot\Public\Set-ProcessArticleAttachment.ps1
. $PSScriptRoot\Public\Normalize-And-ConvertImage.ps1


#Check for Article Resume
if ($ResumeFound -eq $true -and (Test-Path "$MigrationLogs\ArticleBase.json")) {
    Write-Host "Loading Article Migration"
    $MatchedArticles = Get-Content "$MigrationLogs\ArticleBase.json" -raw | Out-String | ConvertFrom-Json -depth 100
} else {

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


            $company = $MatchedCompanies | Where-Object { $_.CompanyName -eq $doc.organization }
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
        $MatchedArticles | ConvertTo-Json -depth 100 | Out-File "$MigrationLogs\ArticleBase.json"
        $ManualActions | ConvertTo-Json -depth 100 | Out-File "$MigrationLogs\ManualActions.json"
        Write-TimedMessage -Timeout 3 -Message "Snapshot Point: Stub Articles Created Continue?"  -DefaultResponse "continue to Document/Article Bodies, please."
    }

}

############################### Documents / Articles Bodies ###############################

#Check for Articles Resume
if ($ResumeFound -eq $true -and (Test-Path "$MigrationLogs\Articles.json")) {
    Write-Host "Loading Article Content Migration"
    $MatchedArticles = Get-Content "$MigrationLogs\Articles.json" -raw | Out-String | ConvertFrom-Json -depth 100
} else {
	if ($ImportArticles -eq $true) {
    # Only directories here; no need to recurse yet
    $AttachRoots = Get-ChildItem -Directory (Join-Path -Path $ITGLueExportPath -ChildPath "attachments\documents")

    # Now do the actual work of populating the content of articles
    $ArticleErrors = foreach ($Article in $MatchedArticles) {
        Write-Host "Starting $($Article.Name) in $($Article.Company.CompanyName)" -ForegroundColor Green
        $InFile = $Article.FullPath

        $html = New-Object -ComObject "HTMLFile"
        $rawsource = Get-Content -LiteralPath $InFile -Raw -Encoding UTF8
        if ($rawsource.Length -gt 0) {
            $page_out = ''
            $source = [regex]::replace($rawsource, '\xa0+', ' ')
            $src    = [System.Text.Encoding]::Unicode.GetBytes($source)
            $html.write($src)

            # Collections from DOM (live)
            $images  = @($html.Images)
            $anchors = @($html.Links)
            $escaped = [regex]::Escape($([string]$Article.ITGID))
            $pattern = '^{0}(?=\b|$)' -f $escaped

            $attachDirs = $AttachRoots |
            Where-Object { $_.Name -match $pattern } |
            Select-Object -ExpandProperty FullName

            if ($attachDirs -and $attachDirs.Count -gt 0) {
                $attResult = Set-ProcessArticleAttachment `
                    -Html $html `
                    -Attachments $attachDirs `
                    -ITGURL $ITGURL `
                    -UploadableId $Article.HuduID `
                    -UploadableType 'Article' `
                    -UploadUnlinked

                if (-not $attResult.Success) {
                    foreach ($e in $attResult.Errors) {
                        Write-ErrorObjectsToFile -name ($e.File ?? 'unknown') -ErrorObject $e
                    }
                }
            }

            foreach ($imageObject in $images) {
                $imagePath = $null
                if (($imageObject.src -notmatch '^http[s]?://') -or ($imageObject.src -match [regex]::Escape($ITGURL))) {
                    $script:HasImages = $true
                    $imgHTML = $imageObject.outerHTML
                    Write-Host "Processing HTML: $imgHTML"

                    if ($imageObject.src -match [regex]::Escape($ITGURL)) {
                        $matchedImage = Update-StringWithCaptureGroups -inputString $imgHTML -type 'img' -pattern $ImgRegexPatternToMatch
                        if ($matchedImage) {
                            $tnImgUrl  = $matchedImage.url
                            $tnImgPath = $matchedImage.path
                        } else {
                            $tnImgPath = $imageObject.src
                        }
                    } else {
                        $basepath  = Split-Path $InFile
                        if ($fullImgUrl = $imgHTML.split('data-src-original="')[1]) { $fullImgUrl = $fullImgUrl.split('"')[0] }
                        $tnImgUrl  = $imgHTML.split('src="')[1].split('"')[0]
                        if ($fullImgUrl) { $fullImgPath = Join-Path -Path $basepath -ChildPath $fullImgUrl.Replace('/','\') }
                        $tnImgPath = Join-Path -Path $basepath -ChildPath $tnImgUrl.Replace('/','\')
                    }

                    Write-Host "Processing IMG: $tnImgPath"

                    if ($fullImgUrl -and ($foundFile = Get-Item -Path "$fullImgPath*" -ErrorAction SilentlyContinue)) {
                        $imagePath = $foundFile.FullName
                    } elseif ($tnImgUrl -and ($foundFile = Get-Item -Path "$tnImgPath*" -ErrorAction SilentlyContinue)) {
                        $imagePath = $foundFile.FullName
                    } else {
                        continue
                    }

                    $imageTest = Get-ImageTests -imagePath $imagePath
                    if ($true -ne $imageTest.Success) { Write-ErrorObjectsToFile -name $imagePath -ErrorObject $imageTest; continue }

                    $uploadedPhoto = Get-UploadedPhotoURL -imagePath $imagePath -articleId $Article.HuduID

                    $replacedLinksResult = Set-ReplacedHTMLLinks -huduPhotoURL $uploadedPhoto.UploadImage.url -imageObject $imageObject -html $html
                    if ($true -ne $replacedLinksResult.Success) { Write-ErrorObjectsToFile -name $imagePath -ErrorObject $replacedLinksResult; continue }
                    
                    $html = $replacedLinksResult.html
                }
            }

            $page_Source = $html.documentElement.outerHTML
            $page_out = [regex]::replace($page_Source, '\xa0+', ' ')
        }

        if ($page_out -eq '') {
            $page_out = 'Empty Document in IT Glue Export - Please Check IT Glue'
            $ManualLog = [PSCustomObject]@{
                Document_Name = $Article.name
                Asset_Type    = 'Article'
                Company_Name  = $Article.Company.CompanyName
                Field_Name    = 'N/A'
                HuduID        = $Article.HuduID
                Notes         = 'Empty Document'
                Action        = 'Validate the document is blank in ITGlue, or manually copy the content across. Note that embedded documents in ITGlue will be migrated in blank with an attachment of the original doc'
                Data          = "$InFile"
                Hudu_URL      = $Article.HuduObject.url
                ITG_URL       = "$ITGURL/$($Article.ITGLocator)"
            }
            $null = $ManualActions.Add($ManualLog)
        }

        if ($Article.company.InternalCompany -eq $false) {
            $ArticleSplat = @{
                article_id = $Article.HuduID
                name       = $Article.name
                content    = $page_out
                company_id = $Article.company.HuduID
            }
        } else {
            $ArticleSplat = @{
                article_id = $Article.HuduID
                name       = $Article.name
                content    = $page_out
            }
        }

        $null = Set-HuduArticle @ArticleSplat
        Write-Host "$($Article.name) completed" -ForegroundColor Green
        $Article.Imported = "Created-By-Script"
    }

    $MatchedArticles | ConvertTo-Json -Depth 100 | Out-File "$MigrationLogs\Articles.json"
    $ArticleErrors   | ConvertTo-Json -Depth 100 | Out-File "$MigrationLogs\ArticleErrors.json"
    $ManualActions   | ConvertTo-Json -Depth 100 | Out-File "$MigrationLogs\ManualActions.json"
    Write-TimedMessage -Timeout 3 -Message "Snapshot Point: Articles Created Continue?" -DefaultResponse "continue to Passwords, please."
    }
}


############################### Passwords ###############################


#Check for Passwords Resume
if ($ResumeFound -eq $true -and (Test-Path "$MigrationLogs\Passwords.json")) {
    Write-Host "Loading Previous Paswords Migration"
    $MatchedPasswords = Get-Content "$MigrationLogs\Passwords.json" -raw | Out-String | ConvertFrom-Json
} else {

    #Import Passwords
    Write-Host "Fetching Passwords from IT Glue" -ForegroundColor Green
    $PasswordSelect = { (Get-ITGluePasswords -page_size 1000 -page_number $i).data }

    $ITGPasswords = Import-ITGlueItems -ItemSelect $PasswordSelect -MigrationName 'Passwords'

    if ($ScopedMigration) {
        $OriginalPasswordsCount = $($ITGPasswords.count)
        Write-Host "Setting passwords to those in scope..." -foregroundcolor Yellow        
        $ITGPasswords         = $ITGPasswords | Where-Object { $ScopedCompanyIds -contains $_.attributes.'organization-id' }
        Write-Host "Passwords scoped... $OriginalPasswordsCount => $($ITGPasswords.count)"
    }

    try {
        Write-Host "Loading Passwords from CSV for faster import" -foregroundcolor Cyan
        $ITGPasswordsRaw = Import-CSV -Path "$ITGLueExportPath\passwords.csv"
    }
	catch {
        $ITGPasswordsSingle = foreach ($ITGRawPass in $ITGPasswords) {
            $ITGPassword = (Get-ITGluePasswords -id $ITGRawPass.id -include related_items).data
            $ITGPassword
        }
        $ITGPasswords = $ITGPasswordsSingle
    }
    
    Write-Host "$($ITGPasswords.count) IT Glue Passwords Found"

    $PasswordsInCSV = [System.Collections.ArrayList]::new()
    $PasswordsNotInCSV = [System.Collections.ArrayList]::new()

    $IdOrganizationMap = @{}
    foreach ($row in $ITGPasswordsRaw) {
        $IdOrganizationMap[[string]$row.id] = @{
            'password' = $row.password
            'otp_secret' = $row.otp_secret
        }
    }

    foreach ($row in $ITGPasswords) {
        if ($IdOrganizationMap.ContainsKey([string]$row.id) -eq $true) {
            $row.attributes | Add-Member -MemberType 'NoteProperty' -Name 'password' -Value $IdOrganizationMap[[string]$row.id].password
            $row.attributes | Add-Member -MemberType 'NoteProperty' -Name 'otp_secret' -Value $IdOrganizationMap[[string]$row.id].otp_secret
            [void]$PasswordsInCSV.Add($row)
        } else {
            [void]$PasswordsNotInCSV.Add($row)
        }
    }

    $MatchedPasswords = New-Object 'System.Collections.ArrayList'
    foreach ($itgpassword in $PasswordsInCSV) {
        [void]$MatchedPasswords.Add(
            [PSCustomObject]@{
                "Name"       = $itgpassword.attributes.name
                "ITGID"      = $itgpassword.id
                "HuduID"     = ""
                "Matched"    = $false
                "HuduObject" = ""
                "ITGObject"  = $itgpassword
                "Imported"   = ""
            }
        )
    }
    foreach ($itgpassword in $PasswordsNotInCSV) {
        $FullPassword = (Get-ITGluePasswords -id $itgpassword.id -include related_items).data
        [void]$MatchedPasswords.Add(
            [PSCustomObject]@{
                "Name"       = $itgpassword.attributes.name
                "ITGID"      = $itgpassword.id
                "HuduID"     = ""
                "Matched"    = $false
                "HuduObject" = ""
                "ITGObject"  = $FullPassword
                "Imported"   = ""
            }
        )
    }

    Write-Host "Passwords to Migrate"
    $MatchedPasswords | Sort-Object Name |  Select-Object Name | Format-Table


    $UnmappedPasswordCount = ($MatchedPasswords | Where-Object { $_.Matched -eq $false } | measure-object).count

    if ($ImportPasswords -eq $true -and $UnmappedPasswordCount -gt 0) {

        $importOption = Get-ImportMode -ImportName "Passwords"

        if (($importOption -eq "A") -or ($importOption -eq "S") ) {		

            foreach ($company in $CompaniesToMigrate) {
                Write-Host "Migrating $($company.CompanyName)" -ForegroundColor Green

                foreach ($unmatchedPassword in ($MatchedPasswords | Where-Object { $_.Matched -eq $false -and $company.ITGCompanyObject.id -eq $_."ITGObject".attributes."organization-id" })) {

                    Confirm-Import -ImportObjectName "$($unmatchedPassword.Name)" -ImportObject $unmatchedPassword -ImportSetting $ImportOption

                    Write-Host "Starting $($unmatchedPassword.Name)"

                    $PasswordableType = 'Asset'
                    $ParentItemID = $null
		    
                    if ($($unmatchedPassword.ITGObject.attributes."resource-id")) {
						
                        if ($unmatchedPassword.ITGObject.attributes."resource-type" -eq "flexible-asset-traits") {
                            # Check if it has already migrated with Assets
                            $FoundItem = $MatchedAssetPasswords | Where-Object { $_.ITGID -eq $($unmatchedPassword.ITGID) }
                            if (!$FoundItem) {
                                Write-Host "Could not find password field on asset. ParentID: $($unmatchedPassword.ITGObject.attributes.`"resource-id`")"
                                $FoundItem = $MatchedAssets | Where-Object { $_.ITGID -eq $unmatchedPassword.ITGObject.attributes."resource-id" }
                                $ManualLog = [PSCustomObject]@{
                                    Document_Name = $FoundItem.name
                                    Field_Name    = $unmatchedPassword.ITGObject.attributes.name
                                    Asset_Type    = "Asset password field"
                                    Company_Name  = $unmatchedPassword.ITGObject."organization-name"
                                    HuduID        = $unmatchedPassword.HuduID
                                    Notes         = "Password from FA Field not found."
                                    Action        = "Manually create password"
                                    Data          = "Type: $($unmatchedPassword.ITGObject.attributes.`"resource-type`")"
                                    Hudu_URL      = $FoundItem.HuduObject.url
                                    ITG_URL       = $unmatchedPassword.ITGObject.attributes."parent-url"
                                }
                                $null = $ManualActions.add($ManualLog)
                            } else {
                                Write-Host "Migrated with Asset: $FoundItem.HuduID"
                            }
                        } else {
                            # Check if it needs to link to websites
                            if ($($unmatchedPassword.ITGObject.attributes."resource-type") -eq "domains") {
                                $ParentItemID = ($MatchedWebsites | Where-Object { $_.ITGID -eq $($unmatchedPassword.ITGObject.attributes."resource-id") }).HuduID
                                if ($ParentItemID) {
                                    Write-Host "Matched to $ParentItemID" -ForegroundColor Green
                                } else {
                                    Write-Host "Could not find asset to Match. ParentID: $($unmatchedPassword.ITGObject.attributes.`"resource-id`")"
                                    $ManualLog = [PSCustomObject]@{
                                        Document_Name = $unmatchedPassword.ITGObject.attributes.name
                                        Field_Name    = "N/A"
                                        Asset_Type    = $unmatchedPassword.HuduObject.asset_type
                                        Company_Name  = $unmatchedPassword.HuduObject.company_name
                                        HuduID        = $unmatchedPassword.HuduID
                                        Notes         = "Password could not be related."
                                        Action        = "Manually relate password"
                                        Data          = "Type: $($unmatchedPassword.ITGObject.attributes.`"resource-type`")"
                                        Hudu_URL      = $unmatchedPassword.HuduObject.url
                                        ITG_URL       = $unmatchedPassword.ITGObject.attributes."parent-url"
                                    }
                                    $null = $ManualActions.add($ManualLog)
                                }

                            } else {
                                # Deal with all others
                                $ParentItemID = (Find-MigratedItem -ITGID $($unmatchedPassword.ITGObject.attributes."resource-id")).HuduID
                                if ($ParentItemID) {
                                    Write-Host "Matched to $ParentItemID" -ForegroundColor Green
                                } else {
                                    Write-Host "Could not find asset to Match. ParentID: $($unmatchedPassword.ITGObject.attributes.`"resource-id`")"
                                    $ManualLog = [PSCustomObject]@{
                                        Document_Name = $unmatchedPassword.ITGObject.attributes.name
                                        Field_Name    = "N/A"
                                        Asset_Type    = $unmatchedPassword.HuduObject.asset_type
                                        Company_Name  = $unmatchedPassword.HuduObject.company_name
                                        HuduID        = $unmatchedPassword.HuduID
                                        Notes         = "Password could not be related."
                                        Action        = "Manually relate password"
                                        Data          = "Type: $($unmatchedPassword.ITGObject.attributes.`"resource-type`")"
                                        Hudu_URL      = $unmatchedPassword.HuduObject.url
                                        ITG_URL       = $unmatchedPassword.ITGObject.attributes."parent-url"
                                    }
                                    $null = $ManualActions.add($ManualLog)
                                }
                            }
                        }
                    }
					
                    if (!($($unmatchedPassword.ITGObject.attributes."resource-type") -eq "flexible-asset-traits")) {

                        $validated_otp = "$($unmatchedPassword.ITGObject.attributes.otp_secret)".Trim().ToUpper()
                        if ($validated_otp) {
                            $isValidBase32 = $validated_otp -match '^[A-Z2-7]+$'
                            $lengthOK = $validated_otp.Length -ge 16 -and $validated_otp.Length -le 80

                            $validated_otp = if ($isValidBase32 -and $lengthOK) { $validated_otp } else { $null }

                            if (-not ($isValidBase32 -and $lengthOK)) {
                                Write-Warning "Invalid OTP secret for $($unmatchedPassword.ITGObject.attributes.name): $($unmatchedPassword.ITGObject.attributes.otp_secret)... valid base32? $isValidBase32 length ok? $lengthOK (min / max is 16 / 80 chars)"
                            }                            
                        }


                        $PasswordSplat = @{
                            name              = "$($unmatchedPassword.ITGObject.attributes.name)"
                            company_id        = $company.HuduCompanyObject.ID
                            description       = $unmatchedPassword.ITGObject.attributes.notes
                            passwordable_type = $PasswordableType
                            passwordable_id   = $ParentItemID
                            in_portal         = $false
                            password          = $unmatchedPassword.ITGObject.attributes.password
                            url               = if ($url = $unmatchedPassword.ITGObject.attributes.url) {$url} Else {$unmatchedPassword.ITGObject.attributes.'resource-url'}
                            username          = $unmatchedPassword.ITGObject.attributes.username
                            otpsecret         = $validated_otp

                        }
                        if ([string]::IsNullOrWhiteSpace($unmatchedPassword.ITGObject.attributes.password) -or $unmatchedPassword.ITGObject.attributes.password.Length -lt 1) {
                            $manualActions.add([PSCustomObject]@{
                                name              = "$($unmatchedPassword.ITGObject.attributes.name)"
                                company_id        = $company.HuduCompanyObject.ID
                                description       = $unmatchedPassword.ITGObject.attributes.notes
                                passwordable_type = $PasswordableType
                                passwordable_id   = $ParentItemID
                                in_portal         = $false
                                password          = ""
				                Hudu_URL      	  = $unmatchedPassword.HuduObject.url
                                ITG_URL           = if ($url = $unmatchedPassword.ITGObject.attributes.url) {$url} Else {$unmatchedPassword.ITGObject.attributes.'resource-url'}
                                username          = $unmatchedPassword.ITGObject.attributes.username
                                otpsecret         = "removed for security purposes"
                                problem           = "password was null or empty"
                            })
                            $unmatchedPassword.matched = $false
                            Write-Warning "$($HuduNewPassword.Name) Has been skipped and added to manual actions due to being empty"                            
                        } else {
                            $HuduNewPassword = (New-HuduPassword @PasswordSplat).asset_password 
                            $unmatchedPassword.matched = $true
                            $unmatchedPassword.HuduID = $HuduNewPassword.id
                            $unmatchedPassword."HuduObject" = $HuduNewPassword
                            $unmatchedPassword.Imported = "Created-By-Script"
                            $ImportsMigrated = $ImportsMigrated + 1
                            Write-host "$($HuduNewPassword.Name) Has been created in Hudu"
                        }
                    }
                }
            }
        }


    } else {
        if ($UnmappedPasswordCount -eq 0) {
            Write-Host "All Passwords matched, no migration required" -foregroundcolor green
        } else {
            Write-Host "Warning Import passwords is set to disabled so the above unmatched passwords will not have data migrated" -foregroundcolor red
            Write-TimedMessage -Timeout 3 -Message "Press any key to continue or CTRL+C to quit"  -DefaultResponse "continue wrap-up of passwords, please."
        }
    }

    # Save the results to resume from if needed
    $MatchedPasswords | ConvertTo-Json -depth 100 | Out-File "$MigrationLogs\Passwords.json"
    $ManualActions | ConvertTo-Json -depth 100 | Out-File "$MigrationLogs\ManualActions.json"
    Write-TimedMessage -Timeout 3 -Message "Snapshot Point: Passwords Finished. Continue?"  -DefaultResponse "continue to Document/Article Updates, please."
}

############################## Update ITGlue URLs on All Areas to Hudu #######################
$UpdateArticles = (Get-HuduArticles | Where-Object {$_.content -like "*$ITGURL*"})
$UpdateAssets = $MatchedAssets | Where-Object {$_.HuduObject.fields.value -like "*$ITGURL*"}
$UpdatePasswords = $MatchedPasswords | Where-Object {$_.HuduObject.description -like "*$ITGURL*"}
$UpdateAssetPasswords = $MatchedAssetPasswords | Where-Object {$_.ITGObject.attributes.notes -like "*$ITGURL*"}
$UpdateCompanyNotes = $MatchedCompanies | Where-Object {$_.HuduCompanyObject.notes -like "*$ITGURL*"}


# Articles
$articlesUpdated = @()
foreach ($articleFound in $UpdateArticles) {
    if ($NewContent = Update-StringWithCaptureGroups -inputString $articleFound.content -pattern $RichRegexPatternToMatchSansAssets -type "rich") {
        $NewContent = Update-StringWithCaptureGroups -inputString $NewContent -pattern $RichRegexPatternToMatchWithAssets -type "rich"
	$NewContent = Update-StringWithCaptureGroups -inputString $NewContent -pattern $RichDocLocatorUrlPatternToMatch -type "rich"
 	$NewContent = Update-StringWithCaptureGroups -inputString $NewContent -pattern $RichDocLocatorRelativeURLPatternToMatch -type "rich"
        Write-Host "Updating Article $($articleFound.name) with replaced Content" -ForegroundColor 'Green'
	try {
        $ArticlePost = Set-HuduArticle -Name $articleFound.name -id $articleFound.id -Content $NewContent -ErrorAction Stop
        $articlesUpdated = $articlesUpdated + @{"status" = "replaced"; "original_article" = $articleFound; "updated_article" = $ArticlePost}
	} catch { $articlesUpdated = $articlesUpdated + @{"status" = "failed"; "original_article" = $articleFound; "attempted_changes" = $newContent} }
        }
    else {
        Write-Warning "Article $articleFound.id found ITGlue URL but didn't match"
        $articlesUpdated = $articlesUpdated + @{"status" = "clean"; "original_article" = $articleFound}
    }
}

$articlesUpdated | ConvertTo-Json -depth 100 |Out-file "$MigrationLogs\ReplacedArticlesURL.json"
Write-TimedMessage -Timeout 3 -Message "Snapshot Point: Article URLs Replaced. Continue?"  -DefaultResponse "continue to Assets, please."

# Assets
$assetsUpdated = @()
foreach ($assetFound in $UpdateAssets.HuduObject) {
    $originalAsset = $assetFound
    $replacedStatus = 'clean'
    $customFields = @()

    foreach ($field in $assetFound.fields) {
        # Convert the caption to snake_case to match API expectations for 2.37.1
        $label = ($field.caption -replace '[^\w\s]', '') -replace '\s+', '_' | ForEach-Object { $_.ToLower() }

        if ($label -in @('itglue_url', 'itglue_id', 'imported_from_itglue') -and $field.value -like "*$ITGURL*") {
            $NewContent = Update-StringWithCaptureGroups -inputString $field.value -pattern $RichRegexPatternToMatchSansAssets -type "rich"
            $NewContent = Update-StringWithCaptureGroups -inputString $NewContent -pattern $RichRegexPatternToMatchWithAssets -type "rich"

            if ($NewContent -and $NewContent -ne $field.value) {
                Write-Host "Replacing Asset $($assetFound.name) field $($field.caption) with updated content" -ForegroundColor 'Red'
                $customFields += @{ $label = $NewContent }
                $replacedStatus = 'replaced'
            } else {
                $customFields += @{ $label = $field.value }
            }
        } else {
            # For other fields, preserve existing value (optional)
            $customFields += @{ $label = $field.value }
        }
    }

    if ($replacedStatus -eq 'replaced') {
        Write-Host "Updating Asset $($assetFound.name) with new custom_fields array" -ForegroundColor 'Green'
        $AssetPost = Invoke-HuduRequest -Method PUT -Resource "api/v1/companies/$($assetFound.company_id)/assets/$($assetFound.id)" -Body @{
            name              = $assetFound.name
            asset_layout_id   = $assetFound.asset_layout_id
            custom_fields     = $customFields
        }
    }

    $assetsUpdated += @{
        status         = $replacedStatus
        original_asset = $originalAsset
        updated_asset  = $AssetPost.asset
    }
}

$assetsUpdated | ConvertTo-Json -depth 100 |Out-file "$MigrationLogs\ReplacedAssetsURL.json"
Write-TimedMessage -Timeout 3 -Message  "Snapshot Point: Assets URLs Replaced. Continue?" -DefaultResponse "continue to Passwords Matching, please."

# Passwords
$passwordsUpdated = @()
foreach ($passwordFound in $UpdatePasswords.HuduObject) {
    $NewContent = Update-StringWithCaptureGroups -inputString $passwordFound.description -pattern $TextRegexPatternToMatchSansAssets -type "plain"
    $NewContent = Update-StringWithCaptureGroups -inputString $NewContent -pattern $TextRegexPatternToMatchWithAssets -type "plain"
    if ($NewContent) {
        Write-Host "Updating Password $($passwordFound.name) with updated description" -ForegroundColor 'Green'
        $passwordsUpdated = $passwordsUpdated + @{"original_password" = $passwordFound; "updated_password" = (Set-HuduPassword -id $passwordFound.id -Description $NewContent).asset_password}
    }
}
$passwordsUpdated | ConvertTo-Json -depth 100 |Out-file "$MigrationLogs\ReplacedPasswordsURL.json"
Write-TimedMessage -Timeout 3 -Message  "Snapshot Point: Password URLs Replaced. Continue?"  -DefaultResponse "continue to Asset Passwords Matching, please."

# Asset Passwords
$assetPasswordsUpdated = @()
foreach ($passwordFound in $UpdateAssetPasswords) {
    $passwordFound = Get-HuduPasswords -id $passwordFound.HuduID
    $NewContent = Update-StringWithCaptureGroups -inputString $passwordFound.description -pattern $TextRegexPatternToMatchSansAssets -type "plain"
    $NewContent = Update-StringWithCaptureGroups -inputString $NewContent -pattern $TextRegexPatternToMatchWithAssets -type "plain"
    if ($NewContent)   {
        Write-Host "Updating Asset Password $($passwordFound.name) with updated description" -ForegroundColor 'Green'
        $assetPasswordsUpdated = $assetPasswordsUpdated + @{"original_password" = $passwordFound; "updated_password" = (Set-HuduPassword -Id $passwordFound.id -Description $NewContent).asset_password}
    }
    
}
$assetPasswordsUpdated | ConvertTo-Json -depth 100 |Out-file "$MigrationLogs\ReplacedAssetPasswordsURL.json"
Write-TimedMessage -Timeout 3 -Message  "Snapshot Point: Asset Passwords URLs Replaced. Continue?"  -DefaultResponse "continue to Company Notes, please."

# Company Notes
$companyNotesUpdated = @()
foreach ($companyFound in $UpdateCompanyNotes.HuduCompanyObject) {
    $NewContent = Update-StringWithCaptureGroups -inputString $companyFound.notes -pattern $RichRegexPatternToMatchSansAssets -type "rich"
    $NewContent = Update-StringWithCaptureGroups -inputString $NewContent -pattern $RichRegexPatternToMatchWithAssets -type "rich"
    if ($NewContent) {
        Write-Host "Updating Company $($companyFound.name) with updated notes" -ForegroundColor 'Green'
        $companyNotesUpdated = $companyNotesUpdated + @{"original_company" = $companyFound; "updated_company" = (Set-HuduCompany -id $companyFound.id -Notes $NewContent).company}
    }

}
$companyNotesUpdated | ConvertTo-Json -depth 100 |Out-file "$MigrationLogs\ReplacedCompaniesURL.json"
Write-TimedMessage -Timeout 3 -Message "Snapshot Point: Company Notes URLs Replaced. Continue?"  -DefaultResponse "continue to Manual Actions, please."

############################### Generate Manual Actions Report ###############################

$ManualActions | ForEach-Object {
    if ($_.Hudu_URL -notmatch "http:" -and $_.Hudu_URL -notmatch "https:") {
        $_.Hudu_URL = "$HuduBaseDomain$($_.Hudu_URL)"
    }
}


$Head = @"
<html>
<head>
<Title>Manual Actions Required Report</Title>
<link href="https://cdn.jsdelivr.net/npm/bootstrap@5.0.1/dist/css/bootstrap.min.css" rel="stylesheet" integrity="sha384-+0n0xVW2eSR5OomGNYDnhzAbDsOXxcvSN1TPprVMTNDbiYZCxYbOOl7+AMvyTG2x" crossorigin="anonymous">
<style type="text/css">
<!–
body {
    font-family: Verdana, Geneva, Arial, Helvetica, sans-serif;
}
h2{ clear: both; font-size: 100%;color:#354B5E; }
h3{
    clear: both;
    font-size: 75%;
    margin-left: 20px;
    margin-top: 30px;
    color:#475F77;
}
table{
	border-collapse: collapse;
	margin: 5px 0;
	font-size: 0.8em;
	font-family: sans-serif;
	min-width: 400px;
	box-shadow: 0 0 20px rgba(0, 0, 0, 0.15);
}

th, td {
	padding: 5px 5px;
	max-width: 400px;
	width:auto;
}
thead tr {
	background-color: #009879;
	color: #ffffff;
	text-align: left;
}
tr {
	border-bottom: 1px solid #dddddd;
}
tr:nth-of-type(even) {
	background-color: #f3f3f3;
}
->
</style>
</head>
<body>
<div style="padding:40px">


"@


$MigrationReport = @"
<h1> Migration Report </h1>
Started At: $ScriptStartTime <br />
Completed At: $(Get-Date -Format "o") <br />
$(($MatchedCompanies | Measure-Object).count) : Companies Migrated <br />
$(($MatchedLocations | Measure-Object).count) : Locations Migrated <br />
$(($MatchedWebsites | Measure-Object).count) : Websites Migrated <br />
$(($MatchedConfigurations | Measure-Object).count) : Configurations Migrated <br />
$(($MatchedContacts | Measure-Object).count) : Contacts Migrated <br />
$(($MatchedLayouts | Measure-Object).count) : Layouts Migrated <br />
$(($MatchedAssets | Measure-Object).count) : Assets Migrated <br />
$(($MatchedArticles | Measure-Object).count) : Articles Migrated <br />
$(($MatchedPasswords | Measure-Object).count) : Passwords Migrated <br />
If you found this script useful please consider sponsoring me at: <a href=https://github.com/sponsors/lwhitelock?frequency=one-time>https://github.com/sponsors/lwhitelock?frequency=one-time</a>
<hr>
<h1>Manual Actions Required Report</h1>
"@

$footer = "</div></body></html>"

$UniqueItems = $ManualActions | Select-Object huduid, hudu_url -unique

$ManualActionsReport = foreach ($item in $UniqueItems) {
    $items = $ManualActions | where-object { $_.huduid -eq $item.huduid -and $_.hudu_url -eq $item.Hudu_url }
    $core_item = $items | Select-Object -First 1
    $Header = "<h2><strong>Name: $($core_item.Document_Name)</strong></h2>
				<h2>Type: $($core_item.Asset_Type)</h2>
				<h2>Company: $($core_item.Company_name)</h2>
				<h2>Hudu URL: <a href=$($core_item.Hudu_URL)>$($core_item.Hudu_URL)</a></h2>
				<h2>IT Glue URL: <a href=$($core_item.ITG_URL)>$($core_item.ITG_URL)</a></h2>
				"
    $Actions = $items | Select-Object Field_Name, Notes, Action, Data | ConvertTo-Html -fragment | Out-String

    $OutHTML = "$Header $Actions <hr>"

    $OutHTML

}

$FinalHtml = "$Head $MigrationReport $ManualActionsReport $footer"
$FinalHtml | Out-File ManualActions.html



############################### End ###############################


Write-Host "#######################################################" -ForegroundColor Green
Write-Host "#                                                     #" -ForegroundColor Green
Write-Host "#        IT Glue to Hudu Migration Complete           #" -ForegroundColor Green
Write-Host "#                                                     #" -ForegroundColor Green
Write-Host "#######################################################" -ForegroundColor Green
Write-Host "Started At: $ScriptStartTime"
Write-Host "Completed At: $(Get-Date -Format "o")"
Write-Host "$(($MatchedCompanies | Measure-Object).count) : Companies Migrated" -ForegroundColor Green
Write-Host "$(($MatchedLocations | Measure-Object).count) : Locations Migrated" -ForegroundColor Green
Write-Host "$(($MatchedWebsites | Measure-Object).count) : Websites Migrated" -ForegroundColor Green
Write-Host "$(($MatchedConfigurations | Measure-Object).count) : Configurations Migrated" -ForegroundColor Green
Write-Host "$(($MatchedContacts | Measure-Object).count) : Contacts Migrated" -ForegroundColor Green
Write-Host "$(($MatchedLayouts | Measure-Object).count) : Layouts Migrated" -ForegroundColor Green
Write-Host "$(($MatchedAssets | Measure-Object).count) : Assets Migrated" -ForegroundColor Green
Write-Host "$(($MatchedArticles | Measure-Object).count) : Articles Migrated" -ForegroundColor Green
Write-Host "$(($MatchedPasswords | Measure-Object).count) : Passwords Migrated" -ForegroundColor Green
Write-Host "#######################################################" -ForegroundColor Green
Write-Host "Manual Actions report can be found in ManualActions.html in the folder the script was run from"
Write-Host "Logs of what was migrated can be found in the MigrationLogs folder"
Write-TimedMessage -Message "Press any key to start wrap-up tasks or Ctrl+C to end" -Timeout 120  -DefaultResponse "continue, view generative Manual Actions webpage, please."

write-host "wrapup 1/5... setting asset layouts as active"
foreach ($layout in Get-HuduAssetLayouts) {write-host "setting $($(Set-HuduAssetLayout -id $layout.id -Active $true).asset_layout.name) as active" }

write-host "wrapup 2/5... adding attachments (this can take a while)"
. .\Add-HuduAttachmentsViaAPI.ps1

write-host "wrapup 3/5... adding missing relations (this can take a long while). Some errors will appear here, they can be safely ignored."
# set retry to off/false in HuduAPI module, this will save time during adding potentially existent relations.
$global:SKIP_HAPI_ERROR_RETRY=$true
. .\Get-MissingRelations.ps1

@($AssetRelationsToCreate) + @($ConfigurationRelationsToCreate) | ForEach-Object {try {New-HuduRelation -FromableType  $_.FromableType -FromableID    $_.FromableID -ToableType    $_.ToableType -ToableID      $_.ToableID} catch {Write-Host "Skipped or errored: $_" -ForegroundColor Yellow}}

write-host "wrapup 4/5... archiving passwords, assets, configurations as they had been in ITGlue (this can take a while)"
$DocsCsv = import-csv "$ITGLueExportPath\documents.csv"
$ArchivedPasswords = $MatchedPasswords |? {$_.itgobject.attributes.archived -eq $true}
$ArchivedConfigurations = $MatchedConfigurations |? {$_.ITGObject.attributes.archived -eq $true}    
$ArchivedAssets = $MatchedAssets |? {$_.ITGObject.attributes.archived -eq $true}
$ArchivedDocs = $DocsCsv |? {$_.archived -eq 'yes'}

write-host "wrapup 5/5... archiving items..."
$ptaresults = $ArchivedPasswords | % {if ($_.huduid -and $_.huduid -gt 0) {Set-HuduPasswordArchive -id $_.huduid -Archive $true}}
$ctaresults = $ArchivedConfigurations |% {if ($_.huduid -and $_.huduid -gt 0) {Set-HuduAssetArchive -Id $_.huduid -CompanyId $_.huduobject.company_id -Archive $true}}
$ataresults = $ArchivedAssets |% {if ($_.huduid -and $_.huduid -gt 0) {Set-HuduAssetArchive -Id $_.huduid -CompanyId $_.huduobject.company_id -Archive $true}}
$dtaresults = $ArchivedDocs |% {$i = $_; $A2D = $MatchedArticles |? {$A2D.itgid -eq $i.id}; if ($A2D.huduid -and $A2D.huduid -gt 0) {Set-HuduArticleArchive -Id $A2D.HuduId -Archive $true}} 
foreach ($obj in @(
    @{Name = "passwords";       Archived = $ptaresults},
    @{Name = "configs";         Archived = $ctaresults},
    @{Name = "assets";          Archived = $ataresults},
    @{Name = "docs";            Archived = $dtaresults})) {
    $obj.Archived | ConvertTo-Json -depth 75 | Out-File $(join-path $settings.MigrationLogs "archived-$($obj.Name).json")
}
$global:SKIP_HAPI_ERROR_RETRY=$false

Start-Process ManualActions.html


