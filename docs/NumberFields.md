# Numeric flexible asset fields

On Hudu 2.48.0 or later, ITGlue `Number` starts as `Number` / `number_type: number`
and `Percent` maps to `Number` / `number_type: percentage`. The source `decimals`
setting is retained in the migration log without rounding values. New subtype
attributes are not sent to older Hudu versions. The migration reads back the saved
layout, verifies the requested subtype/currency settings, and validates values
against the saved destination definition and its `min`/`max` settings.

The documented ITGlue field-kind enumeration includes `Number` and `Percent`, but
no Currency kind or currency code. Currency label inference is a heuristic rather
than source metadata. See the [ITGlue API reference](https://api.itglue.com/developer/).
For source Number fields, inference recognizes whole words such as cost, spend,
debt, price, budget, revenue, expense, fee, and payment, plus currency symbols/codes.
Underscores count as word separators. Percent metadata takes precedence. Labels
containing percentages, ratios, counts, identifiers, or cost-center terms are
excluded, as are conflicting currency codes/symbols. Decimal counts alone are
never used to classify currency. Heuristics can still misclassify a field.

Inference is enabled on 2.48.0+ by default, but ambiguous symbols such as `$` and
bare keywords do not establish a currency code. Configure a default once for
your source data to enable these matches:

```powershell
$ITGlueCurrencyInference = @{
    Enabled = $true
    DefaultCurrencyCode = 'USD'
    # DecimalPlacesByCurrency = @{ EUR = 2 } # After verifying target behavior.
}
```

An explicit label code takes precedence over the default; `€` and `£` are
interpreted as EUR and GBP label hints. The code and precision must both resolve
before a heuristic changes the field to currency. Otherwise it remains a plain
number and the reason is logged. Only USD precision is built in from the probe;
other currencies need `DecimalPlacesByCurrency` or a field-level `DecimalPlaces`.
Use `$ITGlueCurrencyInference = @{ Enabled = $false }` to disable label inference.

Explicit field overrides always take precedence, including `NumberType = 'number'`
to prevent an incorrect match. They use the **ITGlue flexible asset field ID** and
must be defined before starting the migration:

```powershell
$ITGlueNumberFieldOverrides = @{
    '12345' = @{ NumberType = 'currency'; CurrencyCode = 'USD' }
}
. .\ITGlue-Hudu-Migration.ps1
```

The layout migration already fetches full field definitions using
`Get-ITGlueFlexibleAssetFields -flexible_asset_type_id ...`. Its
`AssetLayoutsFields.json` log now retains `ITGFieldID` and the complete
`ITGFieldDefinition` for every mapped field. `NumberMappingSource` distinguishes
ITGlue-kind mapping, explicit overrides, and label heuristics.
`NumberMappingReason` and `CurrencyCandidate` explain each match or unresolved
candidate. Matches are also printed during layout migration. A label heuristic
introduces the currency precision checks described below; it is not only a display
change. The same setting/override mechanism lets callers correct false positives.

Overrides can also select `number` or `percentage`. If an export supplies an
explicit `Currency` kind, it still needs a currency-code override; USD is not
assumed. USD's two-decimal precision is the only currency policy verified by the
probe. Other currencies require explicit `DecimalPlaces` or a configured
`DecimalPlacesByCurrency` policy, based on verified target
behavior, e.g. `CurrencyCode = 'JPY'; DecimalPlaces = 0` after testing JPY.
`DecimalPlaces` is local validation policy, not a Hudu layout attribute.

Overrides apply while creating/updating layouts. A resume that skips that stage
uses the mappings in its existing logs. Start a fresh layout migration to apply
new overrides; changing the variable does not retrofit saved mappings.

## Value policy

`Public/ConvertTo-HuduNumber.ps1` sends invariant plain decimal strings. It removes
surrounding whitespace, leading plus signs/zeros, and insignificant trailing zeros
without changing magnitude. Text fields containing numeric-looking identifiers
are not coerced. Null/blank source values are omitted from updates; zero is sent.

- Hudu 2.48.0: enforce the server-reported range `-9223372036854775807` through
  `9223372036854775807`, including fractional parts at the endpoints. Out-of-range
  values are blocked on both create and update: the probe observed successful
  updates storing null for overflow.
- Percentages: maximum 100; negatives allowed unless destination bounds disallow
  them. The migration never multiplies or divides a percentage by 100.
- USD: at most two significant fractional places. Excess precision is reported
  without rounding or truncation. Other currencies require explicit policy.
- Reject symbols, grouping, decimal commas, exponent strings, NaN/Infinity,
  complex values, booleans, arrays, and objects. False/empty collections are
  rejected even though the API sometimes coerces them to null.
- Before 2.48.0: keep the migration's historical Int32 integer envelope without
  rounding. Fractions/overflow require review. This is a conservative migration
  policy, not a claim about all older Hudu storage implementations.

Invalid fields are omitted and recorded with their original value/reason in the
existing manual-action report. Other fields can still migrate. An omitted required
field can still cause the server to reject the update when its destination is
empty; the normal commit reports retain those failures. Values are never replaced
with zero to satisfy a required field.

A source value already deserialized as floating point is formatted invariantly
and emits a warning; precision previously lost at the source cannot be recovered.
Long plain decimal strings retain their precision. UI behavior, other currencies,
and every possible server configuration have not been established by this run.

The shared helper is used in serial/parallel preparation and the companion layout
transfer source script. Keep it with the scripts. Transfer rejects invalid numbers
with warnings and no longer strips non-digits into a value. Prebuilt executables
have not been rebuilt with these changes.

Run `./tests/NumberFields.Tests.ps1` for offline checks. The fixture
`tests/fixtures/number-fields-2.48.0.csv` contains selected observations extracted
from `numresults.csv`, without asset IDs/customer data. No tests contact Hudu.

## Recommended HuduAPI module validation

Use one validator for `New-HuduAsset` and `Set-HuduAsset`, resolving fields against
the actual target layout and server version. Validate the entire proposed payload
before sending it. A library should raise a field-specific error; the migration
can then choose its own omit-and-report policy.

1. Expose/round-trip `number_type`, `currency_code`, `min`, and `max` on layout
   writes; gate attributes by version. Report unknown subtypes rather than
   silently treating them as plain numbers. Cache metadata with refresh support.
2. Serialize finite numeric scalars/plain decimal strings as exact invariant
   decimal strings. Avoid integer/double conversion, culture-dependent parsing,
   symbol stripping, implicit percentage scaling, and automatic currency rounding.
   Existing floating-point inputs cannot promise arbitrary precision.
3. Apply the observed numeric range equally on create and update, using exact
   decimal comparisons. Respect actual min/max, including zero bounds. Do not add
   a blanket ban on negatives or a percentage minimum of zero.
4. Resolve currency precision from authoritative currency metadata or explicit
   caller policy. The experiment establishes USD's two-place rule only; avoid
   applying that limit to every currency.
5. Distinguish omission (leave unchanged), explicit null (intentional clear), and
   zero. Reject bool/collection-to-null coercion. The migration's omission policy
   should not prevent a library caller from intentionally clearing a field.
6. Offer numeric readback verification, comparing decimal magnitudes exactly and
   distinguishing missing/null/value. HTTP success alone did not prove persistence.
   Preserve API errors and report any readback mismatch.

These are recommendations for the separate HuduAPI module; this change does not
edit that repository. Keep policies version-aware and retest when upgrading.
