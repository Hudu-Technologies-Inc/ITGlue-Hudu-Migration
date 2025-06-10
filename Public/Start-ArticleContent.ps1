
if ($ImportArticles -eq $true) {
    $Attachfiles = Get-ChildItem (Join-Path -Path $ITGLueExportPath -ChildPath "attachments\documents") -recurse

    # Now do the actual work of populating the content of articles
    $ArticleErrors = foreach ($Article in $MatchedArticles) {

        $page_out = ''
        $imagePath = $null
    
        # Check for attachments
        $attachdir = $Attachfiles | Where-Object { $_.PSIsContainer -eq $true -and $_.Name -match $Article.ITGID }
        if ($Attachdir) {
            $InFile = ''
            $html = ''
            $rawsource = ''

            $ManualLog = [PSCustomObject]@{
                Document_Name = $Article.Name
                Asset_Type    = "Article"
                Company_Name  = $Article.HuduObject.company_name
                HuduID        = $Article.HuduID
                Field_Name    = "N/A"
                Notes         = "Attached Files not Supported"
                Action        = "Manually Upload files to Related Files"
                Data          = $attachdir.fullname
                Hudu_URL      = $Article.HuduObject.url
                ITG_URL       = "$ITGURL/$($Article.ITGLocator)"
            }
            $null = $ManualActions.add($ManualLog)

        }


        Write-Host "Starting $($Article.Name) in $($Article.Company.CompanyName)" -ForegroundColor Green
            
        $InFile = $Article.FullPath
            
        $html = New-Object -ComObject "HTMLFile"
        $rawsource = Get-Content -encoding UTF8 -LiteralPath $InFile -Raw
        if ($rawsource.Length -gt 0) {
            $source = [regex]::replace($rawsource , '\xa0+', ' ')
            $src = [System.Text.Encoding]::Unicode.GetBytes($source)
            $html.write($src)
            $images = @($html.Images)

            $images | ForEach-Object {
                
                
                if (($_.src -notmatch '^http[s]?://') -or ($_.src -match [regex]::Escape($ITGURL))) {
                    $script:HasImages = $true
                    $imgHTML = $_.outerHTML
                    Write-Host "Processing HTML: $imgHTML"
                    if ($_.src -match [regex]::Escape($ITGURL)) {
                        $matchedImage = Update-StringWithCaptureGroups -inputString $imgHTML -type 'img' -pattern $ImgRegexPatternToMatch
                        if ($matchedImage) {
                            $tnImgUrl = $matchedImage.url
                            $tnImgPath = $matchedImage.path
                        } else {
                            $tnImgPath = $_.src
                        }
                    }
                    else {
                        $basepath = Split-Path $InFile
                        
                        if ($fullImgUrl = $imgHTML.split('data-src-original="')[1]) {$fullImgUrl = $fullImgUrl.split('"')[0] }
                        $tnImgUrl = $imgHTML.split('src="')[1].split('"')[0]
                        if ($fullImgUrl) {$fullImgPath = Join-Path -Path $basepath -ChildPath $fullImgUrl.replace('/','\')}
                        $tnImgPath = Join-Path -Path $basepath -ChildPath $tnImgUrl.replace('/','\')
                    }
                    
                    Write-Host "Processing IMG: $tnImgPath"
                    
                    # Some logic to test for the original data source being specified vs the thumbnail. Grab the Thumbnail or final source.
                    if ($fullImgUrl -and ($foundFile = Get-Item -Path "$fullImgPath*" -ErrorAction SilentlyContinue)) {
                        $imagePath = $foundFile.FullName
                    } elseif ($tnImgUrl -and ($foundFile = Get-Item -Path "$tnImgPath*" -ErrorAction SilentlyContinue)) {
                        $imagePath = $foundFile.FullName
                    } else { 
                        Remove-Variable -Name imagePath -ErrorAction SilentlyContinue
                        Remove-Variable -Name foundFile -ErrorAction SilentlyContinue
                        Write-Warning "Unable to validate image file."
                        $ManualLog = [PSCustomObject]@{
                        Document_Name = $Article.Name
                        Asset_Type    = "Article"
                        Company_Name  = $Article.Company.CompanyName
                        HuduID        = $Article.HuduID
                        Notes = 'Missing image, file not found'
                        Actions = "Neither $fullImgPath or $tnImgPath were found, validate the images exist in the export, or retrieve them from ITGlue directly"
                        Data = "$InFile"
                        Hudu_URL = $Article.HuduObject.url
            ITG_URL = "$ITGURL/$($Article.ITGLocator)"
                        }

                        $null = $ManualActions.add($ManualLog)

                }

                    # Test the path to ensure that a file extension exists, if no file extension we get problems later on. We rename it if there's no ext.
                    if ($imagePath -and (Test-Path $imagePath -ErrorAction SilentlyContinue)) {
                        if ((Get-Item -path $imagePath).extension -eq '') {
                            Write-Warning "$imagePath is undetermined image. Testing..."
                            if ($Magick = New-Object ImageMagick.MagickImage($imagePath)) {
                                $OriginalFullImagePath = $imagePath
                                $imagePath = "$($imagePath).$($Magick.format)"
                                $MovedItem = Move-Item -Path $OriginalFullImagePath -Destination $imagePath
                            }
                        }                        
                        $imageType = Invoke-ImageTest($imagePath)
                        if ($imageType) {
                            Write-Host "Uploading new image"
                            try {
                                $UploadImage = New-HuduPublicPhoto -FilePath "$imagePath" -record_id $Article.HuduID -record_type 'Article'
                                $NewImageURL = $UploadImage.public_photo.url.replace($HuduBaseDomain, '')
                                $ImgLink = $html.Links | Where-Object {$_.innerHTML -eq $imgHTML}
                                Write-Host "Setting image to: $NewImageURL"
                                $_.src = [string]$NewImageURL
                                
                                # Update Links for this image
                                $ImgLink.href = [string]$NewImageUrl

                            }
                            catch {
                                $ManualLog = [PSCustomObject]@{
                                    Document_Name = $Article.Name
                                    Asset_Type    = "Article"
                                    Company_Name  = $Article.Company.CompanyName
                                    HuduID        = $Article.HuduID
                                    Notes = 'Failed to Upload to Backend Storage'
                                    Action = "$imagePath failed to upload to Hudu backend with error $_`n Validate that uploads are working and you still have disk space."
                                    Data = "$InFile"
                                    Hudu_URL = $Article.HuduObject.url
                ITG_URL = "$ITGURL/$($Article.ITGLocator)"
                                }

                                $null = $ManualActions.add($ManualLog)
                            }

                            if ($Magick -and $MovedItem) {
                                Move-Item -Path $imagePath -Destination $OriginalFullImagePath
                            }
    
                        }
                        else {

                            $ManualLog = [PSCustomObject]@{
                                Document_Name = $Article.Name
                                Asset_Type    = "Article"
                                Company_Name  = $Article.Company.CompanyName
                                HuduID        = $Article.HuduID
                                Notes       = 'Image Not Detected'
                                Action         = "$imagePath not detected as image, validate the identified file is an image, or imagemagick modules are loaded"        
                                Data = "$InFile"
                                Hudu_URL = $Article.HuduObject.url
                ITG_URL = "$ITGURL/$($Article.ITGLocator)"
                            }

                            $null = $ManualActions.add($ManualLog)

                        }
                    }
                    else {
                        Write-Warning "Image $tnImgUrl file is missing"
                        $ManualLog = [PSCustomObject]@{
                                Document_Name = $Article.Name
                                Asset_Type    = "Article"
                                Company_Name  = $Article.Company.CompanyName
                Field_Name = 'N/A'
                                HuduID        = $Article.HuduID
                                Notes       = 'Image File Missing'
                                Action         = "$tnImgUrl is not present in export,validate the image exists in ITGlue and manually replace in Hudu"   
                                Data = "$InFile"
                                Hudu_URL = $Article.HuduObject.url
                ITG_URL = "$ITGURL/$($Article.ITGLocator)"
                            }

                            $null = $ManualActions.add($ManualLog)
                    }
                }
            }
        
            $page_Source = $html.documentelement.outerhtml
            $page_out = [regex]::replace($page_Source , '\xa0+', ' ')
                    
        }
    
        if ($page_out -eq '') {
            $page_out = 'Empty Document in IT Glue Export - Please Check IT Glue'
            $ManualLog = [PSCustomObject]@{
                Document_Name   = $Article.name
                Asset_Type      = 'Article'
        Company_Name = $Article.Company.CompanyName
        Field_Name	   = 'N/A'
        HuduID = $Article.HuduID                    
        Notes       = 'Empty Document'
        Action	  = 'Validate the document is blank in ITGlue, or manually copy the content across. Note that embedded documents in ITGlue will be migrated in blank with an attachment of the original doc'
                Data          = "$InFile"
                Hudu_URL = $Article.HuduObject.url
        ITG_URL = "$ITGURL/$($Article.ITGLocator)"
            }

            $null = $ManualActions.add($ManualLog)
        }
        
            
        if ($_.company.InternalCompany -eq $false) {
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


