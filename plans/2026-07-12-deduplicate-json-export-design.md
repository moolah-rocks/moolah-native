# Deduplicated JSON Export Design

**Date:** 2026-07-12  
**Status:** Design (no implementation yet)  
**Issue:** [#1303 — Deduplicate JSON Export](https://github.com/moolah-rocks/moolah-native/issues/1303)

## Goal

Make profile JSON exports reference instruments by ID everywhere outside the top-level
`instruments` catalogue. A current export must contain each full instrument definition once,
while Moolah must continue to import version 1 files that embed full instruments in accounts,
groups, earmarks, amounts, transaction legs, and investment values.

## Current format and source of growth

`ExportedData` currently serialises domain models directly. Each model's normal `Codable`
conformance embeds an entire `Instrument` value. The export also contains the same definitions in
its top-level `instruments` array.

The repeated objects occur in:

- every account and account group;
- every earmark and its optional savings target;
- every earmark budget amount;
- every transaction leg; and
- every recorded investment value.

Investment histories and transaction legs dominate the growth because their collections can be
large. The other exported relationships are already ID-based: transaction legs use account,
category, and earmark IDs; categories use parent IDs; account membership uses group IDs; and the
investment-value dictionary uses account IDs. There is no other embedded entity graph that offers
a comparable deduplication win.

Pretty printing remains unchanged. It makes exports inspectable and is independent of the
duplicate-data bug. Compression or a compact JSON presentation can be considered separately if
file size remains a problem after instrument deduplication.

## Format version 2

Version 2 keeps full definitions only in `instruments`. Every other instrument-bearing wire value
uses `instrumentId`:

```json
{
  "version": 2,
  "instruments": [
    {
      "id": "ASX:BHP.AX",
      "kind": "stock",
      "name": "BHP",
      "decimals": 0,
      "ticker": "BHP.AX",
      "exchange": "ASX"
    }
  ],
  "accounts": [
    {
      "id": "…",
      "name": "Brokerage",
      "instrumentId": "ASX:BHP.AX"
    }
  ],
  "transactions": [
    {
      "id": "…",
      "legs": [
        {
          "id": "…",
          "accountId": "…",
          "quantity": 10,
          "instrumentId": "ASX:BHP.AX",
          "type": "transfer"
        }
      ]
    }
  ],
  "investmentValues": {
    "…account id…": [
      {
        "date": "2026-07-12T00:00:00Z",
        "value": {
          "quantity": 1234.56,
          "instrumentId": "ASX:BHP.AX"
        }
      }
    ]
  }
}
```

The abbreviated example omits unrelated existing fields; their keys and semantics do not change.
`InstrumentAmount` values retain both `quantity` and `instrumentId`. The instrument cannot be
inferred safely from an owning account or earmark because the persisted model permits values and
legs to carry their own instrument.

Use a named `instrumentId` key instead of overloading `instrument` with either an object or a
string. This gives version 2 one unambiguous shape and makes malformed files easier to diagnose.

## Architecture

### Separate in-memory data from the wire format

Keep `ExportedData` as the fully hydrated in-memory aggregate consumed by `DataExporter`,
`CloudKitDataImporter`, and `ImportVerifier`. Move file serialisation behind a new
`ExportDocumentCodec` in `Shared/Export/`:

```swift
struct ExportDocumentCodec {
  func encode(_ data: ExportedData) throws -> Data
  func decode(_ bytes: Data) throws -> ExportedData
}
```

The codec owns ISO-8601 dates, sorted/pretty-printed JSON, version dispatch, wire-to-domain
conversion, and reference validation. `ExportCoordinator` becomes its production call site.
Tests that need to inspect an export also use the codec instead of reaching through
`JSONEncoder.exportEncoder` or `JSONDecoder.exportDecoder`.

Do not change `Instrument`, `InstrumentAmount`, or the other domain models' normal `Codable`
conformances. Those conformances are used outside profile exports and do not have access to the
top-level instrument catalogue. Encoder `userInfo`, coding-path checks, global decode context, and
JSON post-processing would make domain decoding context-dependent or risk changing `Decimal`
values; the explicit wire boundary avoids those problems.

### Versioned wire DTOs

Add private/export-internal wire DTOs under `Shared/Export/Wire/`:

- `ExportVersionEnvelope` decodes only `version` for dispatch.
- `ExportDocumentV1` mirrors the current shape and decodes embedded domain instruments.
- `ExportDocumentV2` mirrors the top-level shape with v2 reference-bearing DTOs.
- Focused v2 DTOs cover account, account group, earmark, earmark budget item,
  `InstrumentAmount`, transaction/leg, and investment value.

The v2 DTOs explicitly copy the existing persisted fields and convert to/from domain values. This
is deliberate duplication at the serialization boundary: adding a domain field then requires an
explicit export-format decision and tests, rather than silently changing backup files through
synthesised `Codable`.

Define one format constant rather than spreading numeric literals:

```swift
enum ExportFormatVersion {
  static let current = 2
  static let oldestSupported = 1
}
```

`DataExporter` creates `ExportedData` at `current`. The decoder accepts versions 1 and 2 and
rejects anything newer before decoding its version-specific body. The existing unsupported-version
error remains user-facing.

### Reference resolution and validation

When encoding v2:

1. Build `[String: Instrument]` from `ExportedData.instruments`.
2. Reject duplicate IDs whose definitions differ. Identical duplicate entries should also be
   normalised to one catalogue entry so new exports are canonical.
3. Walk every instrument-bearing value and require its exact instrument definition to match the
   catalogue entry for its ID.
4. Encode the reference-bearing DTOs only after the catalogue is complete and valid.

`DataExporter.collectInstruments` must include instruments from all exported locations, not only
accounts, groups, and transaction legs. Add earmarks, savings targets, budget items, and investment
values to make catalogue closure explicit. This also protects future data shapes where a child
instrument differs from its owner.

When decoding v2:

1. Decode and validate the catalogue into `[String: Instrument]`.
2. Resolve every `instrumentId` through that map while constructing domain values.
3. Throw `DecodingError.dataCorrupted` with the wire coding path and missing/conflicting ID if a
   reference cannot be resolved.

Never invent `Instrument.fiat(code:)` for a missing reference. A broken backup should fail before
any profile is created or database rows are written.

Version 1 decoding does not require the catalogue to rehydrate embedded instruments, because old
exports may have incomplete `instruments` arrays. After decoding, normalise its catalogue by
collecting the embedded definitions before passing the hydrated `ExportedData` to the importer.
This preserves old-file compatibility while ensuring the shared instrument registry sees every
non-fiat definition.

### Coordinator flow

`ExportCoordinator.exportToFile` calls `ExportDocumentCodec.encode` during its existing encoding
stage. Both import entry points call the same codec decode method, removing their duplicated
`JSONDecoder` blocks. The existing atomic write, import transaction, verification, rollback, and
sync-queue behaviour remain unchanged.

The coordinator's version guard moves into the codec so an unsupported document is rejected before
version-specific decoding. Map codec failures through the existing `ExportError.importFailed`
boundary, while preserving `ExportError.unsupportedVersion` as a distinct error.

## Compatibility contract

| Producer | File version | Current app behaviour |
| --- | ---: | --- |
| Moolah before #1303 | 1 | Decode embedded instruments and import successfully |
| Moolah after #1303 | 2 | Resolve instrument IDs from the catalogue and import successfully |
| Future Moolah | >2 | Reject with `unsupportedVersion` before creating a profile |

Forward compatibility with older app builds is not promised: a pre-v2 app will reject a version 2
file, as expected for an intentional wire-format change. Backward compatibility means current and
future builds continue to read valid version 1 backups.

## Tests

Add codec-focused tests before implementation:

- A v2 export contains one full definition per instrument and no nested `instrument` objects.
- Every v2 instrument-bearing location emits the expected `instrumentId`, including savings goals,
  budgets, transaction legs, and investment values.
- A mixed fiat/stock/crypto v2 round trip preserves exact instruments and monetary quantities.
- A checked-in or inline version 1 fixture using embedded instruments still decodes and imports.
- A v1 file with an incomplete catalogue but a valid embedded non-fiat instrument is normalised and
  imports successfully.
- A v2 file with a missing instrument reference fails before profile creation.
- A v2 catalogue with conflicting definitions for one ID fails deterministically.
- Encoding fails if a referenced instrument is absent from, or conflicts with, the catalogue.
- A version greater than 2 produces `ExportError.unsupportedVersion` and does not create a profile.
- A high-cardinality fixture (many transaction legs and investment values) asserts that v2 is
  materially smaller than the equivalent v1 output. Compare byte counts using the same formatting;
  use a ratio threshold loose enough to describe the deduplication property rather than pinning
  encoder whitespace.

Keep the existing end-to-end export/import tests. Update their decode helpers to use
`ExportDocumentCodec` and assert the emitted version is 2. No UI test is required because file
selection, progress, and error presentation do not change.

## Implementation sequence

1. Add failing codec tests and a frozen representative v1 fixture.
2. Introduce format constants, v1/v2 wire DTOs, and `ExportDocumentCodec` with strict reference
   resolution.
3. Expand `DataExporter.collectInstruments` to all instrument-bearing export fields and add closure
   tests.
4. Route export and both import paths through the codec; remove the export-specific raw
   `JSONEncoder`/`JSONDecoder` helpers once all call sites migrate.
5. Update integration and automation tests, run `just format`, `just format-check`, the focused
   export tests, and `just build-mac` with output captured under `.agent-tmp/`.
6. Run the required review cycle before committing: `code-review`, `concurrency-review` for the
   coordinator/actor boundary, and `instrument-conversion-review` for exact instrument and quantity
   preservation. Repeat review and fixes until there are no findings.

## Risks and mitigations

- **A domain field is omitted from a wire DTO.** Conversion tests compare every exported field, and
  explicit DTOs make format changes review-visible.
- **Catalogue/reference drift loses metadata.** Encoding requires exact definition equality;
  decoding resolves exclusively from the validated catalogue.
- **Old backups depend on embedded instruments absent from their catalogue.** The v1 path accepts
  embedded definitions and rebuilds catalogue closure after decoding.
- **Financial precision changes during conversion.** DTOs carry `Decimal` directly through
  `Codable`; the design does not round-trip through `JSONSerialization`, `Double`, or string
  rewriting.
- **The new format reduces size less than expected.** A byte-ratio regression test covers realistic
  high-cardinality data. If whitespace is then the dominant cost, compact presentation or archive
  compression should be evaluated as a separate format decision.

