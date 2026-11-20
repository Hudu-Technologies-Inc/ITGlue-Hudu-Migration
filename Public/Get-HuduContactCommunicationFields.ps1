# Native contact fields hold one value; keep the remaining details in rich text.
function Get-HuduContactCommunicationFields {
    param(
        [AllowNull()]
        [object]$Attributes
    )

    function Get-ContactProperty {
        param([AllowNull()][object]$Item, [string]$Name)
        if ($null -eq $Item) { return $null }
        if ($Item -is [System.Collections.IDictionary]) { return $Item[$Name] }
        $property = $Item.PSObject.Properties[$Name]
        if ($null -ne $property) { return $property.Value }
        return $null
    }

    $emails = [System.Collections.Generic.List[object]]::new()
    foreach ($email in @(Get-ContactProperty $Attributes 'contact-emails')) {
        $value = [string](Get-ContactProperty $email 'value')
        if ([string]::IsNullOrWhiteSpace($value)) { continue }
        $label = [string](Get-ContactProperty $email 'label-name')
        if ([string]::IsNullOrWhiteSpace($label)) { $label = 'Email' }
        $emails.Add([pscustomobject]@{
            Index = $emails.Count
            Value = $value.Trim()
            Label = $label
            Primary = ((Get-ContactProperty $email 'primary') -eq $true)
        })
    }

    $phones = [System.Collections.Generic.List[object]]::new()
    foreach ($phone in @(Get-ContactProperty $Attributes 'contact-phones')) {
        $value = [string](Get-ContactProperty $phone 'value')
        $displayValue = [string](Get-ContactProperty $phone 'formatted-value')
        $extension = [string](Get-ContactProperty $phone 'extension')
        if ([string]::IsNullOrWhiteSpace($value)) { $value = $displayValue }
        if ([string]::IsNullOrWhiteSpace($displayValue)) { $displayValue = $value }
        if ([string]::IsNullOrWhiteSpace($value) -and [string]::IsNullOrWhiteSpace($extension)) { continue }
        $label = [string](Get-ContactProperty $phone 'label-name')
        if ([string]::IsNullOrWhiteSpace($label)) { $label = 'Phone' }
        # Within each label preference, primary wins, then original source order.
        $preference = switch -Regex ($label.Trim()) {
            '^Direct(?:\s+Phone)?$' { 0; break }
            '^Work(?:\s+Phone)?$' { 1; break }
            default { 2 }
        }
        $phones.Add([pscustomobject]@{
            Index = $phones.Count
            Value = $value.Trim()
            DisplayValue = $displayValue
            Extension = $extension
            Label = $label
            Primary = ((Get-ContactProperty $phone 'primary') -eq $true)
            Preference = $preference
        })
    }

    $primaryOrder = @{ Expression = { if ($_.Primary) { 0 } else { 1 } } }
    $selectedEmail = $emails | Sort-Object -Property $primaryOrder, Index | Select-Object -First 1
    $selectedPhone = $phones | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Value) } |
        Sort-Object -Property Preference, $primaryOrder, Index | Select-Object -First 1

    $phoneLinks = [System.Collections.Generic.List[string]]::new()
    foreach ($phone in $phones) {
        # Keep the grid phone's extension in Notes as well, so dialing details survive.
        if ($null -ne $selectedPhone -and $phone.Index -eq $selectedPhone.Index -and
            [string]::IsNullOrWhiteSpace($phone.Extension)) { continue }
        $text = "$($phone.Label): $($phone.DisplayValue)"
        $target = 'tel:' + [Uri]::EscapeDataString($phone.Value).Replace('%2B', '+')
        if (-not [string]::IsNullOrWhiteSpace($phone.Extension)) {
            $text += " ext. $($phone.Extension)"
            $target += ';ext=' + [Uri]::EscapeDataString($phone.Extension.Trim())
        }
        $text = [System.Net.WebUtility]::HtmlEncode($text)
        if ([string]::IsNullOrWhiteSpace($phone.Value)) {
            $phoneLinks.Add("<li>$text</li>")
        } else {
            $target = [System.Net.WebUtility]::HtmlEncode($target)
            $phoneLinks.Add("<li><a href=`"$target`">$text</a></li>")
        }
    }

    $emailLinks = [System.Collections.Generic.List[string]]::new()
    foreach ($email in $emails) {
        if ($null -ne $selectedEmail -and $email.Index -eq $selectedEmail.Index) { continue }
        $text = [System.Net.WebUtility]::HtmlEncode("$($email.Label): $($email.Value)")
        $target = [System.Net.WebUtility]::HtmlEncode('mailto:' + [Uri]::EscapeDataString($email.Value).Replace('%40', '@'))
        $emailLinks.Add("<li><a href=`"$target`">$text</a></li>")
    }

    $notes = [System.Collections.Generic.List[string]]::new()
    $sourceNotes = [string](Get-ContactProperty $Attributes 'notes')
    if (-not [string]::IsNullOrWhiteSpace($sourceNotes)) { $notes.Add($sourceNotes) }
    if ($phoneLinks.Count -gt 0 -or $emailLinks.Count -gt 0) {
        $notes.Add('<h3>Additional contact details</h3>')
        if ($phoneLinks.Count -gt 0) { $notes.Add('<h4>Phones</h4><ul>' + ($phoneLinks -join '') + '</ul>') }
        if ($emailLinks.Count -gt 0) { $notes.Add('<h4>Emails</h4><ul>' + ($emailLinks -join '') + '</ul>') }
    }

    return @{
        emails = if ($null -ne $selectedEmail) { $selectedEmail.Value } else { $null }
        phones = if ($null -ne $selectedPhone) { $selectedPhone.Value } else { $null }
        notes = $notes -join "`n"
    }
}
