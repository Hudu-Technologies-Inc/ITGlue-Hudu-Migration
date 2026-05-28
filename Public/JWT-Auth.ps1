function Get-ITGlueJWTAuth{
    param ([string]$ITglueJWT, [string]$ITGBaseURI)
    $ITGlueJWT = $ITGlueJWT ?? (Read-Host "Please enter your ITGlue JWT as retrieved from browser.")
    Clear-Host

    while ($true){
        Write-Host "Testing provided JWT"
        try {
            $null = Get-ITGlueCheckLists -JWTAuthToken $ITGlueJWT -page_size $PageSize -page_number $PageNum -ITGBaseURI $ITGAPIEndpoint
            Write-host "successful authentication"
            return $ITglueJWT   
        } catch {
            Write-Host "Issue retrieving data with JWT auth. $_; Re-enter a fresh JWT if possible or enter 0 to cancel"
            $ITGlueJWT = Read-Host "Please enter your ITGlue JWT as retrieved from browser."
            Clear-Host
            if ("$ITGlueJWT".Trim() -eq "0"){break}
        }
    }
    return $ITglueJWT
}