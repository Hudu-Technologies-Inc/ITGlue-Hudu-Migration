function Resolve-ImageFilePath {
    [CmdletBinding()]
    [OutputType([System.IO.FileInfo])]
    param(
        [AllowNull()]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    $trimmedPath = $Path.Trim().Trim('"', "'")
    $candidatePaths = @($trimmedPath)

    if ($trimmedPath -match '^file:') {
        try {
            $candidatePaths += ([uri]$trimmedPath).LocalPath
        } catch {}
    }

    foreach ($candidatePath in @($candidatePaths)) {
        try {
            $decodedPath = [uri]::UnescapeDataString($candidatePath)
            if ($decodedPath -ne $candidatePath) {
                $candidatePaths += $decodedPath
            }
        } catch {}

        $querylessPath = $candidatePath -replace '[?#].*$', ''
        if ($querylessPath -ne $candidatePath) {
            $candidatePaths += $querylessPath
        }
    }

    foreach ($candidatePath in ($candidatePaths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)) {
        if (Test-Path -LiteralPath $candidatePath -PathType Leaf -ErrorAction SilentlyContinue) {
            return Get-Item -LiteralPath $candidatePath -ErrorAction SilentlyContinue
        }

        $parentPath = [System.IO.Path]::GetDirectoryName($candidatePath)
        $leafName = [System.IO.Path]::GetFileName($candidatePath)

        if ([string]::IsNullOrWhiteSpace($leafName)) {
            continue
        }

        if ([string]::IsNullOrWhiteSpace($parentPath)) {
            $parentPath = '.'
        }

        if (Test-Path -LiteralPath $parentPath -PathType Container -ErrorAction SilentlyContinue) {
            $foundFile = Get-ChildItem -LiteralPath $parentPath -File -Filter "$leafName*" -ErrorAction SilentlyContinue |
                Select-Object -First 1

            if ($foundFile) {
                return $foundFile
            }
        }
    }

    return $null
}
