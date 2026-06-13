// MoolahTests/Shared/CryptoImport/WalletSyncTestDoubles.swift
import Foundation

@testable import Moolah

/// Namespace anchor so SwiftLint's `file_name` rule stays satisfied
/// alongside the loose top-level helpers and stubs declared below.
enum WalletSyncTestDoubles {}

/// Counting stub for `AlchemyClient` that returns a scripted transfer
/// list per `(chainId, walletAddress)` key. Records every call so tests
/// can assert on `fromBlock` derivation and call counts.
///
/// `@unchecked Sendable`: state lives behind an `NSLock`, mirroring the
/// project convention for non-actor concurrent test stubs (see
/// `AlchemyTestSupport.swift`, `CryptoTokenDiscoveryTestDoubles.swift`).
final class RecordingAlchemyClientStub: AlchemyClient, @unchecked Sendable {
  struct AssetTransfersCall: Sendable, Hashable {
    let chainId: Int
    let walletAddress: String
    let fromBlock: UInt64
  }

  enum Response: Sendable {
    case transfers([AlchemyTransfer])
    case failure(any Error)
  }

  /// Scripted reply for a `getTransactionReceipt` call. Tests that
  /// exercise the gas-leg path script success on the hashes they care
  /// about and (optionally) failure on others to verify the
  /// per-receipt error containment.
  enum ReceiptResponse: Sendable {
    case receipt(AlchemyTransactionReceipt)
    case failure(any Error)
  }

  /// Errors thrown when scripting hooks are unset and a test path hits
  /// the stub anyway. Keeps the failure message specific to the path.
  struct UnscriptedTransfersCall: Error { let chainId: Int }
  /// Thrown when `getTransactionReceipt` is called for a hash that
  /// hasn't been scripted on this stub. Tests that exercise the
  /// receipt path script per-hash responses; tests that don't stay on
  /// the inbound-only path which never triggers a receipt fetch.
  struct UnscriptedReceiptCall: Error { let hash: String }

  private let lock = NSLock()
  private var transfersResponse: Response?
  private var perAddressResponses: [String: Response] = [:]
  private var assetTransfersCalls: [AssetTransfersCall] = []
  private var receiptResponses: [String: ReceiptResponse] = [:]
  private var receiptCalls: [String] = []
  /// Optional hook fired before the response is returned — the
  /// cancellation test installs a closure here that cancels the parent
  /// task so the engine throws on the next `checkCancellation()`.
  private var beforeAssetTransfers: (@Sendable () async -> Void)?

  func setTransfersResponse(_ response: Response) {
    lock.withLock { self.transfersResponse = response }
  }

  /// Per-wallet-address scripted response. Used by Stage 9's tests to
  /// verify per-account error containment — one wallet throws, another
  /// returns transfers. Lookup is case-insensitive (Alchemy lowercases
  /// outputs but wallet records may be checksummed).
  func setTransfersResponse(_ response: Response, for walletAddress: String) {
    lock.withLock { self.perAddressResponses[walletAddress.lowercased()] = response }
  }

  func setBeforeAssetTransfers(_ hook: (@Sendable () async -> Void)?) {
    lock.withLock { self.beforeAssetTransfers = hook }
  }

  var recordedCalls: [AssetTransfersCall] {
    lock.withLock { assetTransfersCalls }
  }

  func getAssetTransfers(
    chain: ChainConfig,
    walletAddress: String,
    fromBlock: UInt64
  ) async throws -> [AlchemyTransfer] {
    let (response, hook) = lock.withLock {
      assetTransfersCalls.append(
        AssetTransfersCall(
          chainId: chain.chainId,
          walletAddress: walletAddress,
          fromBlock: fromBlock))
      let perAddress = perAddressResponses[walletAddress.lowercased()]
      return (perAddress ?? transfersResponse, beforeAssetTransfers)
    }
    if let hook { await hook() }
    try Task.checkCancellation()
    switch response {
    case .none:
      throw UnscriptedTransfersCall(chainId: chain.chainId)
    case let .failure(error):
      throw error
    case let .transfers(transfers):
      return transfers
    }
  }

  /// Scripts a receipt response for a given on-chain hash. The lookup
  /// is exact-match — production callers always pass the same casing
  /// they read off `AlchemyTransfer.hash`, so tests can use the same
  /// values verbatim.
  func setReceiptResponse(_ response: ReceiptResponse, for hash: String) {
    lock.withLock { receiptResponses[hash] = response }
  }

