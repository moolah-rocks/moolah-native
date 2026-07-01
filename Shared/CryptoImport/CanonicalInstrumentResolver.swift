// Shared/CryptoImport/CanonicalInstrumentResolver.swift

import Foundation
import os

/// Resolves a retired cross-chain crypto instrument id to its canonical id,
/// so ETH on mainnet / OP / Base is treated as one asset (`1:native`) and an
/// L2 USDC/USDT collapses onto its mainnet contract.
///
/// Two layers:
/// - A **static base layer** (`staticBaseMap`), present from the instant the
///   app launches, so construction-time canonicalization (later PRs) maps
///   retired ids before the data migration writes any `alias_of` — the local
///   device never mints a retired id.
/// - A **dynamic layer** (`dynamicMap`), derived by grouping the shared
///   registry's crypto registrations by `assetKey` and refreshed on registry
///   change, covering discovered ERC-20s absent from the static list.
///
/// **`@unchecked Sendable` justification.** The only mutable state is
/// `dynamicMap`, guarded by `OSAllocatedUnfairLock` — the lock-guarded
/// mutable-map pattern sanctioned in `guides/CONCURRENCY_GUIDE.md` §2
/// carve-out 7. `staticBaseMap` is an immutable `static let`. The lock is
/// never held across an `await`: lookups are synchronous because the first
/// consumers (`ChainConfig.nativeInstrument`, native transfer/gas legs) read
/// them from non-async contexts.
final class CanonicalInstrumentResolver: @unchecked Sendable {
  /// Hardcoded retired → canonical entries available at startup. Mirrors the
  /// cross-chain deployments in `CanonicalTokenRegistry+Bundled.swift`; the
  /// drift-guard test asserts each L2 stablecoin address is still recognised
  /// there. ETH L2 natives collapse to `1:native`; L2 USDC/USDT collapse to
  /// their mainnet contract ids.
  static let staticBaseMap: [String: String] = [
    // ETH L2 natives → mainnet native.
    "10:native": "1:native",
    "8453:native": "1:native",
    // USDC: L2 deployment → mainnet USDC.
    "10:0x0b2c639c533813f4aa9d7837caf62653d097ff85":
      "1:0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
    "137:0x3c499c542cef5e3811e1192ce70d8cc03d5c3359":
      "1:0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
    "8453:0x833589fcd6edb6e08f4c7c32d4f71b54bda02913":
      "1:0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
    // USDT: L2 deployment → mainnet USDT.
    "10:0x94b008aa00579c1307b0ef2c499ad98a8ce58e58":
      "1:0xdac17f958d2ee523a2206206994597c13d831ec7",
    "137:0xc2132d05d31c914a87c6611c10748aeb04b58e8f":
      "1:0xdac17f958d2ee523a2206206994597c13d831ec7",
    "8453:0xfde4c96c8593536e31f229ea8f37b2ada2699bb2":
      "1:0xdac17f958d2ee523a2206206994597c13d831ec7",
  ]

  /// Dynamic retired → canonical map, rebuilt on registry change.
  private let dynamicMap = OSAllocatedUnfairLock<[String: String]>(initialState: [:])

  /// The canonical id for `id`, or `id` unchanged when it is not a known
  /// alias. Static base layer wins (it is authoritative and lock-free); the
  /// dynamic layer covers the discovered tail. Canonical ids are never
  /// themselves aliases, so a single hop suffices.
  func canonicalId(for id: String) -> String {
    if let canonical = Self.staticBaseMap[id] { return canonical }
    if let canonical = dynamicMap.withLock({ $0[id] }) { return canonical }
    return id
  }

  /// `true` when `id` is retired (resolves to a different canonical id).
  func isAlias(_ id: String) -> Bool {
    canonicalId(for: id) != id
  }

  // MARK: - Dynamic layer

  /// Derives the retired → canonical map from crypto registrations. Groups by
  /// `CryptoProviderMapping.assetKey` (a no-key instrument's assetKey is its
  /// own id, so it forms a singleton group and is never aliased). Within a
  /// multi-member group the canonical is the `chainId == 1` member, else the
  /// member with the lowest `chainId`; ties break on the lexicographically
  /// smallest id for determinism. Only non-canonical members appear as keys.
  static func derive(from registrations: [CryptoRegistration]) -> [String: String] {
    let groups = Dictionary(grouping: registrations, by: { $0.mapping.assetKey })
    var map: [String: String] = [:]
    for (_, members) in groups where members.count > 1 {
      let canonical = members.min { lhs, rhs in
        let lChain = lhs.instrument.chainId ?? Int.max
        let rChain = rhs.instrument.chainId ?? Int.max
        if lChain == 1 && rChain != 1 { return true }
        if rChain == 1 && lChain != 1 { return false }
        if lChain != rChain { return lChain < rChain }
        return lhs.instrument.id < rhs.instrument.id
      }
      guard let canonical else { continue }
      for member in members where member.instrument.id != canonical.instrument.id {
        map[member.instrument.id] = canonical.instrument.id
      }
    }
    return map
  }

  /// Rebuilds the dynamic map from an in-hand registration list. Test seam
  /// and the synchronous core used by both `refresh(from:)` overloads.
  func refresh(with registrations: [CryptoRegistration]) {
    let map = Self.derive(from: registrations)
    dynamicMap.withLock { $0 = map }
  }

  /// Rebuilds the dynamic map from the shared registry. Registry errors are
  /// swallowed after logging — a stale dynamic map still resolves via the
  /// static base layer, and the next tick retries.
  func refresh(from registry: any InstrumentRegistryRepository) async {
    do {
      let registrations = try await registry.allCryptoRegistrations()
      refresh(with: registrations)
    } catch {
      Self.logger.error("alias map refresh failed: \(error, privacy: .public)")
    }
  }

  /// Refreshes once, then rebuilds on every registry-change tick. Mirrors the
  /// `for await _ in observeChanges()` pattern used by the per-profile stores
  /// (e.g. `InvestmentStore`). Returns the task so the owner can cancel it.
  ///
  /// The `changes` stream is injected (not fetched from `registry`) so callers
  /// can share a single `observeChanges()` subscription across multiple
  /// consumers and tests can drive ticks without a real registry.
  @discardableResult
  func startObserving(
    registry: any InstrumentRegistryRepository,
    changes: AsyncStream<Void>
  ) -> Task<Void, Never> {
    Task { [weak self] in
      await self?.refresh(from: registry)
      if Task.isCancelled { return }
      for await _ in changes {
        if Task.isCancelled { return }
        await self?.refresh(from: registry)
        if Task.isCancelled { return }
      }
    }
  }

  private static let logger = Logger(
    subsystem: "com.moolah.app", category: "CanonicalInstrumentResolver")
}
