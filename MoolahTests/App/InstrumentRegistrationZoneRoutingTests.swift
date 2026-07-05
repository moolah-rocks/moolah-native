// MoolahTests/App/InstrumentRegistrationZoneRoutingTests.swift

import CloudKit
import Foundation
import GRDB
import Testing

@testable import Moolah

/// Pins that registering a non-fiat instrument through the **shared
/// registry** (the `registerResolvable` path the create / update /
/// account writes take before their per-profile `database.write`)
/// emits its `onRecordChanged` hook with a string-keyed recordName
/// destined for the **profile-index zone** — never a `profile-<UUID>`
/// zone. There is no per-profile-zone instrument upload path (a DEBUG
/// trap in `ProfileDataSyncHandler.recordToSave` catches regressions);
/// this test pins the positive contract
/// end-to-end so a future refactor that loses the shared-registry
/// routing fails here before hitting the trap in CI.
@Suite("Instrument registration routes to the profile-index zone")
@MainActor
struct InstrumentRegistrationZoneRoutingTests {

  @Test(
    "registerStock on the shared registry fires onRecordChanged with the bare instrument id"
  )
  func sharedRegistryRegisterStockEmitsBareIdRecordName() async throws {
    // Wire a shared registry against the in-memory profile-index DB
    // (production constructs the same shape in
    // `MoolahApp+SharedInstrumentScope.makeSharedInstrumentRegistry`).
    let queue = try ProfileIndexDatabase.openInMemory()
    let registry = GRDBInstrumentRegistryRepository(database: queue)

    // Capture the recordNames the registry's hook fires with. The
    // production wiring (`MoolahApp+SharedInstrumentScope.attachSharedInstrumentRegistrySyncHooks`)
    // forwards each recordName to `coordinator.queueSave(recordName:zoneID:)`
    // with the profile-index zoneID. Capturing the recordName lets
    // us assert the bare-id contract that hook depends on.
    let captured = Capture()
    registry.attachSyncHooks(
      onRecordChanged: { recordName in
        Task { @MainActor in captured.add(recordName) }
      },
      onRecordDeleted: { _ in })

    // Register a stock instrument — the same call `registerResolvable`
    // makes (via `registerStock`) when a create / update / account write
    // registers a non-fiat denomination before its per-profile write.
    let bhp = Instrument.stock(
      ticker: "BHP.AX", exchange: "ASX", name: "BHP Group")
    try await registry.registerStock(bhp)

    // Drain main-actor hops that the hook callback runs through.
    try await drainHookHops()

    // The hook must fire exactly once with the bare instrument id —
    // no `<recordType>|<UUID>` prefix. Without this contract the
    // production wiring's `coordinator.queueSave(recordName:zoneID:)`
    // would route the upload to a recordID that the profile-index
    // handler's string-keyed dispatch can't decode, and CKSyncEngine
    // would silently drop the change.
    #expect(captured.recordNames == [bhp.id])
    #expect(captured.recordNames.first == "ASX:BHP.AX")
  }

  @Test(
    "registerCrypto on the shared registry fires onRecordChanged with the chain-prefixed id"
  )
  func sharedRegistryRegisterCryptoEmitsChainPrefixedRecordName() async throws {
    let queue = try ProfileIndexDatabase.openInMemory()
    let registry = GRDBInstrumentRegistryRepository(database: queue)

    let captured = Capture()
    registry.attachSyncHooks(
      onRecordChanged: { recordName in
        Task { @MainActor in captured.add(recordName) }
      },
      onRecordDeleted: { _ in })

    let usdc = Instrument.crypto(
      chainId: 1,
      contractAddress: "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
      symbol: "USDC",
      name: "USD Coin",
      decimals: 6)
    try await registry.registerCrypto(
      usdc,
      mapping: CryptoProviderMapping(
        instrumentId: usdc.id,
        coingeckoId: "usd-coin",
        binanceSymbol: nil))

    try await drainHookHops()

    // Crypto IDs use the `<chainId>:<lowercased-contract>` form. The
    // hook must carry the same string so the profile-index handler's
    // string-keyed dispatch can decode it on the upload side.
    #expect(captured.recordNames == [usdc.id])
    #expect(captured.recordNames.first == "1:0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48")
  }

  // MARK: - Helpers

  /// `@MainActor`-confined buffer the hook closure appends into via a
  /// `Task { @MainActor in }` hop. Mirrors the `Capture` pattern in
  /// `InstrumentLocalSyncQueueTests`.
  @MainActor
  final class Capture {
    private(set) var recordNames: [String] = []

    func add(_ recordName: String) { recordNames.append(recordName) }
  }

  /// Bounded backstop for the main-actor hop the hook closure runs
  /// through. The `for await { break }` propagation pattern is the
  /// project's preferred idiom but the registry's hook is a closure
  /// (not an `AsyncStream`), so a single `Task.yield()` followed by a
  /// short `ContinuousClock.sleep` deadline is the closest equivalent
  /// — never `Task.sleep`, which would race the hook hop.
  private func drainHookHops() async throws {
    // One yield is usually enough; the brief sleep covers the rare
    // case where the @MainActor hop hasn't been scheduled yet.
    await Task.yield()
    try await ContinuousClock().sleep(until: .now.advanced(by: .milliseconds(20)))
  }
}
