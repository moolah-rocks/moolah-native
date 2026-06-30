import Foundation
import os

struct Instrument: Codable, Sendable, Hashable, Identifiable {
  enum Kind: String, Codable, Sendable, CaseIterable {
    case fiatCurrency
    case stock
    case cryptoToken
  }

  let id: String
  let kind: Kind
  let name: String
  let decimals: Int

  // Kind-specific metadata (all optional)
  let ticker: String?
  let exchange: String?
  let chainId: Int?
  let contractAddress: String?

  /// Factory for fiat currency instruments.
  /// Derives decimal places from the system locale database.
  static func fiat(code: String) -> Instrument {
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencyCode = code
    return Instrument(
      id: code,
      kind: .fiatCurrency,
      name: code,
      decimals: formatter.maximumFractionDigits,
      ticker: nil,
      exchange: nil,
      chainId: nil,
      contractAddress: nil
    )
  }

  /// Derive the currency symbol from the currency's representative locale (fiat only).
  /// Returns nil for non-fiat instruments.
  var currencySymbol: String? {
    guard kind == .fiatCurrency else { return nil }
    return Self.preferredCurrencySymbol(for: id)
  }

  /// Factory for stock instruments.
  /// `ticker` is the Yahoo Finance symbol (e.g., "BHP.AX") and, together with
  /// `exchange`, forms the canonical id as `"\(exchange):\(ticker)"`.
  /// `exchange` is the exchange code (e.g., "ASX", "NASDAQ") and is part of identity.
  /// `name` is the display name (e.g., "BHP", "Apple") and does not influence
  /// identity — two rows with the same exchange and ticker but different names
  /// are the same instrument.
  /// `decimals` defaults to 0 (whole shares); override for fractional instruments.
  static func stock(ticker: String, exchange: String, name: String, decimals: Int = 0) -> Instrument
  {
    Instrument(
      id: "\(exchange):\(ticker)",
      kind: .stock,
      name: name,
      decimals: decimals,
      ticker: ticker,
      exchange: exchange,
      chainId: nil,
      contractAddress: nil
    )
  }

  /// Convenience: the ticker symbol for display. For crypto, this is the short symbol (ETH, BTC).
  /// For stocks, the exchange ticker. For fiat, nil (use currencySymbol instead).
  var displaySymbol: String? {
    ticker
  }

  /// Best user-facing short label for this instrument, suitable as a prefix next to a
  /// numeric input field or row label.
  /// - Fiat: the OS-localised currency symbol (e.g., "£", "$", or the ISO code on locales
  ///   that don't define a narrow symbol for the currency).
  /// - Stock/crypto: the ticker (e.g., "BHP.AX", "ETH").
  /// Falls back to `id`/`name` if neither is available.
  var displayLabel: String {
    switch kind {
    case .fiatCurrency:
      return currencySymbol ?? id
    case .stock, .cryptoToken:
      return ticker ?? name
    }
  }

  // Convenience constants
  static let AUD = Instrument.fiat(code: "AUD")
  static let USD = Instrument.fiat(code: "USD")
}

extension Instrument {
  /// The 17 most-used fiat currency codes; the canonical seed list for any
  /// fiat-only picker fallback. Sorted by ISO code so order is deterministic.
  static let commonFiatCodes: [String] = [
    "AUD", "CAD", "CHF", "CNY", "EUR", "GBP", "HKD", "INR", "JPY", "KRW",
    "MXN", "NOK", "NZD", "SEK", "SGD", "USD", "ZAR",
  ]
}

extension Instrument {
  /// Short identifier used as the primary label in pickers and inline displays.
  /// - Fiat: ISO code ("AUD").
  /// - Stock/crypto: ticker if present, otherwise the canonical id.
  var shortCode: String {
    switch kind {
    case .fiatCurrency: id
    case .stock, .cryptoToken: ticker ?? id
    }
  }

  /// Full human-readable name shown alongside `shortCode` in pickers, when one
  /// is available and meaningfully different from the code itself.
  /// - Fiat: locale-localised currency name (e.g. "Australian Dollar"); `nil`
  ///   when the locale only echoes the ISO code.
  /// - Stock/crypto: the instrument's `name`; `nil` when it matches the ticker.
  var longDisplayName: String? {
    switch kind {
    case .fiatCurrency:
      let resolved = Self.localizedName(for: id)
      return resolved == id ? nil : resolved
    case .stock, .cryptoToken:
      return name == shortCode ? nil : name
    }
  }

  /// Single-line picker label: "Long Name (CODE)" when a long name is
  /// available, otherwise just the short code.
  var pickerLabel: String {
    if let long = longDisplayName {
      return "\(long) (\(shortCode))"
    }
    return shortCode
  }

  /// Locale-localised currency name for an ISO code, or the code itself
  /// if the locale can't resolve it. Replaces `CurrencyPicker.currencyName(for:)`.
  static func localizedName(for code: String) -> String {
    Locale.current.localizedString(forCurrencyCode: code) ?? code
  }

  /// Currency symbol from the currency's primary locale, not the user's.
  /// Returns nil when no representative locale produces a distinctive
  /// symbol (the result would just echo the ISO code).
  static func preferredCurrencySymbol(for code: String) -> String? {
    symbolCache.withLock { cache in
      if let hit = cache[code] { return hit.value }
      let resolved = Self.shortestCurrencySymbol(for: code)
      cache[code] = SymbolCacheEntry(value: resolved)
      return resolved
    }
  }

  private static func shortestCurrencySymbol(for code: String) -> String? {
    Locale.availableIdentifiers
      .lazy
      .map(Locale.init(identifier:))
      .filter { $0.currency?.identifier == code }
      .compactMap { $0.currencySymbol }
      .filter { !$0.isEmpty && $0 != code }
      .min(by: { $0.count < $1.count })
  }

  private struct SymbolCacheEntry: Sendable { let value: String? }

  private static let symbolCache = OSAllocatedUnfairLock<[String: SymbolCacheEntry]>(
    initialState: [:]
  )
}

extension Instrument {
  /// Human-readable chain name for crypto tokens, used to disambiguate
  /// instruments that share a ticker across chains (e.g. ETH on mainnet,
  /// Optimism, and Base). `nil` for fiat and stocks, which have no chain.
  var chainDisplayName: String? {
    guard kind == .cryptoToken, let chainId else { return nil }
    return Self.chainName(for: chainId)
  }

  /// Human-readable chain name for a given chain ID (crypto tokens).
  static func chainName(for chainId: Int) -> String {
    switch chainId {
    case 0: "Bitcoin"
    case 1: "Ethereum"
    case 10: "Optimism"
    case 137: "Polygon"
    case 42161: "Arbitrum"
    case 8453: "Base"
    case 43114: "Avalanche"
    default: "Chain \(chainId)"
    }
  }

  /// Factory for cryptocurrency token instruments.
  /// Uses a `chainId:address` ID scheme.
  static func crypto(
    chainId: Int,
    contractAddress: String?,
    symbol: String,
    name: String,
    decimals: Int
  ) -> Instrument {
    let normalizedAddress = contractAddress?.lowercased()
    let id: String
    if let address = normalizedAddress {
      id = "\(chainId):\(address)"
    } else {
      id = "\(chainId):native"
    }
    return Instrument(
      id: id,
      kind: .cryptoToken,
      name: name,
      decimals: decimals,
      ticker: symbol,
      exchange: nil,
      chainId: chainId,
      contractAddress: normalizedAddress
    )
  }
}
