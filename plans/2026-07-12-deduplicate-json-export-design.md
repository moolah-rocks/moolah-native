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
keeps its existing `instrument` key but encodes the value as an instrument ID string:

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
      "instrument": "ASX:BHP.AX"
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
          "instrument": "ASX:BHP.AX",
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
          "instrument": "ASX:BHP.AX"
        }
      }
    ]
  }
}
```

The abbreviated example omits unrelated existing fields; their keys and semantics do not change.
`InstrumentAmount` values retain both `quantity` and `instrument`. The instrument cannot be
inferred safely from an owning account or earmark because the persisted model permits values and
legs to carry their own instrument.

Keeping the existing property key is what lets parent models retain synthesised or existing
`Codable` implementations. The top-level version makes the value shape unambiguous: version 1 has
a full object at `instrument`, while version 2 has its ID string.

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

The codec owns ISO-8601 dates, sorted/pretty-printed JSON, version dispatch, export-specific
instrument coding context, and reference validation. `ExportCoordinator` becomes its production
call site.
Tests that need to inspect an export also use the codec instead of reaching through
`JSONEncoder.exportEncoder` or `JSONDecoder.exportDecoder`.

### Preserve automatic domain-field encoding

Do not mirror accounts, earmarks, transactions, or other domain objects into export-only DTOs.
They continue to encode through their existing `Codable` conformances. Consequently, adding a new
field to one of those models follows its existing Codable rules:

- a model with synthesised `Codable` includes the field automatically; and
- a model with a hand-written conformance is updated once in that model, as it already must be for
  every Codable use, with no second export serializer to remember.

Only the representation of `Instrument` changes while the export codec is active. Introduce
export-specific contexts carried in `Encoder.userInfo` / `Decoder.userInfo`:

```swift
final class InstrumentReferenceCodingContext: Sendable {
  private let instrumentsById: OSAllocatedUnfairLock<[String: Instrument]>