  /// Recorded list of every `getTransactionReceipt` invocation, in
  /// call order. Used by the coalescing tests to assert that one
  /// outbound + four inbound triggers exactly one fetch.
  var recordedReceiptCalls: [String] {
    lock.withLock { receiptCalls }
  }

  func getTransactionReceipt(
    chain: ChainConfig,
    hash: String
  ) async throws -> AlchemyTransactionReceipt {
    let response: ReceiptResponse? = lock.withLock {
      receiptCalls.append(hash)
      return receiptResponses[hash]
    }
    switch response {
    case .none:
      throw UnscriptedReceiptCall(hash: hash)
    case let .failure(error):
      throw error
    case let .receipt(receipt):
      return receipt
    }
  }
}

/// In-memory `WalletSyncStateRepository` stub. Records every call so
/// tests can verify the engine reads but never writes.
///
/// `@unchecked Sendable`: state behind an `NSLock`, matching the project
/// convention.
final class RecordingWalletSyncStateRepository: WalletSyncStateRepository, @unchecked Sendable {
  private let lock = NSLock()
  private var seeded: [UUID: WalletSyncState] = [:]
  private var _saveCount: Int = 0
  private var _deleteCount: Int = 0

  var saveCount: Int { lock.withLock { _saveCount } }
  var deleteCount: Int { lock.withLock { _deleteCount } }

  func seed(_ state: WalletSyncState) {
    lock.withLock { seeded[state.id] = state }
  }

  func loadAll() async throws -> [WalletSyncState] {
    lock.withLock { Array(seeded.values) }
  }

  func load(accountId: UUID) async throws -> WalletSyncState? {
    lock.withLock { seeded[accountId] }
  }

  func save(_ state: WalletSyncState) async throws {
    lock.withLock {
      _saveCount += 1
      seeded[state.id] = state
    }
  }

  func delete(accountId: UUID) async throws {
    lock.withLock {
      _deleteCount += 1
      seeded[accountId] = nil
    }
  }
}

// MARK: - Builder shortcuts

/// Constructs an `AlchemyTransfer` with the fields tests inspect — `hash`,
/// `from`, `to`, `category`, `asset`, contract address / decimals, raw
/// hex amount. Defaults match a typical native ETH send so cases that
/// only change one or two fields read concisely. `uniqueIdSuffix` lets
/// tests model multiple events on a single hash without colliding on
/// `uniqueId` (production uses Alchemy's `:log:N` index — tests just
/// need any distinct suffix per event).
func makeAlchemyTransfer(
  hash: String,
  from: String,
  to: String?,
  category: AlchemyTransferCategory,
  asset: String? = "ETH",
  contractAddress: String? = nil,
  decimalsHex: String? = "0x12",  // 18
  rawValueHex: String = "0x0de0b6b3a7640000",  // 1.0 * 10^18
  blockTimestamp: String? = "2024-09-12T12:34:56.000Z",
  blockNum: String = "0x12d4f0a",
  uniqueIdSuffix: String = "0"
) -> AlchemyTransfer {
  AlchemyTransfer(
    hash: hash,
    uniqueId: "\(hash):\(uniqueIdSuffix)",
    from: from,
    to: to,
    category: category,
    asset: asset,
    rawContract: AlchemyTransfer.RawContract(
      address: contractAddress?.lowercased(),
      decimal: decimalsHex,
      rawValue: rawValueHex),
    metadata: AlchemyTransfer.Metadata(blockTimestamp: blockTimestamp),
    blockNum: blockNum)
}

/// Builds an `ImportOrigin` keyed off the synced account id. Matches
/// the production factory shape Stage 9 will pass.
func makeWalletImportOrigin(
  for accountId: UUID,
  importedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
  sessionId: UUID = UUID()
) -> ImportOrigin {
  ImportOrigin(
    rawDescription: "wallet:\(accountId.uuidString)",
    rawAmount: 0,
    importedAt: importedAt,
    importSessionId: sessionId,
    parserIdentifier: "alchemy-wallet-sync")
}

/// `AlchemyClient` that returns a zero-cost receipt for every receipt
/// fetch and traps on the unrelated `getAssetTransfers` path. Used by
/// `TransferEventBuilder` tests that only care about transfer-leg
/// construction — a zero receipt produces no gas leg (the builder drops
/// a non-positive total) so the legs the test actually inspects stay
/// deterministic without extra plumbing.
final class ZeroReceiptAlchemyStub: AlchemyClient, @unchecked Sendable {
  struct UnexpectedAssetTransfersCall: Error {}

  private let lock = NSLock()
  private var receiptHashes: [String] = []

