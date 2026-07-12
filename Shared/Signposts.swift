import os

enum Signposts {
  static let repository = OSLog(subsystem: "com.moolah.app", category: "Repository")
  static let sync = OSLog(subsystem: "com.moolah.app", category: "Sync")
  static let balance = OSLog(subsystem: "com.moolah.app", category: "Balance")
  /// Per-stage boundaries for the CSV import pipeline. Instruments traces
  /// attribute time to `tokenize`, `parse`, `dedup`, `rules`, and the outer
  /// `ingest` range. See `guides/BENCHMARKING_GUIDE.md`.
  static let importPipeline = OSLog(subsystem: "com.moolah.app", category: "ImportPipeline")
  /// Per-stage boundaries for the profile export pipeline
  /// (`DataExporter.export`). Each step (accounts, categories, earmarks,
  /// transactions) emits its own region so hangs surface
  /// in Instruments rather than as a user-reported silent failure.
  static let export = OSLog(subsystem: "com.moolah.app", category: "Export")
  /// Per-stage boundaries for the crypto wallet sync pipeline. Named
  /// regions cover `alchemy.getAssetTransfers`,
  /// `transferEventBuilder.build`, `crossAccountTransferMerger.merge`,
  /// `walletApplyEngine.{dedup,persist,rules}`,
  /// `crossDeviceLegDeduper.dedup`, and the top-level
  /// `cryptoSyncStore.syncAccounts`. Inspect via the os_signpost
  /// instrument filtered to `com.moolah.app` / `CryptoSync`.
  static let cryptoSync = OSLog(subsystem: "com.moolah.app", category: "CryptoSync")
  /// One-shot `.event` signpost emitted from `databaseDidCommit` of the
  /// opt-in `BenchmarkGRDBCommitObserver` (only attached in tests/benches
  /// via `BenchmarkGRDBCommitObserver.attach(to:)`). Marks the moment a
  /// GRDB write becomes observable to `ValueObservation`. Production code
  /// never attaches the observer, so the production app pays no cost
  /// here. See `guides/BENCHMARKING_GUIDE.md`.
  static let grdbWrite = OSLog(subsystem: "com.moolah.app", category: "GRDBWrite")
  /// Begin/end pair around each value emitted by the
  /// `AsyncValueObservation → AsyncStream` bridge in
  /// `Backends/GRDB/Observation/AsyncValueObservation+AsyncStream.swift`.
  /// The interval covers the `for try await value in self` body — i.e.
  /// from "GRDB delivered a value to the bridge" to "the bridge yielded
  /// it to the consumer". In Instruments this measures the in-bridge
  /// hop; the gap from the preceding `GRDBWrite` event to this region's
  /// begin is the GRDB re-fetch + scheduling cost.
  static let grdbObservation = OSLog(
    subsystem: "com.moolah.app", category: "GRDBObservation")
  /// Begin/end pair around the work performed by a reactive store's
  /// `apply(...)` / `recompute…` methods on `MainActor`. Each reactive
  /// store (Account, Earmark, Transaction, …) wires this in the same way.
  /// Intervals here are the `mainThreadMs` cost measured by
  /// `SyncReactivityBenchmarks` against the `< 50 ms cumulative`
  /// acceptance criterion.
  static let reactiveStore = OSLog(
    subsystem: "com.moolah.app", category: "ReactiveStore")
}

extension Duration {
  /// Milliseconds as an integer, for performance logging.
  var inMilliseconds: Int {
    let (seconds, attoseconds) = components
    return Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000)
  }
}
