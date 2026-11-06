function Test-ITGlueIntegratorLayout {
    param([AllowNull()][string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    $Name = $Name.Trim()

    return (
        $Name -ilike '*(auto)*' -or
        $Name -ilike '*(liongard)*' -or
        $Name -ilike '*datto*rmm*' -or
        $Name -ilike '*connectwise*' -or
        $Name -ilike '*autotask*' -or
        $Name -imatch '^Office 365 Licenses \[([0-9a-f]{4}([0-9a-f]{2})?|Disconnected)\]$' -or
        $Name -in @('Microsoft 365: Groups', 'Entra ID: Security Groups')
    )
}
