# Shared, comprehensive IT Glue -> Hudu URL rewriter.
#
# The migration's original rewriter (Update-StringWithCaptureGroups in ConvertTo-HuduURL.ps1) only
# handled <a href> anchors for docs/passwords/configurations/assets and required href to be the first
# attribute, so plain-text URLs, other entity types (contacts/locations/websites), kb.itglue.com and
# many reordered-attribute anchors were left pointing at IT Glue. This function does a direct URL-string
# replacement against ITGlue-ID -> Hudu-URL maps, so it catches every form (anchor and plain-text,
# encoded or not, any entity type).
#
# Policy: rewrite every URL whose target WAS migrated to its Hudu URL; leave links to items that were
# NOT migrated (deleted in IT Glue, index/list pages) untouched and return them as dead links for
# reporting. It never strips or invents a destination, so it is safe to run over any content.
#
# Used by BOTH the migration (ITGlue-Hudu-Migration.ps1 link-replacement pass) and the standalone
# Recover-AllITGlueUrls.ps1 remediation script - single source of truth.

function ConvertTo-FullHuduUrl {
    param([string]$Url, [string]$HuduBaseDomain)
    if ([string]::IsNullOrWhiteSpace($Url)) { return $Url }
    if ($Url -match '^https?://') { return $Url }
    return ($HuduBaseDomain.TrimEnd('/') + '/' + $Url.TrimStart('/'))
}

function Get-ITGlueUrlMaps {
    <#
    .SYNOPSIS
    Build the ITGlue-ID -> Hudu-URL lookup maps used by Update-AllITGlueUrls, from the migration's
    matched-object collections (or the equivalent *.json logs loaded into the same shape).

    .DESCRIPTION
    Each matched object is expected to expose .ITGID and .HuduObject.url (websites store a relative
    url, which is expanded with the Hudu base domain). Articles additionally map their .ITGLocator so
    DOC-<company>-<doc> locator links resolve. Any collection may be $null/empty.
    #>
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '',
        Justification = 'Params are matched-object collections (password *records*), not secrets.')]
    param(
        [Parameter(Mandatory)][string]$HuduBaseDomain,
        $Articles, $Passwords, $AssetPasswords, $Configurations, $Assets, $Contacts, $Locations, $Websites
    )

    function New-Map($items) {
        $h = @{}
        foreach ($x in @($items)) {
            if ($null -ne $x -and $x.ITGID -and $x.HuduObject.url) {
                $h["$($x.ITGID)"] = (ConvertTo-FullHuduUrl -Url ([string]$x.HuduObject.url) -HuduBaseDomain $HuduBaseDomain)
            }
        }
        return $h
    }

    # passwords + embedded (asset) passwords share IT Glue's /passwords/<id> space
    $passwordMap = New-Map $Passwords
    foreach ($x in @($AssetPasswords)) {
        if ($null -ne $x -and $x.ITGID -and $x.HuduObject.url -and -not $passwordMap.ContainsKey("$($x.ITGID)")) {
            $passwordMap["$($x.ITGID)"] = (ConvertTo-FullHuduUrl -Url ([string]$x.HuduObject.url) -HuduBaseDomain $HuduBaseDomain)
        }
    }

    # DOC-locator ( /DOC-123-456 ) -> article Hudu URL
    $docLocator = @{}
    foreach ($x in @($Articles)) {
        if ($null -ne $x -and $x.ITGLocator -and $x.HuduObject.url) {
            $docLocator["$($x.ITGLocator)"] = (ConvertTo-FullHuduUrl -Url ([string]$x.HuduObject.url) -HuduBaseDomain $HuduBaseDomain)
        }
    }

    return @{
        docs           = New-Map $Articles
        passwords      = $passwordMap
        configurations = New-Map $Configurations
        assets         = New-Map $Assets
        contacts       = New-Map $Contacts
        locations      = New-Map $Locations
        websites       = New-Map $Websites
        doclocator     = $docLocator
    }
}

