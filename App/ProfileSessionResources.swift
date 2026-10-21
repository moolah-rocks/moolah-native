import Foundation

/// External resources chosen at the session composition boundary. A nil catalogue directory
/// disables optional public catalogues; callers can supply isolated networking and credentials.
struct ProfileSessionResources: Sendable {
  let networking: NetworkingServices
  let catalogDirectory: URL?
  let coinGeckoAPIKey: @Sendable () -> String?
  let alchemyAPIKey: @Sendable () -> String?
  let removeObsoleteCredential: @Sendable () -> Void
  let rpcEndpoints: any CryptoRPCEndpointsStoring

  /// In-memory credentials and no public catalogues. All outbound HTTP fails before
  /// opening a socket; suitable for previews and isolated session fixtures.
  static var disconnected: Self {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [DisconnectedProfileURLProtocol.self]
    return Self(
      networking: NetworkingServices(session: URLSession(configuration: configuration)),
      catalogDirectory: nil,
      coinGeckoAPIKey: { nil },
      alchemyAPIKey: { nil },
      removeObsoleteCredential: {},
      rpcEndpoints: InMemoryCryptoRPCEndpointsStore())
  }

  func using(networking override: NetworkingServices?) -> Self {
    Self(
      networking: override ?? networking,
      catalogDirectory: catalogDirectory,
      coinGeckoAPIKey: coinGeckoAPIKey,
      alchemyAPIKey: alchemyAPIKey,
      removeObsoleteCredential: removeObsoleteCredential,
      rpcEndpoints: rpcEndpoints)
  }

  static var live: Self {
    Self(
      networking: NetworkingServices(),
      catalogDirectory: URL.moolahScopedApplicationSupport.appending(path: "InstrumentRegistry"),
      coinGeckoAPIKey: { ProfileSession.resolveCoinGeckoApiKey() },
      alchemyAPIKey: { ProfileSession.resolveAlchemyApiKey() },
      removeObsoleteCredential: {
        KeychainStore(
          service: KeychainServices.apiKeys,
          account: "cryptocompare",
          synchronizable: true
        ).clear()
      },
      rpcEndpoints: CryptoRPCEndpointsStore())
  }
}

private final class DisconnectedProfileURLProtocol: URLProtocol {
  override static func canInit(with request: URLRequest) -> Bool { true }
  override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
  }
  override func stopLoading() {}
}
