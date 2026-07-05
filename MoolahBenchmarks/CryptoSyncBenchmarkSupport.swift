import Foundation

@testable import Moolah

/// Namespace anchor so SwiftLint's `file_name` rule stays satisfied
/// alongside the loose top-level fixtures, stubs, and helper types
/// declared below. Mirrors the `WalletSyncTestDoubles` /
/// `CryptoTokenDiscoveryTestDoubles` pattern in the test target.
enum CryptoSyncBenchmarkSupport {}

// MARK: - Benchmark wallets

/// Pinned wallet identities for benchmarks. Each entry has a stable
/// lowercased Ethereum address and pre-allocated account UUID so the
/// fixtures and the seeded accounts agree on which wallet is which
/// across runs.
struct BenchmarkWallet: Sendable {
  let accountId: UUID
  let address: String

  static let eth1 = BenchmarkWallet(
    accountId: makeUUID("DEC0DEAD-0001-0000-0000-000000000001"),
    address: "0x" + String(repeating: "1", count: 40))
  static let eth2 = BenchmarkWallet(
    accountId: makeUUID("DEC0DEAD-0002-0000-0000-000000000002"),
    address: "0x" + String(repeating: "2", count: 40))
  static let eth3 = BenchmarkWallet(
    accountId: makeUUID("DEC0DEAD-0003-0000-0000-000000000003"),
    address: "0x" + String(repeating: "3", count: 40))
  static let eth4 = BenchmarkWallet(
    accountId: makeUUID("DEC0DEAD-0004-0000-0000-000000000004"),
    address: "0x" + String(repeating: "4", count: 40))
  static let eth5 = BenchmarkWallet(
    accountId: makeUUID("DEC0DEAD-0005-0000-0000-000000000005"),
    address: "0x" + String(repeating: "5", count: 40))
}

// MARK: - Fixtures

/// Synthesises `AlchemyTransfer` lists for the benchmark. Stable — every
/// run produces the identical bytes — so iteration noise comes from the
/// pipeline, not the inputs.
enum BenchmarkAlchemyFixtures {
  /// `count` native-ETH transfers from a fixed counterparty into the
  /// given wallet. Each transfer has a unique `hash` and `blockNum`
  /// derived from `index + hashOffset` so re-sync benchmarks can plant
  /// "old" hashes followed by "new" hashes without collision.
  static func makeNativeTransfers(
    wallet: BenchmarkWallet,
    count: Int,
    hashOffset: Int = 0
  ) -> [AlchemyTransfer] {
    var transfers: [AlchemyTransfer] = []
    transfers.reserveCapacity(count)
    let counterparty = "0x" + String(repeating: "f", count: 40)
    for index in 0..<count {
      let absoluteIndex = index + hashOffset
      transfers.append(
        AlchemyTransfer(
          hash: hashFor(index: absoluteIndex),
          uniqueId: "\(hashFor(index: absoluteIndex)):0",
          from: counterparty,
          to: wallet.address.lowercased(),
          category: .external,
          asset: "ETH",
          rawContract: AlchemyTransfer.RawContract(
            address: nil,
            decimal: "0x12",
            rawValue: "0x0de0b6b3a7640000"),
          metadata: AlchemyTransfer.Metadata(
            blockTimestamp: "2024-09-12T12:34:56.000Z"),
          blockNum: blockNumHex(absoluteIndex)))
    }
    return transfers
  }

  /// Convenience: produces a `[walletAddressLowercased: transfers]` map
  /// for the parallel-wallets benchmark in one allocation pass.
  static func makeNativeTransfers(
    wallets: [BenchmarkWallet],
    perWallet: Int
  ) -> [String: [AlchemyTransfer]] {
    var map: [String: [AlchemyTransfer]] = [:]
    map.reserveCapacity(wallets.count)
    for wallet in wallets {
      map[wallet.address.lowercased()] = makeNativeTransfers(
        wallet: wallet, count: perWallet)
    }
    return map
  }

