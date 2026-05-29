import Foundation

// SyncBoundary — adding a case requires bumping DataFormatVersion.current.
//
// `exchangeProvider` is a synced field; older builds decode unknown values
// as nil and never sync the account.
/// Centralised exchange a `.exchange` account syncs from. String-backed so it
/// round-trips through GRDB and CloudKit as a stable token.
enum ExchangeProvider: String, Codable, Sendable, CaseIterable {
  case coinstash

  /// Human-readable name shown in account-creation UI and settings.
  var displayName: String {
    switch self {
    case .coinstash: return "Coinstash"
    }
  }

  /// Help article for creating a read-only key (used by the creation UI).
  var helpURL: URL {
    switch self {
    case .coinstash: Self.Links.coinstashHelp
    }
  }

  /// Provider website (used by the synced-account header "open externally").
  var website: URL {
    switch self {
    case .coinstash: Self.Links.coinstashHome
    }
  }

  // String-literal URLs: a parse failure is a programming error, not runtime
  // input (same pattern as AppStoreURL.swift).
  private enum Links {
    static let coinstashHelp = URL(
      string:
        "https://help.coinstash.com.au/en/articles/13481155-how-do-i-use-the-coinstash-api")!  // swiftlint:disable:this force_unwrapping
    static let coinstashHome = URL(
      string: "https://coinstash.com.au")!  // swiftlint:disable:this force_unwrapping
  }
}
