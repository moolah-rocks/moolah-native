# AI Architecture Guide

Shared architecture and testing constraints for AI assistants.

## Architecture

- Target iOS 26+ and macOS 26+.
- `Domain/Models/` and `Domain/Repositories/` must not import `SwiftUI`, `GRDB`, `URLSession`, `Backends/`, or backend implementation types.
- Feature code talks to repositories through protocols from `@Environment(BackendProvider.self)`. Feature files must not import `Backends/` directly.
- `BackendProvider` is the injection point. Production uses `CloudKitBackend`; tests use `TestBackend`; SwiftUI previews use `PreviewBackend`.
- `CloudKit/schema.ckdb` is the canonical CloudKit schema. Generated CloudKit wire code under `Backends/CloudKit/Sync/Generated/` is produced by `just generate` and is gitignored.
- Concurrency work follows `guides/CONCURRENCY_GUIDE.md`: UI-bound stores are `@MainActor`, cross-actor values are `Sendable`, and `async/await` is preferred over callbacks.
- Performance work follows `guides/BENCHMARKING_GUIDE.md`.

## Money And Instruments

- Monetary values are `InstrumentAmount`: a `Decimal` quantity plus an `Instrument`, stored as `Int64` scaled by 10^8.
- A profile's base currency comes from `Profile.currencyCode` through `Profile.instrument`.
- Views derive instrument/currency from loaded domain objects, not global constants.
- Arithmetic across mismatched instruments traps at runtime. Follow `guides/INSTRUMENT_CONVERSION_GUIDE.md`.
- Tests use `Instrument.defaultTestInstrument`.
- Preserve monetary signs. Do not use `abs()` or otherwise discard sign unless a display rule explicitly requires it.

## Thin Views

Views bind state, dispatch actions, and render. Business logic belongs in stores, model extensions, or shared utilities.

Put in stores:

- Multi-step orchestration.
- Async sequences where later steps depend on earlier success.
- Error formatting and error state.
- Computed aggregations over domain data.

Put in model extensions or shared utilities:

- Data transformation and validation.
- Amount parsing through `InstrumentAmount.parseQuantity(from:decimals:)`.
- Reused display properties.

Keep in views:

- Local UI state such as selection, sheet visibility, and search text.
- One-line dispatch to store actions.
- SwiftUI layout, styling, and modifiers.

## Testing

- All tests follow `guides/TEST_GUIDE.md`; UI tests also follow `guides/UI_TEST_GUIDE.md`.
- Write the test file before the implementation file.
- Repository protocols have contract tests under `MoolahTests/Domain/`.
- Store methods that mutate state need tests for published state and repository state.
- Use `TestBackend` instead of mocking repositories.
- Test rollback/error paths as well as happy paths.
- New user actions that trigger multi-step async flows belong in a store method first, with store tests, then UI wiring.
- Test targets are `MoolahTests_iOS`, `MoolahTests_macOS`, and `MoolahUITests_macOS`.
