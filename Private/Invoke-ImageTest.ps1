# Coming improvements to images
# - replace TestImage with using ImageMagick to validate the image
# - Check for extension of the image, and if it doesn't exist rename it with the extension
# - Check for and use the full size image if the image is a thumbnail

function Invoke-ImageTest {
    [CmdletBinding()]
    [OutputType([System.Boolean])]
    param(
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true)]
        [ValidateNotNullOrEmpty()]
        [Alias('PSPath')]
        [string] $FilePath
    )

    $signature = [byte[]]::new(12)
    $stream = $null
    try {
        $stream = [System.IO.File]::Open($FilePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $read = $stream.Read($signature, 0, $signature.Length)

        if (
            ($read -ge 8 -and $signature[0] -eq 0x89 -and $signature[1] -eq 0x50 -and $signature[2] -eq 0x4E -and $signature[3] -eq 0x47) -or
            ($read -ge 3 -and $signature[0] -eq 0xFF -and $signature[1] -eq 0xD8 -and $signature[2] -eq 0xFF) -or
            ($read -ge 6 -and $signature[0] -eq 0x47 -and $signature[1] -eq 0x49 -and $signature[2] -eq 0x46) -or
            ($read -ge 2 -and $signature[0] -eq 0x42 -and $signature[1] -eq 0x4D) -or
            ($read -ge 4 -and (($signature[0] -eq 0x49 -and $signature[1] -eq 0x49 -and $signature[2] -eq 0x2A -and $signature[3] -eq 0x00) -or ($signature[0] -eq 0x4D -and $signature[1] -eq 0x4D -and $signature[2] -eq 0x00 -and $signature[3] -eq 0x2A))) -or
            ($read -ge 12 -and $signature[0] -eq 0x52 -and $signature[1] -eq 0x49 -and $signature[2] -eq 0x46 -and $signature[3] -eq 0x46 -and $signature[8] -eq 0x57 -and $signature[9] -eq 0x45 -and $signature[10] -eq 0x42 -and $signature[11] -eq 0x50)
        ) {
            return $true
        }
    }
    catch {}
    finally {
        if ($stream) { $stream.Dispose() }
    }

    $Magick = $null
    try {
        $Magick = New-Object ImageMagick.MagickImage($FilePath)
        $true
    }
    catch {
        $false
    }
    finally {
        if ($Magick) { $Magick.Dispose() }
    }
}
