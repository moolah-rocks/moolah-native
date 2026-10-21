import Foundation
import Testing

@testable import Moolah

struct ReadQueryRevisionTests {
  @Test
  func registryMetadataChangesExpirePagesWithoutAProfileWrite() async throws {
    let (_, database) = try TestBackend.create()
    let original = Instrument.stock(ticker: "ABC", exchange: "TEST", name: "Fixture")
    let resolver = MutableReadInstrumentMap(instruments: [original.id: original])
    let repository = GRDBReadQueryRepository(
      database: database,
      instrumentResolver: resolver,
      defaultInstrument: .AUD)
    let first = try await repository.accounts(includeHidden: false, page: ReadPageRequest())
    let updated = Instrument.stock(ticker: "ABC", exchange: "TEST", name: "Fixture", decimals: 4)
    await resolver.replace(with: [updated.id: updated])
    await #expect(throws: ReadQueryError.cursorExpired) {
      try await repository.accounts(
        includeHidden: false,
        page: ReadPageRequest(revision: first.revision))
    }
  }

  @Test
  func updatedProfileDefaultExpiresPagesOnTheSameQueue() async throws {
    let (backend, _) = try TestBackend.create()
    let original = try #require(backend.readQueries).using(defaultInstrument: .AUD)
    let first = try await original.earmarks(page: ReadPageRequest())
    let updated = original.using(defaultInstrument: .USD)
    await #expect(throws: ReadQueryError.cursorExpired) {
      try await updated.earmarks(page: ReadPageRequest(revision: first.revision))
    }
  }
}

private actor MutableReadInstrumentMap: InstrumentMapResolving {
  var instruments: [String: Instrument]

  init(instruments: [String: Instrument]) { self.instruments = instruments }
  func replace(with instruments: [String: Instrument]) { self.instruments = instruments }
  func instrumentMap() async throws -> [String: Instrument] { instruments }
}
