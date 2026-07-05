// Shared/CryptoImport/AlchemyTransactionReceipt.swift
import Foundation

/// Decoded subset of Alchemy `eth_getTransactionReceipt` response.
/// Used to compute the gas leg on outbound transfers — Alchemy's
/// transfer endpoint doesn't include gas-cost data per transfer, so
/// the wallet sync pipeline fetches the receipt for any unique
/// outbound `txHash`.
///
/// `gasUsed` is the actual amount of gas consumed (post-execution).
/// `effectiveGasPrice` is the per-gas price actually paid (post-EIP-1559
/// — handles base fee + priority tip). Multiplying gives wei spent on gas.
///
/// Both fields decode from `0x`-prefixed hex strings; we normalise to
/// `Decimal` to preserve precision (256-bit values overflow `UInt64`).
struct AlchemyTransactionReceipt: Sendable, Hashable {
  /// On-chain transaction hash (`0x`-prefixed). Used by the builder to
  /// key receipts back to the originating event.
  let hash: String
  /// Gas units actually consumed by the transaction. Decoded from the
  /// `gasUsed` 0x-hex field on the receipt.
  let gasUsed: Decimal
  /// Effective per-gas price actually paid in wei. Decoded from the
  /// `effectiveGasPrice` 0x-hex field; covers both base fee and priority
  /// tip post-EIP-1559.
  let effectiveGasPrice: Decimal
  /// EOA that signed the on-chain transaction (lowercased). Sourced from
  /// the `from` field on `eth_getTransactionReceipt`. The gas-leg
  /// builder compares this against the synced wallet address — gas is
  /// only attributed to a wallet that signed the outer tx. An `.internal`
  /// or `erc20 transferFrom` row can have `transfer.from == wallet`
  /// while `receipt.from` is a different EOA; that wallet did not pay
  /// gas and gets no `:gas` leg.
  let from: String
  /// OP-stack L1 data fee in wei, decoded from the receipt's `l1Fee`
  /// field. `nil` on chains that don't post calldata to an L1 (Ethereum,
  /// Polygon) — the field is absent there. On Optimism / Base this is
  /// usually the dominant cost; `TransferReceiptCoalescer.makeGasLeg`
  /// adds it to the gas-leg quantity, gated by
  /// `ChainConfig.chargesL1DataFee` (#920). Kept separate from
  /// `l2ExecutionFeeWei` because the receipt is chain-agnostic — only
  /// the gas-leg builder knows whether this chain charges it.
  let l1FeeWei: Decimal?
  /// Event logs emitted by the transaction, in on-chain order. Empty
  /// for receipts that don't need them (the gas-leg builder never reads
  /// this field) and defaulted to `[]` in the memberwise init below so
  /// every pre-existing call site is unaffected. Read by the wrap/unwrap
  /// detector to find WETH `Deposit`/`Withdrawal` events.
  let logs: [ReceiptLog]

  /// L2 execution fee — `gasUsed * effectiveGasPrice` in wei. This is
  /// the *whole* transaction fee on Ethereum / Polygon, but only the L2
  /// portion on OP-stack chains (the L1 data fee is `l1FeeWei`). Caller
  /// divides by `10 ** chain.nativeInstrument.decimals` to get native
  /// units.
  var l2ExecutionFeeWei: Decimal {
    gasUsed * effectiveGasPrice
  }

  /// Hand-written rather than synthesized: a *defaulted* `let` stored
  /// property is excluded from Swift's synthesized memberwise
  /// initializer entirely (SE-0242 only defaults `var` parameters), so
  /// `l1FeeWei` could not be set at all without this init. It exists to
  /// expose `l1FeeWei` as an optional parameter — the pre-OP-stack call
  /// sites and L1-chain test stubs that omit it stay unchanged — not to
  /// duplicate synthesized behaviour. Do not "simplify" it away.
  init(
    hash: String,
    gasUsed: Decimal,
    effectiveGasPrice: Decimal,
    from: String,
    l1FeeWei: Decimal? = nil,
    logs: [ReceiptLog] = []
  ) {
    self.hash = hash
    self.gasUsed = gasUsed
    self.effectiveGasPrice = effectiveGasPrice
    self.from = from
    self.l1FeeWei = l1FeeWei
    self.logs = logs
  }
}

/// A single event log entry from a transaction receipt. Used by the
/// wrap/unwrap detector to recognise WETH `Deposit`/`Withdrawal` events
/// (`topics[0]` is the event signature hash; `address` identifies the
/// emitting contract).
struct ReceiptLog: Sendable, Hashable {
  /// Contract address that emitted the log (lowercased on decode).
  let address: String
  /// Indexed event topics, `0x`-prefixed. `topics[0]` is conventionally
  /// the event signature hash for non-anonymous events.
  let topics: [String]
  /// ABI-encoded non-indexed event data, `0x`-prefixed hex.
  let data: String
  /// Position of this log within the transaction's full log list.
  /// Decoded from the `logIndex` 0x-hex field.
  let logIndex: Int
}

/// Lenient `0x`-prefixed hex parser shared by the `ChainDataClient`
/// receipt decoder and the `AlchemyTransfer.RawContract` value
/// accessors. Returns `nil` on malformed input so callers can log and
/// skip without failing the whole sync.
///
/// `Decimal` is the target type because 256-bit on-chain integers
/// overflow `UInt64` (gas-fee products in particular routinely exceed
/// 64 bits once `gasUsed * effectiveGasPrice` lands in wei).
enum HexDecimal {
  /// Parses a 0x-prefixed (or unprefixed) hex string into a `Decimal`.
  /// Returns `nil` on empty input or any non-hex character.
  static func parse(_ string: String) -> Decimal? {
    let trimmed = stripHexPrefix(string)
    guard !trimmed.isEmpty else { return nil }
    var result: Decimal = 0
    for char in trimmed {
      guard let nibble = char.hexDigitValue else { return nil }
      result = result * 16 + Decimal(nibble)
    }
    return result
  }

  /// Parses a 0x-prefixed hex string into an `Int`. Returns `nil` on
  /// malformed input or values that exceed `Int.max`.
  static func parseInt(_ string: String) -> Int? {
    let trimmed = stripHexPrefix(string)
    return Int(trimmed, radix: 16)
  }

  private static func stripHexPrefix(_ string: String) -> String {
    string.hasPrefix("0x") || string.hasPrefix("0X")
      ? String(string.dropFirst(2))
      : string
  }
}
