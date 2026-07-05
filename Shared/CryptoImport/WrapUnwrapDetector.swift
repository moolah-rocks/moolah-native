// Shared/CryptoImport/WrapUnwrapDetector.swift
import Foundation

/// Recovers the WETH `.erc20` leg that a native-only view of a wrap or unwrap
/// omits. Wrapping ETH (`WETH.deposit()`) moves native ETH to the wrapped
/// contract and mints WETH back to the wallet via a `Deposit` event; the mint
/// carries no ERC-20 `Transfer` from a real address, so the token side is
/// invisible to both the wrapped-native mint/burn guard and Alchemy's transfer
/// API. This detector scans the (few) native movements that touch a chain's
/// canonical wrapped-native contract, fetches just those receipts, and
/// synthesizes the missing WETH-in (wrap) or WETH-out (unwrap) transfer from
/// the receipt's `Deposit` / `Withdrawal` log.
///
/// `Sendable` struct with no mutable state; the injected `ChainDataClient` is
/// itself `Sendable`.
struct WrapUnwrapResult: Sendable {
  /// Synthesized WETH `.erc20` legs recovered from candidate receipts.
  let rows: [AlchemyTransfer]
  /// Every receipt `detect` fetched, keyed by transaction hash. A wrap's
  /// candidate hash is also the outbound `external` gas-leg hash the
  /// coalescer would otherwise re-fetch — sharing this dictionary with
  /// `TransferEventBuilder` avoids fetching the same receipt twice in one
  /// build pass.
  let receipts: [String: AlchemyTransactionReceipt]
}

struct WrapUnwrapDetector: Sendable {
  private let chainClient: any ChainDataClient

  init(chainClient: any ChainDataClient) {
    self.chainClient = chainClient
  }

  /// `keccak256("Deposit(address,uint256)")` — topic0 of a wrapped-native
  /// `Deposit(dst, wad)` event, emitted when native is wrapped. `dst`
  /// (`topics[1]`) is the wallet credited the new WETH.
  private static let depositTopic =
    "0xe1fffcc4923d04b559f4d29a8bfc6cda04eb5b0d3c460751c2402c5c5cc9109c"
  /// `keccak256("Withdrawal(address,uint256)")` — topic0 of a wrapped-native
  /// `Withdrawal(src, wad)` event, emitted when WETH is unwrapped. `src`
  /// (`topics[1]`) is the wallet whose WETH is burned.
  private static let withdrawalTopic =
    "0x7fcf532c15f0a6db0bd6d0e038bea71d30d808c7d98cb3bf7268a95bf5081b65"
  /// 18-decimals as a 0x-hex string — every listed wrapped-native token
  /// shares the native asset's 18 decimals.
  private static let wrappedNativeDecimals = "0x12"

  /// Scans `nativeTransfers` for wrap / unwrap candidates, fetches each
  /// distinct candidate hash's receipt once, and returns the synthesized
  /// WETH `.erc20` legs together with every receipt fetched. A candidate
  /// whose receipt carries no matching `Deposit` / `Withdrawal` log yields
  /// no row, but its receipt is still returned — the caller (`WalletSyncEngine`)
  /// forwards it to `TransferEventBuilder` so a wrap/unwrap candidate's
  /// receipt (which is also its outbound `external` gas-leg receipt) is
  /// never fetched a second time.
  func detect(
    nativeTransfers: [AlchemyTransfer],
    chain: ChainConfig,
    walletAddress: String
  ) async throws -> WrapUnwrapResult {
    let wallet = walletAddress.lowercased()
    let candidates = nativeTransfers.compactMap { candidate($0, chain: chain, wallet: wallet) }
    guard !candidates.isEmpty else { return WrapUnwrapResult(rows: [], receipts: [:]) }

    // De-dup: one receipt fetch per hash even when several candidate legs
    // share a transaction.
    var receipts: [String: AlchemyTransactionReceipt] = [:]
    for hash in Set(candidates.map(\.transfer.hash)) {
      receipts[hash] = try await chainClient.getTransactionReceipt(chain: chain, hash: hash)
    }

    let rows = candidates.compactMap { candidate in
      synthesize(candidate, receipt: receipts[candidate.transfer.hash], wallet: wallet)
    }
    return WrapUnwrapResult(rows: rows, receipts: receipts)
  }

