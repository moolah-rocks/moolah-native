// Shared/CryptoImport/DirectRPC/TokenMetadataResolver.swift
import Foundation
import OSLog

/// Resolves ERC-20 `decimals()`/`symbol()` metadata per contract address via
/// `eth_call`, caching each contract so the direct-RPC discovery pipeline
/// (one lookup per unique `Transfer` log's contract, potentially thousands
/// of logs) issues at most one pair of calls per contract per sync session.
///
/// An `actor` rather than a plain cache wrapper because the cache is
/// mutated from concurrent callers — `WalletSyncEngine`/`LogTransferMapper`
/// callers resolve metadata for many logs in parallel, and several of those
/// logs commonly share the same contract (e.g. a wallet with many USDC
/// transfers). Concurrent `metadata(for:)` calls for the *same* contract
/// before its first resolution completes share one in-flight `Task` — the
/// second (and later) caller awaits the first's result instead of issuing a
/// duplicate `eth_call` pair. Calls for *different* contracts still proceed
/// independently/concurrently; only same-key calls coalesce.
actor TokenMetadataResolver {
  /// Resolved ERC-20 metadata for one contract. `symbol` is best-effort —
  /// `nil` when `symbol()` reverts or its result can't be decoded — since a
  /// missing symbol doesn't block using the token (decimals is what scaling
  /// depends on), whereas a contract without usable `decimals()` is dropped
  /// entirely by the caller.
  struct Metadata: Sendable, Equatable {
    let decimals: Int
    let symbol: String?
  }

  /// 4-byte selector for `decimals() returns (uint8)` — `keccak256("decimals()")[0..4]`.
  private static let decimalsSelector = "0x313ce567"
  /// 4-byte selector for `symbol() returns (string)` — `keccak256("symbol()")[0..4]`.
  private static let symbolSelector = "0x95d89b41"
  /// Valid range for `decimals()`'s declared `uint8` return type. A hostile
  /// or buggy contract can return a value outside this range (e.g.
  /// 5_000_000_000) that still parses as an `Int` — downstream `pow(10,
  /// decimals)` amount scaling can't handle that safely, so it's rejected
  /// here rather than trusted.
  private static let validDecimalsRange = 0...255

  private static let logger = Logger(
    subsystem: "com.moolah.app", category: "TokenMetadataResolver")

  private let rpc: LiveJSONRPCClient
  /// Cache keyed by lowercased contract address. The value is itself
  /// optional (`Metadata?`) so a resolved-to-`nil` contract (decimals
  /// unreadable) is distinguished from "not yet looked up" — that negative
  /// result is cached too, deliberately: a contract whose `decimals()`
  /// reverts or returns empty/out-of-range isn't going to start working
  /// later in the same sync session, and without caching the negative
  /// result every log naming that contract would re-issue the same failing
  /// `eth_call`. A *transient* failure (rate limit, network blip,
  /// cancellation) is NOT cached here — see `ResolveOutcome` — so a later
  /// log naming the same contract gets another attempt.
  private var cache: [String: Metadata?] = [:]
  /// In-flight resolution per contract, so concurrent callers for the same
  /// not-yet-cached contract share one underlying RPC round-trip pair
  /// instead of each starting their own.
  private var inFlight: [String: Task<ResolveOutcome, Never>] = [:]

  init(rpc: LiveJSONRPCClient) {
    self.rpc = rpc
  }

  /// Resolves `decimals()`/`symbol()` for `contract`, case-insensitively
  /// cached by address. Returns `nil` when `decimals()` reverts, returns an
  /// empty/malformed/out-of-range result, or the lookup fails transiently
  /// (rate limit/network/cancellation) — the caller can't scale that
  /// token's raw transfer amounts, so it drops the token's rows rather than
  /// guessing. Only a *permanent* failure is cached; a transient one is
  /// retried on the next `metadata(for:)` call naming the same contract.
  func metadata(for contract: String) async -> Metadata? {
    let key = contract.lowercased()
    if let cached = cache[key] {
      return cached
    }
    if let pending = inFlight[key] {
      return await pending.value.metadata
    }
    let rpc = self.rpc
    let task = Task { await Self.resolve(rpc: rpc, contract: key) }
    inFlight[key] = task
    let outcome = await task.value
    inFlight[key] = nil
    if !outcome.isTransientFailure {
      cache[key] = outcome.metadata
    }
    return outcome.metadata
  }

  /// Outcome of one `resolve(rpc:contract:)` attempt. `metadata(for:)` uses
  /// `isTransientFailure` to decide whether the result is worth
  /// negative-caching — a permanent failure (revert, malformed/empty/
  /// out-of-range result) is remembered as "this contract doesn't work",
  /// while a transient one (rate limit, network blip, cancellation) is
  /// not, so a later lookup for the same contract gets another attempt.
  private struct ResolveOutcome: Sendable {
    let metadata: Metadata?
    let isTransientFailure: Bool

    static func resolved(_ metadata: Metadata) -> ResolveOutcome {
      ResolveOutcome(metadata: metadata, isTransientFailure: false)
    }

    static let permanentFailure = ResolveOutcome(metadata: nil, isTransientFailure: false)
    static let transientFailure = ResolveOutcome(metadata: nil, isTransientFailure: true)
  }

  /// Performs the two `eth_call`s for one contract. `static` (not
  /// actor-isolated) so it runs on the `Task` it's launched from rather
  /// than hopping back onto the actor for every `await` inside it — the
  /// actor is only touched to read/write the cache and in-flight table in
  /// `metadata(for:)`.
  private static func resolve(rpc: LiveJSONRPCClient, contract: String) async -> ResolveOutcome {
    do {
      guard let decimals = try await fetchDecimals(rpc: rpc, contract: contract) else {
        logger.debug(
          "Dropping contract \(contract, privacy: .public): decimals() unreadable or out of uint8 range"
        )
        return .permanentFailure
      }
      let symbol = await fetchSymbol(rpc: rpc, contract: contract)
      return .resolved(Metadata(decimals: decimals, symbol: symbol))
    } catch {
      if isTransient(error) {
        logger.debug(
          "Deferring contract \(contract, privacy: .public): transient decimals() failure, will retry"
        )
        return .transientFailure
      }
      logger.debug(
        "Dropping contract \(contract, privacy: .public): decimals() call failed permanently (\(String(describing: error), privacy: .public))"
      )
      return .permanentFailure
    }
  }

  /// Classifies an error thrown by `rpc.call` as transient (rate limit,
  /// network blip, task cancellation — worth retrying on a later lookup)
  /// or permanent (contract revert/malformed response — this contract
  /// truly doesn't support the call, worth remembering as such for the
  /// rest of the sync session).
  private static func isTransient(_ error: Error) -> Bool {
    if error is CancellationError {
      return true
    }
    guard let walletError = error as? WalletSyncError else {
      return false
    }
    switch walletError.kind {
    case .rateLimited, .network:
      return true
    case .missingApiKey, .invalidApiKey, .providerMalformedResponse:
      return false
    }
  }

  /// Fetches and parses `decimals()`. Returns `nil` (a permanent failure,
  /// not thrown) when the result is empty/unparseable or outside the ABI
  /// `uint8` range; propagates any `rpc.call` error for the caller to
  /// classify as transient vs. permanent.
  private static func fetchDecimals(rpc: LiveJSONRPCClient, contract: String) async throws -> Int? {
    let hex = try await rpc.call(to: contract, data: decimalsSelector)
    guard let decimals = HexDecimal.parseInt(hex), validDecimalsRange.contains(decimals) else {
      return nil
    }
    return decimals
  }

  /// Fetches and decodes `symbol()`. `symbol` is best-effort (see
  /// `Metadata`'s doc comment), so any failure — transient or permanent —
  /// simply yields `nil` here rather than failing the whole contract
  /// resolution; only `decimals()` failures are classified/negative-cached.
  private static func fetchSymbol(rpc: LiveJSONRPCClient, contract: String) async -> String? {
    guard let hex = try? await rpc.call(to: contract, data: symbolSelector) else {
      return nil
    }
    return decodeABIString(hex)
  }

  // MARK: - ABI string decoding

  /// Decodes an `eth_call` result for a call that returns a single
  /// `string`. Standard ERC-20 `symbol()` returns the dynamic ABI form —
  /// an offset word, then at that offset a length word followed by the
  /// UTF-8 bytes (zero-padded to a 32-byte boundary). Some legacy tokens
  /// (deployed before the dynamic-`string` convention was standard —
  /// e.g. MKR) instead return a fixed `bytes32`: a single 32-byte,
  /// right-zero-padded ASCII/UTF-8 blob with no offset/length prefix. Both
  /// shapes are tried; `nil` if neither decodes to non-empty UTF-8.
  private static func decodeABIString(_ result: String) -> String? {
    let hex =
      result.hasPrefix("0x") || result.hasPrefix("0X") ? String(result.dropFirst(2)) : result
    if let dynamic = decodeDynamicABIString(hex) {
      return dynamic
    }
    return decodeBytes32ABIString(hex)
  }

  private static let abiWordHexLength = 64

  /// Decodes the dynamic ABI `string` layout. `offsetBytes`/`lengthBytes`
  /// come from a hostile contract's response and must be bounded against
  /// the actual input length *before* they're multiplied by 2 (hex chars
  /// per byte) — an unbounded `offsetBytes * 2`/`lengthBytes * 2` can
  /// overflow-trap on a huge offset/length word (e.g. one near `Int.max`,
  /// which `Int(word, radix: 16)` parses successfully) and crash the
  /// entire sync.
  private static func decodeDynamicABIString(_ hex: String) -> String? {
    guard hex.count >= abiWordHexLength else { return nil }
    let maxByteOffset = hex.count / 2
    let offsetWord = String(hex.prefix(abiWordHexLength))
    guard let offsetBytes = Int(offsetWord, radix: 16), offsetBytes <= maxByteOffset else {
      return nil
    }
    let offsetHexIndex = offsetBytes * 2
    guard hex.count >= offsetHexIndex + abiWordHexLength else { return nil }
    let lengthWord = String(hex.dropFirst(offsetHexIndex).prefix(abiWordHexLength))
    guard let lengthBytes = Int(lengthWord, radix: 16), lengthBytes > 0,
      lengthBytes <= maxByteOffset
    else { return nil }
    let dataStart = offsetHexIndex + abiWordHexLength
    let dataHexLength = lengthBytes * 2
    guard hex.count >= dataStart + dataHexLength else { return nil }
    let dataHex = String(hex.dropFirst(dataStart).prefix(dataHexLength))
    return utf8String(fromHex: dataHex)
  }

  private static func decodeBytes32ABIString(_ hex: String) -> String? {
    guard hex.count == abiWordHexLength else { return nil }
    return utf8String(fromHex: hex, trimTrailingZeroBytes: true)
  }

  /// Converts a hex byte string to UTF-8. `trimTrailingZeroBytes` strips
  /// the fixed `bytes32` form's right-padding before decoding; the dynamic
  /// form's caller already slices to the declared length, so it has no
  /// padding to trim.
  private static func utf8String(fromHex hex: String, trimTrailingZeroBytes: Bool = false)
    -> String?
  {
    guard hex.count.isMultiple(of: 2) else { return nil }
    var bytes: [UInt8] = []
    bytes.reserveCapacity(hex.count / 2)
    var index = hex.startIndex
    while index < hex.endIndex {
      let next = hex.index(index, offsetBy: 2)
      guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
      bytes.append(byte)
      index = next
    }
    if trimTrailingZeroBytes {
      while bytes.last == 0 { bytes.removeLast() }
    }
    guard !bytes.isEmpty, let string = String(bytes: bytes, encoding: .utf8) else { return nil }
    return string
  }
}
