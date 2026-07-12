import Foundation
import Testing

@testable import Moolah

@Suite("ActiveExport stage labels")
struct ActiveExportTests {
  @Test("known DataExporter steps map to user-facing labels")
  func testKnownStepLabels() {
    #expect(ActiveExport.stageLabel(for: "starting") == "Starting…")
    #expect(ActiveExport.stageLabel(for: "accounts") == "Fetching accounts…")
    #expect(ActiveExport.stageLabel(for: "categories") == "Fetching categories…")
    #expect(ActiveExport.stageLabel(for: "earmarks") == "Fetching earmarks…")
    #expect(ActiveExport.stageLabel(for: "transactions") == "Fetching transactions…")
    #expect(ActiveExport.stageLabel(for: "encoding") == "Encoding file…")
    #expect(ActiveExport.stageLabel(for: "writing") == "Writing file…")
  }

  @Test("unknown steps sentence-case the raw step so new stages aren't invisible")
  func testUnknownStepFallback() {
    #expect(ActiveExport.stageLabel(for: "uploadingToS3") == "UploadingToS3…")
    #expect(ActiveExport.stageLabel(for: "") == "Working…")
  }

  @Test("ActiveExport is Identifiable so SwiftUI .sheet(item:) can present it")
  func testIdentifiable() {
    let first = ActiveExport(profileLabel: "Test", stageLabel: "Starting…")
    let second = ActiveExport(profileLabel: "Test", stageLabel: "Starting…")
    // Two exports with the same content still have distinct ids — avoids the
    // .sheet(item:) "same identity → no refresh" trap for back-to-back exports.
    #expect(first.id != second.id)
  }
}