function Update-AllITGlueUrls {
    <#
    .SYNOPSIS
    Rewrite every migrated IT Glue URL in a string to its Hudu URL; report the rest as dead links.

    .PARAMETER Content   The HTML/text to rewrite.
    .PARAMETER Maps       Output of Get-ITGlueUrlMaps.
    .PARAMETER ItgDomain  The customer IT Glue host (e.g. enstep.itglue.com) used to read entity ids.

    .OUTPUTS
    [pscustomobject] with:
      Content   - the rewritten string (unchanged if nothing matched)
      Rewritten - count of URLs re-pointed to Hudu
      DeadLinks - array of @{ Url; Type; Id } for IT Glue links whose target was not migrated
                  (image URLs are excluded - those are handled by the image pipeline)
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$Content,
        [Parameter(Mandatory)][hashtable]$Maps,
        [Parameter(Mandatory)][string]$ItgDomain
    )

    if ([string]::IsNullOrEmpty($Content) -or $Content -notmatch 'itglue\.com') {
        return [pscustomobject]@{ Content = $Content; Rewritten = 0; DeadLinks = @() }
    }

    $itgHostRx = [regex]::Escape($ItgDomain)     # e.g. enstep\.itglue\.com
    # A MatchEvaluator scriptblock can read enclosing variables and mutate reference types (Lists) via
    # closure, but a scalar ++ inside it would not propagate - so count rewrites by List length.
    $dead   = [System.Collections.Generic.List[object]]::new()
    $mapped = [System.Collections.Generic.List[object]]::new()

    # Match ANY http(s) URL that mentions itglue.com (customer host, kb.itglue.com, or an encoded
    # redirect wrapper). Decode before parsing so wrapped/encoded enstep URLs are read correctly.
    $new = [regex]::Replace($Content, 'https?://[^\s"''<>\)]*?itglue\.com[^\s"''<>\)]*', {
        param($m)
        $u   = $m.Value
        $dec = try { [uri]::UnescapeDataString($u) } catch { $u }

        # image links are owned by the image-replacement pass - never touch or report them here
        if ($dec -match "$itgHostRx/\d+/docs/\d+/images/") { return $u }

        # DOC-<company>-<doc> locator links (absolute or the encoded host form)
        $docLoc = [regex]::Match($dec, "$itgHostRx/(DOC-[0-9]+-[0-9]+)", 'IgnoreCase')
        if ($docLoc.Success) {
            $loc = $docLoc.Groups[1].Value
            if ($Maps.doclocator.ContainsKey($loc)) { $mapped.Add(1); return $Maps.doclocator[$loc] }
            $dead.Add(@{ Url = $u; Type = 'doclocator'; Id = $loc }); return $u
        }

        # flexible-asset record urls: /<org>/assets/<layout>/records/<id>
        $assetM = [regex]::Match($dec, "$itgHostRx/\d+/assets/(?:[^/\s]+/)?records/(\d+)", 'IgnoreCase')
        # everything else: /<org>/<type>/<id>
        $genM   = [regex]::Match($dec, "$itgHostRx/\d+/(docs|documents|passwords|configurations|contacts|locations|websites)/(\d+)", 'IgnoreCase')

        if ($assetM.Success) {
            $type = 'assets'; $eid = $assetM.Groups[1].Value
        } elseif ($genM.Success) {
            $type = $genM.Groups[1].Value.ToLower(); if ($type -eq 'documents') { $type = 'docs' }
            $eid = $genM.Groups[2].Value
        } else {
            # a bare index/list page (or an unrecognised itglue url) - no id to map
            $dead.Add(@{ Url = $u; Type = 'index'; Id = '' }); return $u
        }

        if ($Maps.ContainsKey($type) -and $Maps[$type].ContainsKey($eid)) {
            $mapped.Add(1)
            return $Maps[$type][$eid]
        }
        $dead.Add(@{ Url = $u; Type = $type; Id = $eid }); return $u
    }, 'IgnoreCase')

    return [pscustomobject]@{ Content = $new; Rewritten = $mapped.Count; DeadLinks = @($dead) }
}
