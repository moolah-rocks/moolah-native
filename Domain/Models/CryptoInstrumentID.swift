// Domain/Models/CryptoInstrumentID.swift
import Foundation

/// Parses a crypto `Instrument.id` of the form `"<chainId>:native"` or
/// `"<chainId>:<contractAddress>"` back into its components. Shared by the
/// price service and the discovery service's canonicalization decomposition.
enum CryptoInstrumentID {
  /// Extracts the chain id from a crypto instrument id of the form
  /// `"<chainId>:native"` or `"<chainId>:<contractAddress>"`. Returns
  /// `nil` when the id does not match the expected format.
  static func chainId(from id: String) -> Int? {
    Int(id.prefix(while: { $0 != ":" }))
  }

  /// Extracts the contract-address segment from a crypto instrument id of the
  /// form `"<chainId>:<contractAddress>"`. Returns `nil` for a native id
  /// (`"<chainId>:native"`) or an id without a `:` separator — matching the
  /// `contractAddress == nil` shape of a native `Instrument`, so the value
  /// round-trips through `WrappedNativeContracts.nativePricingInstrumentId`.
  static func contractAddress(from id: String) -> String? {
    guard let colon = id.firstIndex(of: ":") else { return nil }
    let suffix = String(id[id.index(after: colon)...])
    return suffix == "native" ? nil : suffix
  }
}