  func install(_ instruments: [Instrument]) throws
  func resolve(id: String, codingPath: [any CodingKey]) throws -> Instrument
}
```

The context holds the catalogue and marks nested instruments as references. Its mutable catalogue
is lock-protected to satisfy the SDK's `Encoder.userInfo` Sendable requirement. A fresh context is
created for each codec pass; it is not global, task-local, or shared across export operations.

Give `Instrument` an explicit `Codable` conformance with two paths:

- with no export context, encode and decode the current full object exactly as today; and
- with the v2 export context, encode as its ID string and decode an ID string through the installed
  catalogue.

All non-export Codable call sites therefore retain their current wire shape. The full-object path
and reference path live beside `Instrument`, so adding instrument metadata has one Codable
maintenance point rather than one per exported parent type.

`ExportedData` needs a custom top-level conformance because `instruments` is the one location that
must bypass reference encoding. A small `FullInstrument` wrapper invokes the full-object path for
catalogue entries; every other top-level property is passed straight to its domain `Codable`
conformance. The existing custom decoder must decode and install `instruments` before decoding
accounts, groups, earmarks, budgets, transactions, or investment values.

`FullInstrument` calls narrowly scoped full-representation helpers on `Instrument` directly. This
avoids duplicating instrument metadata inside the wrapper without adding traversal-wide mutable
mode state to the context.

This leaves only the top-level `ExportedData` field list as an explicit export maintenance point.
That list already defines which repositories belong in a profile backup, so adding a new top-level
entity collection is necessarily an export-format decision. New fields inside existing exported
objects require no export-specific work.

Do not select full/reference encoding by inspecting `codingPath`: a future nested field named
`instruments` could accidentally receive the wrong representation. Do not post-process generic
JSON, which could change `Decimal` representations or replace an unrelated object. The explicit
per-operation context and catalogue wrapper make the two exceptional locations unambiguous.

### Version dispatch

Add `ExportVersionEnvelope`, which decodes only `version`. `ExportDocumentCodec.decode` first reads
that envelope, then chooses one of two configured decoders:

- version 1 uses a normal decoder, so every `Instrument` expects the historical full object; and
- version 2 installs an `ExportInstrumentDecodingContext`, so catalogue entries decode in full and
  all later instrument occurrences resolve ID strings.

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

1. Seed a discovery context from `ExportedData.instruments`, rejecting conflicting duplicate IDs.
2. Perform a discarded discovery encode. Every nested `Instrument.encode` registers its exact
   definition through normal Codable traversal, so future instrument-bearing fields are included
   without another hand-maintained walk.
3. Freeze the discovered catalogue into a strict context and perform the final encode. Its
   catalogue wrapper emits full instruments while normal nested domain encoding emits IDs.
4. On every nested `Instrument.encode` in the strict pass, require the concrete instrument to
   exactly match the catalogue definition for its ID before emitting the string.

`DataExporter` seeds the profile's fiat instrument. The codec discovers all other referenced
instruments automatically.

When decoding v2, `ExportedData.init(from:)`:

1. Decode full catalogue entries through `FullInstrument` and install the validated map in the
   decoder's context.
2. Decode the remaining domain collections in their existing shape; nested `Instrument` values
   resolve each ID string through that map.
3. Throw `DecodingError.dataCorrupted` with the wire coding path and missing/conflicting ID if a
   reference cannot be resolved.

Never invent `Instrument.fiat(code:)` for a missing reference. A broken backup should fail before
any profile is created or database rows are written.

Version 1 decoding does not use the reference context because embedded instruments are already
complete and old exports may have incomplete `instruments` arrays. After decoding, normalise its
catalogue by collecting the embedded definitions before passing the hydrated `ExportedData` to the
importer. This preserves old-file compatibility while ensuring the shared instrument registry sees
every non-fiat definition.

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
- Every v2 instrument-bearing location emits the expected instrument ID, including savings goals,
  budgets, transaction legs, and investment values.
- An instrument absent from the initial catalogue is discovered through normal Codable traversal.
- Existing ordinary model fields round-trip without export-specific serializers; this pins the
  automatic-field contract.
- Normal, non-export `Instrument` Codable still emits and accepts a full instrument object.
- A mixed fiat/stock/crypto v2 round trip preserves exact instruments and monetary quantities.
- A checked-in or inline version 1 fixture using embedded instruments still decodes and imports.
- A v1 file with an incomplete catalogue but a valid embedded non-fiat instrument is normalised and
  imports successfully.
- A v2 file with a missing instrument reference fails before profile creation.
- A v2 catalogue with conflicting definitions for one ID fails deterministically.
- Encoding automatically discovers a referenced instrument absent from the seed catalogue, but
  still fails if definitions conflict.
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
2. Introduce format constants, export instrument coding contexts, `FullInstrument`, and
   `ExportDocumentCodec` with strict reference resolution.
3. Add discovery and strict encoding passes so catalogue closure follows normal Codable traversal.
4. Route export and both import paths through the codec; remove the export-specific raw
   `JSONEncoder`/`JSONDecoder` helpers once all call sites migrate.
5. Update integration and automation tests, run `just format`, `just format-check`, the focused
   export tests, and `just build-mac` with output captured under `.agent-tmp/`.
6. Run the required review cycle before committing: `code-review`, `concurrency-review` for the
   coordinator/actor boundary, and `instrument-conversion-review` for exact instrument and quantity
   preservation. Repeat review and fixes until there are no findings.

## Risks and mitigations

- **A future field is omitted from an export-only mirror.** There are no per-model export mirrors;
  existing domain Codable conformances remain the single field list. Only a new top-level entity
  collection requires an explicit `ExportedData` change.
- **Export context leaks into ordinary Codable.** Context objects are created inside the codec and
  passed only through the configured encoder/decoder. Dedicated tests pin the unchanged default
  `Instrument` representation.
- **Catalogue/reference drift loses metadata.** Encoding requires exact definition equality;
  decoding resolves exclusively from the validated catalogue.
- **Old backups depend on embedded instruments absent from their catalogue.** The v1 path accepts
  embedded definitions and rebuilds catalogue closure after decoding.
- **Financial precision changes during conversion.** Domain models continue carrying `Decimal`
  directly through `Codable`; the design does not round-trip through `JSONSerialization`,
  `Double`, or string rewriting.
- **The new format reduces size less than expected.** A byte-ratio regression test covers realistic
  high-cardinality data. If whitespace is then the dominant cost, compact presentation or archive
  compression should be evaluated as a separate format decision.
