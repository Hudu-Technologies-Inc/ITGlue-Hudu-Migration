function Get-HuduArticleLocalContentDirectory {
    param(
        [AllowNull()]
        [string]$MigrationLogsPath = $MigrationLogs,

        [AllowNull()]
        [string]$DebugFolderPath = $debugFolder
    )

    if (-not [string]::IsNullOrWhiteSpace($DebugFolderPath)) {
        return Join-Path -Path $DebugFolderPath -ChildPath 'ArticleContent'
    }

    if (-not [string]::IsNullOrWhiteSpace($MigrationLogsPath)) {
        $logsPath = (Resolve-Path -LiteralPath $MigrationLogsPath -ErrorAction SilentlyContinue).Path
        if ([string]::IsNullOrWhiteSpace($logsPath)) {
            $logsPath = $MigrationLogsPath
        }

        $logsItemName = Split-Path -Path $logsPath -Leaf
        if ($logsItemName -ieq 'logs') {
            return Join-Path -Path (Split-Path -Path $logsPath -Parent) -ChildPath 'ArticleContent'
        }

        return Join-Path -Path $logsPath -ChildPath 'ArticleContent'
    }

    throw "A debug folder or MigrationLogs path is required to cache local article content."
}

function Get-HuduArticleLocalContentPath {
    param(
        [Parameter(Mandatory = $true)]
        $Article,

        [AllowNull()]
        [string]$MigrationLogsPath = $MigrationLogs,

        [AllowNull()]
        [string]$DebugFolderPath = $debugFolder
    )

    $contentDirectory = Get-HuduArticleLocalContentDirectory -MigrationLogsPath $MigrationLogsPath -DebugFolderPath $DebugFolderPath
    $articleKey = $Article.HuduID ?? $Article.id ?? $Article.ITGID ?? $Article.ITGLocator ?? $Article.Name
    if ([string]::IsNullOrWhiteSpace([string]$articleKey)) {
        throw "Cannot determine a stable filename for article local content."
    }

    $safeArticleKey = [string]$articleKey
    foreach ($invalidChar in [System.IO.Path]::GetInvalidFileNameChars()) {
        $safeArticleKey = $safeArticleKey.Replace([string]$invalidChar, '-')
    }
    $safeArticleKey = ($safeArticleKey -replace '\s+', '-').Trim([char[]]@('.', '-', ' '))
    if ([string]::IsNullOrWhiteSpace($safeArticleKey)) {
        throw "Cannot determine a stable filename for article local content."
    }

    return Join-Path -Path $contentDirectory -ChildPath "$safeArticleKey.html"
}

function Set-HuduArticleLocalContent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Article,

        [AllowNull()]
        [string]$Content,

        [AllowNull()]
        [string]$MigrationLogsPath = $MigrationLogs,

        [AllowNull()]
        [string]$DebugFolderPath = $debugFolder
    )

    $contentDirectory = Get-HuduArticleLocalContentDirectory -MigrationLogsPath $MigrationLogsPath -DebugFolderPath $DebugFolderPath
    $null = New-Item -Path $contentDirectory -ItemType Directory -Force

    $contentPath = Get-HuduArticleLocalContentPath -Article $Article -MigrationLogsPath $MigrationLogsPath -DebugFolderPath $DebugFolderPath
    Set-Content -LiteralPath $contentPath -Value ([string]$Content) -Encoding UTF8 -NoNewline

    $Article | Add-Member -MemberType NoteProperty -Name LocalContentPath -Value $contentPath -Force
    $Article | Add-Member -MemberType NoteProperty -Name LocalContentPreparedAt -Value (Get-Date).ToString('o') -Force
    $Article | Add-Member -MemberType NoteProperty -Name LocalContentCommittedAt -Value $null -Force

    return $contentPath
}

function Get-HuduArticleLocalContent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Article
    )

    $contentPath = $Article.LocalContentPath
    if ([string]::IsNullOrWhiteSpace([string]$contentPath)) {
        return $null
    }

    if (-not (Test-Path -LiteralPath $contentPath -PathType Leaf -ErrorAction SilentlyContinue)) {
        return $null
    }

    return Get-Content -LiteralPath $contentPath -Raw -Encoding UTF8
}
