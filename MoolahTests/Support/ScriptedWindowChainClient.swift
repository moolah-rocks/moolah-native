// MoolahTests/Support/ScriptedWindowChainClient.swift
import Foundation

@testable import Moolah

/// Scriptable, recording `ChainDataClient` for the windowed-runner + windowed
/// store-routing tests. Returns a fixed `currentHead`, per-`fromBlock` ERC-20
/// rows (or a single set for every call), records every `getAssetTransfers`
/// `fromBlock`, and can inject a failure on a chosen window's fetch. Receipts
/// return a zero-fee sentinel (`from: ""`) so an outbound transfer's gas-leg
/// lookup resolves to no leg rather than trapping.
///
/// `@unchecked Sendable`: all mutable state lives behind an `NSLock`,
/// matching the project convention for non-actor concurrent test stubs.
final class ScriptedWindowChainClient: ChainDataClient, @unchecked Sendable {
  /// Thrown by a window scripted to fail via `failTransfers(forFromBlock:)`.
  struct ScriptedWindowFailure: Error { let fromBlock: UInt64 }

  private let lock = NSLock()
  private let head: UInt64?
  private var rowsByFromBlock: [UInt64: [AlchemyTransfer]] = [:]
  private var anyCallRows: [AlchemyTransfer] = []
  private var failingFromBlocks: Set<UInt64> = []
  private var fromBlocks: [UInt64] = []
  private var onGetAssetTransfers: (@MainActor () async -> Void)?

  init(head: UInt64?) {
    self.head = head
  }

  /// Optional hook fired inside `getAssetTransfers` (a mid-scan suspension
  /// point) before the rows are returned. The store-routing tests install a
  /// probe here that snapshots the store's published `progressPerAccount`
  /// while a window is in flight, proving determinate progress is visible
  /// mid-scan rather than only inferable after the runner returns.
  ///
  /// Typed `@MainActor` (not `@Sendable`) so the probe can freely read the
  /// `@MainActor`-isolated store state — the same idiom `WindowedWalletSyncRunner`'s
  /// own `progress` closure uses. `getAssetTransfers` hops to the main actor
  /// via `await hook()`.
  func setOnGetAssetTransfers(_ hook: (@MainActor () async -> Void)?) {
    lock.withLock { onGetAssetTransfers = hook }
  }

  /// Rows returned for the window whose fetch starts at `fromBlock`.
  func setRows(_ rows: [AlchemyTransfer], forFromBlock fromBlock: UInt64) {
    lock.withLock { rowsByFromBlock[fromBlock] = rows }
  }

  /// Rows returned for every fetch that has no per-`fromBlock` override —
  /// used to model a transfer that reappears in the reorg-window re-scan.
  func setRowsForAnyCall(_ rows: [AlchemyTransfer]) {
    lock.withLock { anyCallRows = rows }
  }

  /// Scripts the fetch for the window starting at `fromBlock` to throw.
  func failTransfers(forFromBlock fromBlock: UInt64) {
    lock.withLock { _ = failingFromBlocks.insert(fromBlock) }
  }

  /// Clears all scripted failures (used to model a cleared transient error
  /// on resume).
  func clearFailures() {
    lock.withLock { failingFromBlocks.removeAll() }
  }

  /// Every `getAssetTransfers` `fromBlock`, in call order.
  var recordedFromBlocks: [UInt64] {
    lock.withLock { fromBlocks }
  }

  func currentHead(chain: ChainConfig) async throws -> UInt64? {
    head
  }

  func getAssetTransfers(
    chain: ChainConfig,
    walletAddress: String,
    fromBlock: UInt64,
    toBlock: UInt64?
  ) async throws -> [AlchemyTransfer] {
    let hook = lock.withLock { onGetAssetTransfers }
    let (rows, shouldFail) = lock.withLock { () -> ([AlchemyTransfer], Bool) in
      fromBlocks.append(fromBlock)
      let resolved = rowsByFromBlock[fromBlock] ?? anyCallRows
      return (resolved, failingFromBlocks.contains(fromBlock))
    }
    if let hook { await hook() }
    if shouldFail { throw ScriptedWindowFailure(fromBlock: fromBlock) }
    return rows
  }

  func getTransactionReceipt(
    chain: ChainConfig,
    hash: String
  ) async throws -> AlchemyTransactionReceipt {
    // Sentinel `from: ""` never matches a wallet, so `makeGasLeg` returns
    // nil and no gas leg is synthesised — keeps the transfer legs the
    // tests inspect deterministic.
    AlchemyTransactionReceipt(hash: hash, gasUsed: 0, effectiveGasPrice: 0, from: "")
  }
}
