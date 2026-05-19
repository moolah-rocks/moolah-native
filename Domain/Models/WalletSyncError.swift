import Foundation

/// Structured outcome of a failed wallet/exchange/price sync. Stored in
/// `WalletSyncState.lastError` (a per-device, non-cross-device-synced
/// checkpoint) so the UI can format it without coupling the domain to
/// localised strings.
///
/// `provider` records which external provider produced the failure so the
/// caption can name it. It is `nil` when the failure is not attributable
/// to a single provider (e.g. account-data validation) or when decoding a
/// legacy row written before attribution existed.
struct WalletSyncError {
  /// The failure category — exactly the cases the bare enum carried
  /// before attribution was added.
  enum Kind {
    case missingApiKey
    case invalidApiKey
    case rateLimited(retryAfter: Date?)
    case network(underlyingDescription: String)
    case providerMalformedResponse(stage: String)
  }

  let provider: SyncProvider?
  let kind: Kind

  /// Returns a copy attributed to `provider`, but only if it is not
  /// already attributed — the innermost (closest-to-source) provider
  /// wins, so an outer boundary never relabels a deeper one's error.
  func attributed(to provider: SyncProvider) -> WalletSyncError {
    guard self.provider == nil else { return self }
    return WalletSyncError(provider: provider, kind: kind)
  }
}

// MARK: - Protocol conformances

extension WalletSyncError: Error {}
extension WalletSyncError: Sendable {}
extension WalletSyncError: Hashable {}

extension WalletSyncError.Kind: Codable {}
extension WalletSyncError.Kind: Sendable {}
extension WalletSyncError.Kind: Hashable {}

// MARK: - Call-site-preserving factories

// These keep every existing `throw WalletSyncError.network(…)` /
// `.missingApiKey` / etc. site compiling unchanged, producing an
// unattributed error that a leaf boundary later stamps.
extension WalletSyncError {
  static var missingApiKey: WalletSyncError {
    WalletSyncError(provider: nil, kind: .missingApiKey)
  }

  static var invalidApiKey: WalletSyncError {
    WalletSyncError(provider: nil, kind: .invalidApiKey)
  }

  static func rateLimited(retryAfter: Date?) -> WalletSyncError {
    WalletSyncError(provider: nil, kind: .rateLimited(retryAfter: retryAfter))
  }

  static func network(underlyingDescription: String) -> WalletSyncError {
    WalletSyncError(
      provider: nil, kind: .network(underlyingDescription: underlyingDescription))
  }

  static func providerMalformedResponse(stage: String) -> WalletSyncError {
    WalletSyncError(provider: nil, kind: .providerMalformedResponse(stage: stage))
  }
}

// MARK: - LocalizedError

// Account-NEUTRAL, provider-aware fallback message. The rich
// account-type-aware caption lives in
// `SyncedAccountHeaderLogic.errorCaption` (a synced-account header knows
// whether it is crypto or an exchange and says "API token" for an
// exchange). This conformance is the generic fallback for any *other*
// surface that renders `error.localizedDescription` — e.g.
// `AnalysisView`, whose conversion pipeline can surface a price-provider
// failure. It says "API key" (the generic term, accurate for the
// price-provider context this surface reports) rather than the NSError
// bridge string "Moolah.WalletSyncError error 1", which conveys no
// failure kind. The two surfaces are never shown together for the same
// error, so the deliberate "key" vs "token" wording split is not
// user-visible inconsistency.
extension WalletSyncError: LocalizedError {
  var errorDescription: String? { description(now: Date()) }

  /// `now`-injectable backing for `errorDescription` so the
  /// relative-time `.rateLimited(retryAfter:)` rendering is
  /// deterministically testable (the `LocalizedError.errorDescription`
  /// signature itself cannot take a parameter).
  func description(now: Date) -> String {
    let provider = provider?.displayName
    switch kind {
    case .missingApiKey:
      return provider.map { "Add a \($0) API key to enable sync." }
        ?? "An API key is required to fetch this data."
    case .invalidApiKey:
      return provider.map { "\($0) rejected the API key." }
        ?? "The API key was rejected."
    case .rateLimited(let retryAfter):
      let who = provider ?? "The data provider"
      guard let retryAfter else { return "\(who) is rate-limiting requests. Try again shortly." }
      let formatter = RelativeDateTimeFormatter()
      formatter.unitsStyle = .short
      let relative = formatter.localizedString(for: retryAfter, relativeTo: now)
      return "\(who) is rate-limiting requests. Try again \(relative)."
    case .network(let underlying):
      return provider.map { "\($0) network error: \(underlying)" }
        ?? "Network error: \(underlying)"
    case .providerMalformedResponse(let stage):
      let who = provider ?? "The data provider"
      return "\(who) returned a malformed response (\(stage))."
    }
  }
}

// MARK: - Codable with legacy-row migration

// Persisted shape (new): {"provider": "alchemy"|null, "kind": <Kind JSON>}.
// Legacy shape (pre-attribution): the bare enum encoding — a single-key
// object whose key is the case name, e.g. {"network":{...}} or
// {"missingApiKey":{}}. The decoder accepts both; the encoder only ever
// writes the new shape.
extension WalletSyncError: Codable {
  private enum CodingKeys: String, CodingKey { case provider, kind }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    if container.contains(.kind) {
      let provider = try container.decodeIfPresent(
        SyncProvider.self, forKey: .provider)
      let kind = try container.decode(Kind.self, forKey: .kind)
      self.init(provider: provider, kind: kind)
      return
    }
    let legacyKind = try Kind(from: decoder)
    self.init(provider: nil, kind: legacyKind)
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeIfPresent(provider, forKey: .provider)
    try container.encode(kind, forKey: .kind)
  }
}
