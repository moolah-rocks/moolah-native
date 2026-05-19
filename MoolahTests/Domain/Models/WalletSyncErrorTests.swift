// MoolahTests/Domain/Models/WalletSyncErrorTests.swift
import Foundation
import Testing

@testable import Moolah

@Suite("WalletSyncError")
struct WalletSyncErrorTests {
  @Test("Static factories produce provider-less errors")
  func factoriesAreUnattributed() {
    #expect(WalletSyncError.missingApiKey.provider == nil)
    #expect(WalletSyncError.missingApiKey.kind == .missingApiKey)
    let net = WalletSyncError.network(underlyingDescription: "boom")
    #expect(net.provider == nil)
    #expect(net.kind == .network(underlyingDescription: "boom"))
  }

  @Test("attributed(to:) stamps an unattributed error")
  func attributedStampsWhenNil() {
    let stamped = WalletSyncError.network(underlyingDescription: "x")
      .attributed(to: .alchemy)
    #expect(stamped.provider == .alchemy)
    #expect(stamped.kind == .network(underlyingDescription: "x"))
  }

  @Test("attributed(to:) is innermost-wins — does not overwrite")
  func attributedDoesNotOverwrite() {
    let inner = WalletSyncError(provider: .blockExplorer, kind: .invalidApiKey)
    let outer = inner.attributed(to: .alchemy)
    #expect(outer.provider == .blockExplorer)
  }

  @Test("New shape round-trips through JSON")
  func newShapeRoundTrips() throws {
    let original = WalletSyncError(
      provider: .coinstash, kind: .rateLimited(retryAfter: nil))
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(WalletSyncError.self, from: data)
    #expect(decoded == original)
  }

  @Test("Legacy bare-enum JSON decodes as provider: nil")
  func legacyJSONDecodes() throws {
    let legacy = #"{"network":{"underlyingDescription":"old failure"}}"#
    let decoded = try JSONDecoder().decode(
      WalletSyncError.self, from: Data(legacy.utf8))
    #expect(decoded.provider == nil)
    #expect(decoded.kind == .network(underlyingDescription: "old failure"))
  }

  @Test("Legacy bare-enum JSON for a no-payload case decodes")
  func legacyNoPayloadCaseDecodes() throws {
    let legacy = #"{"missingApiKey":{}}"#
    let decoded = try JSONDecoder().decode(
      WalletSyncError.self, from: Data(legacy.utf8))
    #expect(decoded.provider == nil)
    #expect(decoded.kind == .missingApiKey)
  }

  @Test("rateLimited with a non-nil retryAfter survives JSON round-trip")
  func rateLimitedDateRoundTrips() throws {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let original = WalletSyncError(
      provider: .alchemy, kind: .rateLimited(retryAfter: date))
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(WalletSyncError.self, from: data)
    #expect(decoded == original)
    #expect(decoded.kind == .rateLimited(retryAfter: date))
  }

  // MARK: - LocalizedError

  /// Any surface that renders `error.localizedDescription` (e.g.
  /// `AnalysisView`) must show a human-readable sentence, never the
  /// `NSError` fallback "Moolah.WalletSyncError error 1" that hid the
  /// real failure cause on the analysis page.
  @Test("localizedDescription is human-readable, never the NSError fallback")
  func localizedDescriptionIsHumanReadable() {
    let cases: [WalletSyncError] = [
      WalletSyncError(provider: nil, kind: .missingApiKey),
      WalletSyncError(provider: .alchemy, kind: .invalidApiKey),
      WalletSyncError(provider: .coinGecko, kind: .rateLimited(retryAfter: nil)),
      WalletSyncError(provider: nil, kind: .network(underlyingDescription: "HTTP 500")),
      WalletSyncError(
        provider: .coinGecko, kind: .providerMalformedResponse(stage: "dailyPrices")),
    ]
    for error in cases {
      let message = error.localizedDescription
      #expect(!message.isEmpty)
      #expect(!message.contains("WalletSyncError"))
      #expect(!message.contains("error 1"))
      #expect(!message.contains("couldn’t be completed"))
    }
  }

  @Test("errorDescription names the attributed provider and the failure kind")
  func errorDescriptionNamesProviderAndKind() throws {
    let rateLimited = WalletSyncError(
      provider: .coinGecko, kind: .rateLimited(retryAfter: nil))
    let message = try #require(rateLimited.errorDescription)
    #expect(message.contains("CoinGecko"))

    let network = WalletSyncError(
      provider: nil, kind: .network(underlyingDescription: "HTTP 503"))
    let networkMessage = try #require(network.errorDescription)
    #expect(networkMessage.contains("HTTP 503"))
  }

  @Test("rateLimited renders a deterministic relative retry time via injected now")
  func rateLimitedRelativeTimeIsDeterministic() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let retryAfter = now.addingTimeInterval(3600)
    let error = WalletSyncError(
      provider: .coinGecko, kind: .rateLimited(retryAfter: retryAfter))
    let message = error.description(now: now)
    #expect(message.contains("CoinGecko"))
    #expect(message.contains("1 hr") || message.contains("1 hour"))
    #expect(!message.contains("WalletSyncError"))
  }
}
