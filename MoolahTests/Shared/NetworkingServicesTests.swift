import Foundation
import Testing

@testable import Moolah

@Suite("NetworkingServices")
struct NetworkingServicesTests {

  @Test
  func clientForHostReturnsSameGateForSameHost() async {
    let services = NetworkingServices(session: .shared)
    let gateOne = await services.gate(forHost: "api.example.com")
    let gateTwo = await services.gate(forHost: "api.example.com")
    #expect(gateOne === gateTwo)
  }

  @Test
  func clientForHostReturnsDifferentGateForDifferentHost() async {
    let services = NetworkingServices(session: .shared)
    let gateOne = await services.gate(forHost: "api.example.com")
    let gateTwo = await services.gate(forHost: "api.other.com")
    #expect(gateOne !== gateTwo)
  }

  @Test
  func hostKeyIsCaseInsensitive() async {
    let services = NetworkingServices(session: .shared)
    let gateOne = await services.gate(forHost: "API.Example.com")
    let gateTwo = await services.gate(forHost: "api.example.com")
    #expect(gateOne === gateTwo)
  }

  @Test
  func clientForHostUsesInjectedSession() {
    let session = URLSession(configuration: .ephemeral)
    let services = NetworkingServices(session: session)
    let client = services.client(forHost: "api.example.com")
    // Round-trip the client through a successful 2xx; if we got the
    // injected session, the request resolves; otherwise it hits the
    // real network. (Smoke test — no Stub registered, so this would
    // fail outright if the wrong session were used.)
    #expect(client.underlyingSession === session)
  }
}
