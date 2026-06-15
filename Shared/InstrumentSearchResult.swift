import Foundation

/// One candidate returned by `InstrumentSearchService`. May represent an
/// already-registered instrument (pulled from `InstrumentRegistryRepository`),
/// a crypto provider hit that still needs resolution before it can be
/// persisted, a validated stock ticker, or an ambient fiat currency.
struct InstrumentSearchResult: Sendable {
  let instrument: Instrument
  let cryptoMapping: CryptoProviderMapping?
  let isRegistered: Bool
  let requiresResolution: Bool

  /// The human-readable name the query was matched against for relevance
  /// ranking. For fiat this is the locale-localized currency name (e.g.
  /// "US Dollar") because `Instrument.fiat` stores only the ISO code as `name`.
  let matchName: String

  /// Custom init so `matchName` can default to `instrument.name`; the
  /// synthesized memberwise init cannot derive a default from another argument.
  init(
    instrument: Instrument,
    cryptoMapping: CryptoProviderMapping?,
    isRegistered: Bool,
    requiresResolution: Bool,
    matchName: String? = nil
  ) {
    self.instrument = instrument
    self.cryptoMapping = cryptoMapping
    self.isRegistered = isRegistered
    self.requiresResolution = requiresResolution
    self.matchName = matchName ?? instrument.name
  }
}

extension InstrumentSearchResult: Identifiable {
  var id: String { instrument.id }
}

extension InstrumentSearchResult: Equatable {
  static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

extension InstrumentSearchResult: Hashable {
  func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
