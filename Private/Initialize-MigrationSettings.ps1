function Initialize-MigrationSettings {
    param([AllowNull()]$Settings)

    if ($null -eq $Settings) { $Settings = @{} }
    # Old environment files and saved JSON can still contain retired CNAME settings.
    foreach ($name in @('customBrandedDomain', 'ITGCustomDomains')) {
        if ($Settings -is [System.Collections.IDictionary]) {
            [void]$Settings.Remove($name)
        } else {
            $Settings.PSObject.Properties.Remove($name)
        }
    }
    if ($Settings -is [System.Collections.IDictionary]) {
        if ($null -eq $Settings['IncludeITGlueID']) {
            $Settings['IncludeITGlueID'] = $true
        }
    } else {
        $property = $Settings.PSObject.Properties['IncludeITGlueID']
        if ($null -eq $property -or $null -eq $property.Value) {
            $Settings | Add-Member -MemberType NoteProperty -Name IncludeITGlueID -Value $true -Force
        }
    }
    return $Settings
}
