import Foundation
import Testing

@testable import ImportExtensionKit
@testable import Moolah

@Suite("DeepLinkCoordinator.handle")
@MainActor
struct DeepLinkCoordinatorTests {

  private func tempDirectory() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("deep-link-coord-\(UUID().uuidString)", isDirectory: true)
  }

  private func tempStagingDirectory() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("import-store-deep-\(UUID().uuidString)", isDirectory: true)
  }

  private func makeStore(
    backend: any BackendProvider, directory: URL
  ) throws -> ImportStore {
    let staging = try ImportStagingStore(directory: directory)
    return ImportStore(
      backend: backend, staging: staging,
      transferDetection: TransferDetectionCoordinator(
        transactions: backend.transactions,
        suggestions: backend.transferSuggestions))
  }

  private func makePayload(
    rows: [ImportPayloadRow] = [
      ImportPayloadRow(date: "2026-05-10", amount: "-12.34", description: "Coffee")
    ]
  ) -> ImportPayload {
    ImportPayload(
      schemaVersion: 1,
      sourceHost: "example.com",
      sourceURL: "https://example.com/",
      capturedAt: Date(timeIntervalSince1970: 1_717_000_000),
      accountHint: "1234",
      currencyHint: "AUD",
      rows: rows)
  }

  @Test("inbox payload is forwarded to ImportStore and the file is deleted")
  func drainsInboxIntoImportStore() async throws {
    let (backend, _) = try TestBackend.create()
    let stagingDir = tempStagingDirectory()
    defer { try? FileManager.default.removeItem(at: stagingDir) }
    let store = try makeStore(backend: backend, directory: stagingDir)

    let inboxRoot = tempDirectory()
    defer { try? FileManager.default.removeItem(at: inboxRoot) }
    let inbox = InboxWriter(rootDirectory: inboxRoot)
    let id = UUID()
    try inbox.write(makePayload(), id: id)

    let coordinator = DeepLinkCoordinator(
      importStoreProvider: { store },
      inboxProvider: { inbox })

    await coordinator.handle(.importInbox(id))

    // No active web profile → the payload should land in Needs Setup,
    // proving the payload was decoded and pushed all the way to
    // `ImportStore.startWebReview`.
    #expect(store.pendingSetup.count == 1)
    // The inbox file is removed once the payload has been claimed.
    #expect(try inbox.list().contains(id) == false)
    // The pending-destination latch is cleared once drained.
    #expect(coordinator.pendingDestination == nil)
  }

  @Test("no active session retains the pending destination and keeps the inbox file")
  func defersDrainWhenNoSession() async throws {
    let inboxRoot = tempDirectory()
    defer { try? FileManager.default.removeItem(at: inboxRoot) }
    let inbox = InboxWriter(rootDirectory: inboxRoot)
    let id = UUID()
    try inbox.write(makePayload(), id: id)

    let coordinator = DeepLinkCoordinator(
      importStoreProvider: { nil },
      inboxProvider: { inbox })

    await coordinator.handle(.importInbox(id))

    #expect(coordinator.pendingDestination == .importInbox(id))
    #expect(try inbox.list().contains(id))
  }
}
