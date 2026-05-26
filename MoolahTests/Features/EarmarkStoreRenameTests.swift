import Foundation
import Testing

@testable import Moolah

@Suite("EarmarkStore -- rename")
@MainActor
struct EarmarkStoreRenameTests {

  @Test("rename updates the earmark's name")
  func renameUpdatesName() async throws {
    let (backend, database) = try TestBackend.create()
    let original = Earmark(name: "Old", instrument: .defaultTestInstrument)
    TestBackend.seed(earmarks: [original], in: database)
    let store = EarmarkStore(
      repository: backend.earmarks, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)
    try await store.waitForNextEmission(
      matching: { $0.earmarks.by(id: original.id) != nil },
      description: "seeded earmark observed"
    )

    let result = await store.rename(id: original.id, to: "New")

    #expect(result?.name == "New")
    #expect(store.error == nil)
    try await store.waitForNextEmission(
      matching: { $0.earmarks.by(id: original.id)?.name == "New" },
      description: "rename observed"
    )
    let fetched = try await backend.earmarks.fetchAll()
    #expect(fetched.first(where: { $0.id == original.id })?.name == "New")
  }

  @Test("rename trims surrounding whitespace before persisting")
  func renameTrimsWhitespace() async throws {
    let (backend, database) = try TestBackend.create()
    let original = Earmark(name: "Old", instrument: .defaultTestInstrument)
    TestBackend.seed(earmarks: [original], in: database)
    let store = EarmarkStore(
      repository: backend.earmarks, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)
    try await store.waitForNextEmission(
      matching: { $0.earmarks.by(id: original.id) != nil },
      description: "seeded earmark observed"
    )

    let result = await store.rename(id: original.id, to: "  Spaced  ")

    #expect(result?.name == "Spaced")
    #expect(store.error == nil)
    try await store.waitForNextEmission(
      matching: { $0.earmarks.by(id: original.id)?.name == "Spaced" },
      description: "trimmed rename observed"
    )
    let fetched = try await backend.earmarks.fetchAll()
    #expect(fetched.first(where: { $0.id == original.id })?.name == "Spaced")
  }

  @Test("rename to empty / whitespace-only string is a no-op (returns current earmark unchanged)")
  func renameToEmptyIsNoOp() async throws {
    let (backend, database) = try TestBackend.create()
    let original = Earmark(name: "Stable", instrument: .defaultTestInstrument)
    TestBackend.seed(earmarks: [original], in: database)
    let store = EarmarkStore(
      repository: backend.earmarks, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)
    try await store.waitForNextEmission(
      matching: { $0.earmarks.by(id: original.id) != nil },
      description: "seeded earmark observed"
    )

    let result = await store.rename(id: original.id, to: "   ")

    #expect(result?.name == "Stable")
    #expect(store.earmarks.by(id: original.id)?.name == "Stable")
    #expect(store.error == nil)
    let fetched = try await backend.earmarks.fetchAll()
    #expect(fetched.first(where: { $0.id == original.id })?.name == "Stable")
  }

  @Test("rename to the same name is a no-op (no write, returns current)")
  func renameToSameNameIsNoOp() async throws {
    let (backend, database) = try TestBackend.create()
    let original = Earmark(name: "Stable", instrument: .defaultTestInstrument)
    TestBackend.seed(earmarks: [original], in: database)
    let store = EarmarkStore(
      repository: backend.earmarks, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)
    try await store.waitForNextEmission(
      matching: { $0.earmarks.by(id: original.id) != nil },
      description: "seeded earmark observed"
    )

    let result = await store.rename(id: original.id, to: "Stable")

    #expect(result?.name == "Stable")
    #expect(store.earmarks.by(id: original.id)?.name == "Stable")
    #expect(store.error == nil)
    let fetched = try await backend.earmarks.fetchAll()
    #expect(fetched.first(where: { $0.id == original.id })?.name == "Stable")
  }

  @Test("rename of unknown id returns nil without surfacing an error")
  func renameOfUnknownIdReturnsNil() async throws {
    let (backend, _) = try TestBackend.create()
    let store = EarmarkStore(
      repository: backend.earmarks, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)
    try await store.waitForFirstEmission()

    let result = await store.rename(id: UUID(), to: "Whatever")

    #expect(result == nil)
    #expect(store.error == nil)
  }
}