  // MARK: - Internals

  /// Whether a native transfer is a wrap or an unwrap of the chain's canonical
  /// wrapped-native contract, and which direction. A `.external` send from the
  /// wallet *to* the wrapped contract is a wrap; an `.internal` receive *from*
  /// the wrapped contract to the wallet is an unwrap. Any other transfer is
  /// not a candidate.
  private func candidate(
    _ transfer: AlchemyTransfer,
    chain: ChainConfig,
    wallet: String
  ) -> Candidate? {
    switch transfer.category {
    case .external:
      guard transfer.from.lowercased() == wallet,
        let contract = transfer.to,
        WrappedNativeContracts.nativePricingInstrumentId(
          chainId: chain.chainId, contractAddress: contract) != nil
      else { return nil }
      return Candidate(transfer: transfer, wrappedContract: contract.lowercased(), direction: .wrap)
    case .internal:
      guard transfer.to?.lowercased() == wallet,
        WrappedNativeContracts.nativePricingInstrumentId(
          chainId: chain.chainId, contractAddress: transfer.from) != nil
      else { return nil }
      return Candidate(
        transfer: transfer, wrappedContract: transfer.from.lowercased(), direction: .unwrap)
    case .erc20, .unknown:
      return nil
    }
  }

  /// Builds the synthetic WETH `.erc20` transfer for `candidate` from its
  /// receipt's `Deposit` / `Withdrawal` log, or `nil` when the receipt is
  /// missing or has no matching log. The `wad` (unscaled 18-decimals value)
  /// is carried verbatim as the raw hex; direction is expressed via `from` /
  /// `to`, never a sign.
  private func synthesize(
    _ candidate: Candidate,
    receipt: AlchemyTransactionReceipt?,
    wallet: String
  ) -> AlchemyTransfer? {
    guard let receipt,
      let log = matchingLog(in: receipt, candidate: candidate, wallet: wallet)
    else { return nil }

    let contract = candidate.wrappedContract
    let from: String
    let to: String
    switch candidate.direction {
    case .wrap:
      // WETH credited in: from the contract to the wallet.
      from = contract
      to = wallet
    case .unwrap:
      // WETH burned out: from the wallet to the contract.
      from = wallet
      to = contract
    }

    let native = candidate.transfer
    return AlchemyTransfer(
      hash: native.hash,
      uniqueId: "\(native.hash):erc20:\(log.logIndex)",
      from: from,
      to: to,
      category: .erc20,
      asset: nil,
      rawContract: AlchemyTransfer.RawContract(
        address: contract, decimal: Self.wrappedNativeDecimals, rawValue: log.data),
      metadata: native.metadata,
      blockNum: native.blockNum)
  }

  /// Finds the wrapped-native event log for `candidate`: the right topic0
  /// (`Deposit` for a wrap, `Withdrawal` for an unwrap), emitted by the
  /// wrapped contract, with the wallet as the event's `dst` / `src`
  /// (`topics[1]`).
  private func matchingLog(
    in receipt: AlchemyTransactionReceipt,
    candidate: Candidate,
    wallet: String
  ) -> ReceiptLog? {
    let topic = candidate.direction == .wrap ? Self.depositTopic : Self.withdrawalTopic
    return receipt.logs.first { log in
      guard log.topics.count >= 2 else { return false }
      return log.topics[0] == topic
        && log.address.lowercased() == candidate.wrappedContract
        && RPCHex.addressFromTopic(log.topics[1]) == wallet
    }
  }

  /// A native movement identified as a wrap or unwrap, carrying the wrapped
  /// contract (lowercased) and the direction the synthetic WETH leg flows.
  private struct Candidate {
    let transfer: AlchemyTransfer
    let wrappedContract: String
    let direction: Direction
  }

  /// Which way the synthetic WETH leg flows: `wrap` credits WETH to the
  /// wallet; `unwrap` burns the wallet's WETH.
  private enum Direction {
    case wrap
    case unwrap
  }
}