  /// Hashes the builder has asked for receipts on, in call order. Lets
  /// tests assert that their inbound-only path didn't trigger a fetch.
  var recordedReceiptCalls: [String] {
    lock.withLock { receiptHashes }
  }

  func getAssetTransfers(
    chain: ChainConfig,
    walletAddress: String,
    fromBlock: UInt64
  ) async throws -> [AlchemyTransfer] {
    throw UnexpectedAssetTransfersCall()
  }

  func getTransactionReceipt(
    chain: ChainConfig,
    hash: String
  ) async throws -> AlchemyTransactionReceipt {
    lock.withLock { receiptHashes.append(hash) }
    return AlchemyTransactionReceipt(
      hash: hash,
      gasUsed: 0,
      effectiveGasPrice: 0,
      // Sentinel: `from: ""` can never match a real wallet address, so
      // `makeGasLeg` returns nil at the `receipt.from == walletAddress`
      // guard. `gasUsed: 0` / `effectiveGasPrice: 0` provide a second
      // line of defence (zero total-fee guard) if the from-check order
      // ever changes, keeping the "no gas leg" behaviour consistent.
      from: "")
  }
}

/// Builds a crypto `Account` for a given chain + wallet address.
func makeCryptoAccount(
  id: UUID = UUID(),
  walletAddress: String,
  chain: ChainConfig
) -> Account {
  Account(
    id: id,
    name: "Wallet",
    type: .crypto,
    instrument: chain.nativeInstrument,
    walletAddress: walletAddress.lowercased(),
    chainId: chain.chainId)
}

/// Scriptable, recording `BlockExplorerClient` stub. Provides the same
/// lock-discipline as `RecordingAlchemyClientStub`: all mutable state
/// lives behind an `NSLock` so `@unchecked Sendable` is safe even under
/// Swift Testing's parallel-suite execution. Defaults to empty results so
/// engine tests that don't exercise Blockscout compile and run without any
/// extra setup.
final class RecordingBlockExplorerClientStub: BlockExplorerClient, @unchecked Sendable {
  struct BlockExplorerCall: Sendable, Hashable {
    let chainId: Int
    let walletAddress: String
    let fromBlock: UInt64
  }

  enum NativeResponse: Sendable {
    case txs([BlockscoutTransaction])
    case failure(any Error)
  }
  enum InternalResponse: Sendable {
    case txs([BlockscoutInternalTx])
    case failure(any Error)
  }

  private let lock = NSLock()
  private var native: NativeResponse = .txs([])
  private var internalTx: InternalResponse = .txs([])
  private var nativeCalls: [BlockExplorerCall] = []
  private var internalCalls: [BlockExplorerCall] = []

  func setNative(_ response: NativeResponse) { lock.withLock { self.native = response } }
  func setInternal(_ response: InternalResponse) { lock.withLock { self.internalTx = response } }

  var recordedNativeCalls: [BlockExplorerCall] {
    lock.withLock { nativeCalls }
  }

  var recordedInternalCalls: [BlockExplorerCall] {
    lock.withLock { internalCalls }
  }

  func nativeTransactions(
    chain: ChainConfig, walletAddress: String, fromBlock: UInt64
  ) async throws -> [BlockscoutTransaction] {
    let response = lock.withLock { () -> NativeResponse in
      nativeCalls.append(
        BlockExplorerCall(
          chainId: chain.chainId,
          walletAddress: walletAddress,
          fromBlock: fromBlock))
      return native
    }
    switch response {
    case .txs(let txs): return txs
    case .failure(let error): throw error
    }
  }

  func internalTransactions(
    chain: ChainConfig, walletAddress: String, fromBlock: UInt64
  ) async throws -> [BlockscoutInternalTx] {
    let response = lock.withLock { () -> InternalResponse in
      internalCalls.append(
        BlockExplorerCall(
          chainId: chain.chainId,
          walletAddress: walletAddress,
          fromBlock: fromBlock))
      return internalTx
    }
    switch response {
    case .txs(let txs): return txs
    case .failure(let error): throw error
    }
  }
}

/// Shared empty Blockscout stub for engine-construction sites that
/// don't exercise the Blockscout path.
///
/// Returns a **fresh** `RecordingBlockExplorerClientStub` on every access.
/// Tests that need to observe recorded calls must capture the instance before
/// passing it to the engine — asserting on `BlockExplorerTestDoubles.empty`
/// directly would always see an empty call list (a different instance).
enum BlockExplorerTestDoubles {
  static var empty: RecordingBlockExplorerClientStub { RecordingBlockExplorerClientStub() }
}
