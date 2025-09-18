# --- Safe, idempotent helpers (renamed) ---

if (-not $script:FolderCache) { $script:FolderCache = @{} }

function Get-NormalizedFolderName {
    param([Parameter(Mandatory)][string]$Name)
    $n = $Name.Trim()
    [regex]::Replace($n, '\s+', ' ')
}

function Get-FolderCacheKey {
    param([object]$CompanyId, [object]$ParentId, [Parameter(Mandatory)][string]$Name)
    $cid = if ($null -ne $CompanyId) { "$CompanyId" } else { '-' }
    $parentID = if ($null -ne $ParentId)  { "$ParentId" }  else { '-' }
    "$cid|$parentID|$($Name.ToLowerInvariant())"
}

function Get-OrCreateHuduFolderSafe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [object]$CompanyId,
        [object]$ParentId,
        [switch]$AllowRenameSuffix,
        [int]$MaxSuffix = 20
    )

    $name = Get-NormalizedFolderName $Name
    $key  = Get-FolderCacheKey -CompanyId $CompanyId -ParentId $ParentId -Name $name
    if ($script:FolderCache.ContainsKey($key)) { return $script:FolderCache[$key] }

    # ---- 1) Try exact match under intended parent
    $candidates = Get-HuduFolders -Name $name
    $exact = $candidates | Where-Object {
        ($_.parent_folder_id -eq $ParentId) -and
        ($_.company_id -eq $(if ($CompanyId) { $CompanyId } else { $null }))
    } | Select-Object -First 1

    if ($exact) { $script:FolderCache[$key] = $exact; return $exact }

    # ---- 2) Fallback: same scope (global vs company), ignore parent
    $scopeMatches = $candidates | Where-Object {
        ($_.company_id -eq $(if ($CompanyId) { $CompanyId } else { $null }))
    }

    if ($scopeMatches.Count -eq 1) {
        $script:FolderCache[$key] = $scopeMatches[0]
        return $scopeMatches[0]
    }

    # ---- 3) Create (may race)
    try {
        $splat = @{ Name = $name }
        if ($CompanyId) { $splat.company_id = $CompanyId }
        if ($ParentId)  { $splat.parent_folder_id  = $ParentId }
        $created = New-HuduFolder @splat
        $folder  = if ($created.folder) { $created.folder } else { $created }
        if ($folder) { $script:FolderCache[$key] = $folder; return $folder }
    } catch {
        $msg = "$($_.Exception.Message)"
        # ---- 4) Duplicate/race: refetch by name in scope (ignore parent)
        if ($msg -match 'has already been taken' -or $msg -match '422' -or $msg -match '409') {
            $refetch = Get-HuduFolders -Name $name | Where-Object {
                ($_.company_id -eq $(if ($CompanyId) { $CompanyId } else { $null }))
            } | Select-Object -First 1
            if ($refetch) { $script:FolderCache[$key] = $refetch; return $refetch }
        }
        if (-not $AllowRenameSuffix) { throw }
    }

    # ---- 5) Optional suffix flow unchanged...
    for ($i=2; $i -le $MaxSuffix; $i++) {
        $alt = "$name ($i)"
        $altKey = Get-FolderCacheKey -CompanyId $CompanyId -ParentId $ParentId -Name $alt
        if ($script:FolderCache.ContainsKey($altKey)) { return $script:FolderCache[$altKey] }

        $existsAlt = Get-HuduFolders -Name $alt | Where-Object {
            ($_.company_id -eq $(if ($CompanyId) { $CompanyId } else { $null }))
        } | Select-Object -First 1
        if ($existsAlt) { $script:FolderCache[$altKey]=$existsAlt; return $existsAlt }

        try {
            $s = @{ Name=$alt }
            if ($CompanyId) { $s.company_id = $CompanyId }
            if ($ParentId)  { $s.parent_folder_id  = $ParentId }
            $created = New-HuduFolder @s
            $folder  = if ($created.folder) { $created.folder } else { $created }
            if ($folder) { $script:FolderCache[$altKey]=$folder; return $folder }
        } catch {
            $m = "$($_.Exception.Message)"
            if ($m -notmatch 'has already been taken' -and $m -notmatch '422' -and $m -notmatch '409') { throw }
        }
    }
    throw "Unable to create a unique folder for '$name' after $MaxSuffix attempts."
}

function Get-EnsuredHuduFolderPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$PathParts,
        [object]$CompanyId,
        [object]$StartParentId,
        [switch]$AllowRenameSuffix
    )

    $parentId = $StartParentId
    $folder   = $null
    foreach ($segRaw in $PathParts | Where-Object { $_ -and $_.Trim() }) {
        $seg = Get-NormalizedFolderName $segRaw
        $folder = Get-OrCreateHuduFolderSafe -Name $seg -CompanyId $CompanyId -ParentId $parentId -AllowRenameSuffix:$AllowRenameSuffix
        $parentId = $folder.id
    }
    return $folder
}
