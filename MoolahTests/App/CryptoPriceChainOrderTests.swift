import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("CryptoPriceService chain order")
@MainActor
struct CryptoPriceChainOrderTests {
  private func makeNetworking() -> NetworkingServices {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubURLProtocol.self]
    return NetworkingServices(session: URLSession(configuration: config))
  }

  @Test("DefiLlamaClient is first in the crypto price chain")
  func defiLlamaIsFirst() async throws {
    let database = try DatabaseQueue()
    let service = ProfileSession.makeCryptoPriceService(
      coinGeckoApiKeyProvider: { nil },
      database: database,
      networking: makeNetworking(),
      defiLlamaSupportCache: nil,
      localResolver: nil)
    let firstProvider = await service.clients.first?.syncProvider
    #expect(firstProvider == .defiLlama)
  }
}