  /// `count` ERC-20 transfers, each with a distinct contract address so
  /// the discovery actor must resolve each one. Useful for the token-
  /// discovery benchmark; not useful for the native-only benchmarks.
  static func makeERC20Transfers(
    wallet: BenchmarkWallet,
    count: Int
  ) -> [AlchemyTransfer] {
    var transfers: [AlchemyTransfer] = []
    transfers.reserveCapacity(count)
    let counterparty = "0x" + String(repeating: "e", count: 40)
    for index in 0..<count {
      let contract = "0x" + String(format: "%040x", index + 1)
      transfers.append(
        AlchemyTransfer(
          hash: hashFor(index: index + 100_000),
          uniqueId: "\(hashFor(index: index + 100_000)):0",
          from: counterparty,
          to: wallet.address.lowercased(),
          category: .erc20,
          asset: "TKN\(index)",
          rawContract: AlchemyTransfer.RawContract(
            address: contract,
            decimal: "0x12",
            rawValue: "0x0de0b6b3a7640000"),
          metadata: AlchemyTransfer.Metadata(
            blockTimestamp: "2024-09-12T12:34:56.000Z"),
          blockNum: blockNumHex(index + 100_000)))
    }
    return transfers
  }

  /// Stable per-index transaction hash. 64 hex chars (32 bytes) so the
  /// shape matches a real on-chain hash and the partial unique index
  /// stays the bottleneck rather than string length.
  static func hashFor(index: Int) -> String {
    let suffix = String(format: "%016x", index)
    return "0x" + String(repeating: "0", count: 48) + suffix
  }

  /// `0x`-prefixed hex block number derived from `index + 100`. The
  /// `+100` keeps every block above the reorg-window floor so
  /// `WalletSyncEngine.subtractingReorgWindow` doesn't clamp to zero
  /// on the seed.
  private static func blockNumHex(_ index: Int) -> String {
    "0x" + String(index + 100, radix: 16)
  }
}

// MARK: - Benchmark stubs

/// Scripted in-process Alchemy client used by every benchmark. Returns
/// the transfers seeded for the requested wallet address (case-
/// insensitive); throws on any unscripted call so a misconfigured
/// benchmark fails loudly.
///
/// Implemented as an immutable `Sendable` struct — every stored value is
/// already Sendable so there is no concurrent-mutation surface.
struct ScriptedBenchmarkAlchemyClient: AlchemyClient, Sendable {
  private let transfersByWallet: [String: [AlchemyTransfer]]

  init(transfersByWallet: [String: [AlchemyTransfer]]) {
    self.transfersByWallet = transfersByWallet
  }

  struct UnscriptedTransfersCall: Error { let walletAddress: String }

  func getAssetTransfers(
    chain: ChainConfig,
    walletAddress: String,
    fromBlock: UInt64
  ) async throws -> [AlchemyTransfer] {
    if let scripted = transfersByWallet[walletAddress.lowercased()] {
      return scripted
    }
    throw UnscriptedTransfersCall(walletAddress: walletAddress)
  }

  /// Thrown when a benchmark path triggers an unscripted receipt fetch.
  /// The current crypto-sync benchmarks don't exercise the gas-leg
  /// pipeline, so any invocation here is a wiring bug worth surfacing.
  struct UnscriptedReceiptCall: Error { let hash: String }

  func getTransactionReceipt(
    chain: ChainConfig,
    hash: String
  ) async throws -> AlchemyTransactionReceipt {
    throw UnscriptedReceiptCall(hash: hash)
  }
}

/// Returns a successful CoinGecko mapping for every input. Used by the
/// benchmark discovery service so token resolution never fails.
///
/// Stateless `Sendable` struct — no per-call resources to acquire and
/// no concurrent-mutation surface.
struct BenchmarkRegistrationResolver: CryptoRegistrationResolver, Sendable {
  func resolveRegistration(
    chainId: Int,
    contractAddress: String?,
    symbol: String?,
    isNative: Bool
  ) async throws -> CryptoRegistration {
    let resolvedSymbol = symbol ?? "TKN"
    let instrument = Instrument.crypto(
      chainId: chainId,
      contractAddress: isNative ? nil : contractAddress,
      symbol: resolvedSymbol,
      name: resolvedSymbol,
      decimals: 18)
    let mapping = CryptoProviderMapping(
      instrumentId: instrument.id,
      coingeckoId: "bench-\(resolvedSymbol)",
      binanceSymbol: nil)
    return CryptoRegistration(instrument: instrument, mapping: mapping)
  }
}
