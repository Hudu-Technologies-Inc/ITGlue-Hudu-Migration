[string]$WorkingDirectory = "c:\tmp\images"

function Get-ImageTypeFromSignature {
    param (
        [string]$FilePath
    )

    $signature = [byte[]]::new(12)
    $stream = $null
    try {
        $stream = [System.IO.File]::Open($FilePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $read = $stream.Read($signature, 0, $signature.Length)

        if ($read -ge 8 -and $signature[0] -eq 0x89 -and $signature[1] -eq 0x50 -and $signature[2] -eq 0x4E -and $signature[3] -eq 0x47) { return 'png' }
        if ($read -ge 3 -and $signature[0] -eq 0xFF -and $signature[1] -eq 0xD8 -and $signature[2] -eq 0xFF) { return 'jpg' }
        if ($read -ge 6 -and $signature[0] -eq 0x47 -and $signature[1] -eq 0x49 -and $signature[2] -eq 0x46) { return 'gif' }
        if ($read -ge 2 -and $signature[0] -eq 0x42 -and $signature[1] -eq 0x4D) { return 'bmp' }
        if ($read -ge 4 -and (($signature[0] -eq 0x49 -and $signature[1] -eq 0x49 -and $signature[2] -eq 0x2A -and $signature[3] -eq 0x00) -or ($signature[0] -eq 0x4D -and $signature[1] -eq 0x4D -and $signature[2] -eq 0x00 -and $signature[3] -eq 0x2A))) { return 'tiff' }
        if ($read -ge 12 -and $signature[0] -eq 0x52 -and $signature[1] -eq 0x49 -and $signature[2] -eq 0x46 -and $signature[3] -eq 0x46 -and $signature[8] -eq 0x57 -and $signature[9] -eq 0x45 -and $signature[10] -eq 0x42 -and $signature[11] -eq 0x50) { return 'webp' }
    }
    catch {
        return $null
    }
    finally {
        if ($stream) { $stream.Dispose() }
    }

    return $null
}

function Get-ImageType {
    param (
        [string]$FilePath
    )

    $signatureType = Get-ImageTypeFromSignature -FilePath $FilePath
    if ($signatureType) {
        return $signatureType
    }

    $Magick = $null
    try {
        $Magick = New-Object ImageMagick.MagickImage($FilePath)
        return $Magick.Format.ToString().ToLower()
    } catch {
        return $null
    } finally {
        if ($Magick) { $Magick.Dispose() }
    }
}
function Get-SafeFilename {
    param([string]$Name,
        [int]$MaxLength=25
    )

    # If there's a '?', take only the part before it
    $BaseName = $Name -split '\?' | Select-Object -First 1

    # Extract extension (including the dot), if present
    $Extension = [System.IO.Path]::GetExtension($BaseName)
    $NameWithoutExt = [System.IO.Path]::GetFileNameWithoutExtension($BaseName)

    # Sanitize name and extension
    $SafeName = $NameWithoutExt -replace '[\\\/:*?"<>|]', '_'
    $SafeExt = $Extension -replace '[\\\/:*?"<>|]', '_'

    # Truncate base name to 25 chars
    if ($SafeName.Length -gt $MaxLength) {
        $SafeName = $SafeName.Substring(0, $MaxLength)
    }

    return "$SafeName$SafeExt"
}
function Normalize-And-ConvertImage {
    param (
        [string]$InputPath,
        [int]$MaxLength = 64
    )

    $original = $InputPath
    $originalExt = [IO.Path]::GetExtension($InputPath)
    $originalName = [IO.Path]::GetFileNameWithoutExtension($InputPath)

    if (-not (Test-Path $WorkingDirectory)) {
        New-Item -ItemType Directory -Path $WorkingDirectory -Force | Out-Null
    }

    # Create a safe temp copy before doing anything else
    $safeName = [guid]::NewGuid().ToString() + $originalExt
    $safePath = Join-Path $WorkingDirectory $safeName
    write-verbose "MOVING IMAGE FROM $InputPath to SAFE PATH $safePath"

    # -LiteralPath: $InputPath is a concrete file and can contain [ ] (e.g. "[ADP]"), which -Path would treat as wildcards
    Copy-Item -LiteralPath $InputPath -Destination $safePath -Force

    # If no extension, guess and rename
    if (-not $originalExt) {
        write-verbose "NO EXTENTION FOR PRESUMED IMAGE: $InputPath"
        $guessedExt = Get-ImageType $safePath
        if (-not $guessedExt) {
            throw "Unable to determine image type for $InputPath"
        }
        $safePathWithExt = "$safePath.$guessedExt"
        write-verbose "NO EXTENTION IMAGE MOVED TO: $safePathWithExt"
        Move-Item -Path $safePath -Destination $safePathWithExt -Force
        $safePath = $safePathWithExt
    }

    # Detect type
    $type = Get-ImageType $safePath
    $detectedAs = $type
    write-verbose "IMAGE AT SAFEPATH $safePath detected as $detectedAs"

    $preserveExt = @('jpg', 'jpeg', 'png') -contains $type

    # Convert if needed
    if ($type -and -not $preserveExt) {
        write-verbose "IMAGE TYPE NOT IN ALLOWABLE SET... $safePath => $detectedAs converting to jpg"
        $Magick = $null
        $Magick = New-Object ImageMagick.MagickImage($safePath)
        try {
            $convertedPath = [System.IO.Path]::ChangeExtension($safePath, 'jpg')
            $Magick.Format = [ImageMagick.MagickFormat]::Jpeg
            $Magick.Write($convertedPath)
            $safePath = $convertedPath
            $type = 'jpg'
        }
        finally {
            if ($Magick) { $Magick.Dispose() }
        }
    }

    # Normalize name
    $filename = [IO.Path]::GetFileName($safePath)
    $directory = [IO.Path]::GetDirectoryName($safePath)
    $normalized = Normalize-String -InputString $filename -PreserveExtension -PreserveWhitespace
    $limited = Limit-FilenameLength -FullFilename $normalized -MaxLength $MaxLength -PreserveExtension
    write-verbose "IMAGE FILENAME $InputPath NORMALIZED and LIMITED from $limited TO $normalized"

    # Rebuild parts
    $extension = [IO.Path]::GetExtension($limited)
    $basename = [IO.Path]::GetFileNameWithoutExtension($limited)

    if (-not $basename) { $basename = "file" }
    if (-not $extension) { $extension = ".$type" }

    if ($basename.Length -lt 5) {
        $basename = $basename.PadRight(5, '_')
        write-verbose "IMAGE BASENAME ($basename) from $InputPath NORMALIZED TO $basename"
    }

    $finalFilename = "$basename$extension".ToLower()
    $finalPath = Join-Path -Path $directory -ChildPath $finalFilename

    if ($safePath -ne $finalPath) {
        Copy-Item -Path $safePath -Destination $finalPath -Force
        write-verbose "FINAL IMAGE FROM $InputPath PLACED AS $safePath"
    }

    return @{
        FinalPath  = $finalPath
        Original   = $original
        Extention  = $extension
        DetectedAS = $detectedAs
        BaseName   = $basename
    }
}
