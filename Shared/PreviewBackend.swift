import Foundation
import GRDB

/// Factory for creating CloudKitBackend instances for SwiftUI previews.
/// Uses an in-memory GRDB queue — no CloudKit sync, fast initialization.
///
/// **`import GRDB` in `Shared/` is justified.** `DATABASE_CODE_GUIDE.md`
/// scopes `import GRDB` to `Backends/GRDB/` (and implicitly `App/`), but
/// `PreviewBackend` is the canonical preview-wiring helper that every
/// `Features/*/Views/*+Previews.swift` reaches for. Treat this file as
/// a peer to `TestBackend` — the second of two in-memory backend
/// factories — rather than as `Shared/` business logic. Moving it under
/// `Backends/GRDB/` would force every feature preview to import the
/// backend layer, which is a worse coupling than the targeted
/// preview-only import here.
enum PreviewBackend {
  /// Builds a CloudKit-shaped backend for SwiftUI previews. The
  /// optional `sharedRegistry` mirrors `TestBackend.create`'s
  /// equivalent parameter — pass the same instance across multiple
  /// preview backends to share one registry like production does.
  /// Defaults to a fresh per-call registry over its own in-memory
  /// profile-index DB (the preview analogue of production's shared
  /// registry); it is never pointed at the per-profile `ProfileDatabase`,
  /// which has no `instrument` table.
  static func create(
    instrument: Instrument = .AUD,
    sharedRegistry: GRDBInstrumentRegistryRepository? = nil
  ) -> CloudKitBackend {
    // In-memory ProfileDatabase.openInMemory() cannot fail (no
    // filesystem path); this factory is preview-only and never runs in
    // production, so a trap is acceptable.
    // swiftlint:disable:next force_try
    let database = try! ProfileDatabase.openInMemory()
    let registry: GRDBInstrumentRegistryRepository
    if let sharedRegistry {
      registry = sharedRegistry
    } else {
      // In-memory ProfileIndexDatabase.openInMemory() cannot fail (no
      // filesystem path); preview-only path, never runs in production.
      // swiftlint:disable:next force_try
      let indexDatabase = try! ProfileIndexDatabase.openInMemory()
      registry = GRDBInstrumentRegistryRepository(database: indexDatabase)
    }
    // The rate / price caches share the registry's profile-index DB,
    // mirroring production (`sharedMarketData` + shared registry both
    // on `profileIndexDatabase`). There are no per-profile rate-cache
    // tables.
    let marketDataDatabase = registry.database
    let networking = NetworkingServices()
    let exchangeRates = ExchangeRateService(
      client: FrankfurterClient(
        http: networking.client(forHost: "api.frankfurter.app")),
      database: marketDataDatabase
    )
    let conversionService = FiatConversionService(
      exchangeRates: exchangeRates, database: marketDataDatabase)
    return CloudKitBackend(
      database: database,
      instrument: instrument,
      profileLabel: "Preview",
      conversionService: conversionService,
      instrumentRegistry: registry
    )
  }
}
