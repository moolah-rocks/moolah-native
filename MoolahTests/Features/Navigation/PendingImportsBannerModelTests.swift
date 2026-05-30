import Foundation
import Testing

@testable import ImportExtensionKit
@testable import Moolah

@Suite("PendingImportsBannerModel")
@MainActor
struct PendingImportsBannerModelTests {

  private func makeTempInbox() -> (URL, InboxWriter) {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("banner-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return (dir, InboxWriter(rootDirectory: dir))
  }

  private func samplePayload(host: String = "chase.com") -> ImportPayload {
    ImportPayload(
      schemaVersion: 1, sourceHost: host, sourceURL: "https://\(host)/",
      capturedAt: Date(), accountHint: nil, currencyHint: nil, rows: [])
  }

  @Test("no pending files → state is .none")
  func emptyInbox() async throws {
    let (dir, _) = makeTempInbox()
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = PendingImportsBannerModel(writer: InboxWriter(rootDirectory: dir))
    await model.refresh()
    #expect(model.state == .none)
  }

  @Test("one pending file → state is .one(host)")
  func onePending() async throws {
    let (dir, writer) = makeTempInbox()
    defer { try? FileManager.default.removeItem(at: dir) }
    try writer.write(samplePayload(host: "chase.com"), id: UUID())
    let model = PendingImportsBannerModel(writer: writer)
    await model.refresh()
    #expect(model.state == .one(host: "chase.com"))
  }

  @Test("multiple pending files → state is .many(count)")
  func manyPending() async throws {
    let (dir, writer) = makeTempInbox()
    defer { try? FileManager.default.removeItem(at: dir) }
    try writer.write(samplePayload(), id: UUID())
    try writer.write(samplePayload(), id: UUID())
    try writer.write(samplePayload(), id: UUID())
    let model = PendingImportsBannerModel(writer: writer)
    await model.refresh()
    #expect(model.state == .many(count: 3))
  }

  @Test("review(id:) returns the newest id and forwards to the deep-link sink")
  func reviewForwardsNewest() async throws {
    let (dir, writer) = makeTempInbox()
    defer { try? FileManager.default.removeItem(at: dir) }
    let older = UUID()
    let newer = UUID()
    try writer.write(samplePayload(), id: older)
    try await Task.sleep(for: .milliseconds(50))
    try writer.write(samplePayload(), id: newer)
    var routed: DeepLinkDestination?
    let model = PendingImportsBannerModel(writer: writer, onTap: { routed = $0 })
    await model.refresh()
    model.reviewTapped()
    #expect(routed == .importInbox(newer))
  }
}
