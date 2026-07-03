# Normalise an IT Glue OTP/TOTP secret into a base32 seed Hudu will accept, or $null if it isn't one.
#
# IT Glue stores the seed in a few shapes that the migration's original validation rejected outright
# (and then silently dropped): an `otpauth://` URI, a seed with `=` padding or display spaces, or a
# genuinely long-but-valid base32 seed that tripped an arbitrary 80-char cap. This normaliser handles
# all of those, so it is the single source of truth for both the live backfill
# (Backfill-PasswordOTPSeeds.ps1) and the migration's own password import.
#
# Returns the cleaned uppercase base32 seed, or $null when the input is empty or not a usable base32
# secret after normalisation (the caller decides how to report a non-empty input that yields $null).

function ConvertTo-NormalizedOtpSecret {
    [OutputType([string])]
    param(
        [Parameter(Position = 0)]
        [AllowNull()][AllowEmptyString()]
        [string]$Secret
    )

    if ([string]::IsNullOrWhiteSpace($Secret)) { return $null }
    $s = $Secret.Trim()

    # otpauth://totp/Label?secret=<BASE32>&issuer=... -> take the secret parameter
    $m = [regex]::Match($s, '(?i)otpauth://[^\s]*[?&]secret=([^&\s]+)')
    if ($m.Success) {
        $s = try { [uri]::UnescapeDataString($m.Groups[1].Value) } catch { $m.Groups[1].Value }
    }

    # strip display whitespace and '=' padding, then normalise case
    $s = ($s -replace '\s', '') -replace '=+$', ''
    $s = $s.ToUpperInvariant()

    # RFC 4648 base32 alphabet only (A-Z, 2-7). 16 chars ~= 80-bit seed minimum; the old 80-char
    # UPPER cap is dropped - long seeds are valid - but keep a sane ceiling to reject obvious garbage.
    if ($s -match '^[A-Z2-7]+$' -and $s.Length -ge 16 -and $s.Length -le 1024) {
        return $s
    }
    return $null
}
