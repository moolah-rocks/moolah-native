import Foundation
import GRDB
import XCTest

@testable import Moolah

/// Benchmarks the cold-launch instrument-resolution burst that routes
/// through `GRDBInstrumentRegistryRepository.instrumentMap()`.
///
/// Every per-profile instrument resolution resolves against this single
/// shared method on the serial profile-index queue (shared across all
/// profiles, the price caches, and sync apply). The #868 cold-launch
/// path issues a burst on the order of ~1400 resolutions/sec. Without
/// memoisation each call would do a `database.read` + a full-map
/// rebuild — including ~150 `Instrument.fiat(code:)` constructions (each
/// spinning up a `NumberFormatter`) over `Locale.Currency.isoCurrencies`
/// — serialised on the shared queue. The memoised,
/// change-invalidated snapshot makes the steady-state cost a single
/// unfair-lock-guarded dictionary read.
///
/// `testColdLaunchBurst` measures 1400 sequential `instrumentMap()`
/// calls against a populated registry: one cold rebuild then 1399 cache
/// hits. `testColdLaunchBurstWithMutation` interleaves a single
/// `registerCrypto` mutation to exercise exactly one mid-burst rebuild.
/// The `InstrumentRegistry.instrumentMap.rebuild` os_signpost (category
/// `Repository`) wraps the rebuild branch so a missed-invalidation
/// rebuild storm is attributable in Instruments rather than showing up
/// only as an opaque wall-clock blowup here.
final class InstrumentMapResolutionBenchmarks: XCTestCase {

  /// Cold-launch burst size — a one-second proxy for the #868 burst.
  private static let burstCallCount = 1400

  nonisolated(unsafe) private static var _registry: GRDBInstrumentRegistryRepository?
  nonisolated(unsafe) private static var _database: DatabaseQueue?

  override static func setUp() {
    super.setUp()
    let database = expecting("benchmark ProfileIndexDatabase.openInMemory failed") {
      try ProfileIndexDatabase.openInMemory()
    }
    _database = database
    let registry = GRDBInstrumentRegistryRepository(database: database)

    // Populate ~80 crypto + stock rows so the rebuild path realises a
    // representative stored-over-ambient merge, not just bare ambient
    // fiat. The cache-hit path is independent of row count, but the cold
    // rebuild this benchmark also pays once should be realistic.
    awaitSyncExpecting {
      for index in 0..<80 {
        let token = Instrument.crypto(
          chainId: 1,
          contractAddress: "0x\(String(format: "%040x", index))",
          symbol: "TK\(index)",
          name: "Token \(index)",
          decimals: 18)
        try await registry.registerCrypto(
          token,
          mapping: CryptoProviderMapping(
            instrumentId: token.id,
            coingeckoId: "token-\(index)",
            binanceSymbol: nil))
      }
    }
    _registry = registry
  }

  override static func tearDown() {
    _registry = nil
    _database = nil
    super.tearDown()
  }

  private var registry: GRDBInstrumentRegistryRepository {
    guard let registry = Self._registry else {
      preconditionFailure("setUp must initialise _registry before tests run")
    }
    return registry
  }

  private var metrics: [XCTMetric] { [XCTClockMetric(), XCTMemoryMetric()] }
  private var options: XCTMeasureOptions {
    let opts = XCTMeasureOptions()
    opts.iterationCount = 10
    return opts
  }

  /// 1400 sequential `instrumentMap()` calls — one cold rebuild then
  /// 1399 memoised cache hits. Approximates the #868 cold-launch
  /// resolution burst once it routes through the shared registry.
  func testColdLaunchBurst() {
    let registry = self.registry
    let count = Self.burstCallCount
    measure(metrics: metrics, options: options) {
      // `measure` runs the block `iterationCount` (10) times; without
      // resetting the cache, iterations 2–10 would be pure warm-cache
      // hits and wouldn't measure the cold rebuild the test name
      // promises. Invalidate first so every iteration is a genuine
      // "1 cold rebuild + 1399 hits" burst.
      registry.invalidateInstrumentMapCache()
      autoreleasepool {
        _ = awaitSyncExpecting {
          var total = 0
          for _ in 0..<count {
            total += try await registry.instrumentMap().count
          }
          return total
        }
      }
    }
  }

  /// Same burst, but a single `registerCrypto` mutation is interleaved
  /// at the midpoint so exactly one mid-burst cache invalidation +
  /// rebuild is exercised alongside the cache-hit steady state.
  func testColdLaunchBurstWithMutation() {
    let registry = self.registry
    let count = Self.burstCallCount
    let midpoint = count / 2
    measure(metrics: metrics, options: options) {
      autoreleasepool {
        _ = awaitSyncExpecting {
          var total = 0
          for index in 0..<count {
            if index == midpoint {
              let token = Instrument.crypto(
                chainId: 1,
                contractAddress: nil,
                symbol: "MID",
                name: "Mid-burst token",
                decimals: 18)
              try await registry.registerCrypto(
                token,
                mapping: CryptoProviderMapping(
                  instrumentId: token.id,
                  coingeckoId: "mid-burst",
                  binanceSymbol: nil))
            }
            total += try await registry.instrumentMap().count
          }
          return total
        }
      }
    }
  }
}
