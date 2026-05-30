import Foundation
import Testing

@testable import ImportExtensionKit

@Suite("ImportConfirmationViewModel")
@MainActor
struct ImportConfirmationViewModelTests {

  private func samplePayload(rows: Int = 24, host: String = "chase.com") -> ImportPayload {
    ImportPayload(
      schemaVersion: 1, sourceHost: host, sourceURL: "https://\(host)/",
      capturedAt: Date(), accountHint: nil, currencyHint: nil,
      rows: (0..<rows).map {
        ImportPayloadRow(date: "2026-05-2\($0 % 10)", amount: "1", description: "r")
      })
  }

  @Test("success state shows row count and display name from registry")
  func successState() {
    let registry = PluginRegistry(manifests: [
      PluginManifest(host: "chase.com", pathPrefix: "/", jsResource: "x", displayName: "Chase")
    ])
    let viewModel = ImportConfirmationViewModel(payload: samplePayload(), registry: registry)
    #expect(viewModel.state == .success(rows: 24, displayName: "Chase"))
  }

  @Test("empty rows produces emptyResult state with displayName")
  func emptyState() {
    let registry = PluginRegistry(manifests: [
      PluginManifest(host: "chase.com", pathPrefix: "/", jsResource: "x", displayName: "Chase")
    ])
    let viewModel = ImportConfirmationViewModel(payload: samplePayload(rows: 0), registry: registry)
    #expect(viewModel.state == .emptyResult(displayName: "Chase"))
  }

  @Test("payload from unknown host falls back to displayName = host")
  func unknownHostFallback() {
    let registry = PluginRegistry(manifests: [])
    let viewModel = ImportConfirmationViewModel(
      payload: samplePayload(host: "x.com"), registry: registry)
    #expect(viewModel.state == .success(rows: 24, displayName: "x.com"))
  }

  @Test("update(state:) mutates state in place so observers re-render")
  func updateStateMutatesInPlace() {
    let registry = PluginRegistry(manifests: [])
    let viewModel = ImportConfirmationViewModel(
      payload: samplePayload(host: "x.com"), registry: registry)
    #expect(viewModel.state == .success(rows: 24, displayName: "x.com"))
    viewModel.update(state: .writeFailed)
    #expect(viewModel.state == .writeFailed)
  }
}
