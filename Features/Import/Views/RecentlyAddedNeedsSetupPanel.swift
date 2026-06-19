import SwiftUI

// Needs Setup / Failed Files panel for the Recently Added screen, with its
// two row types. These types are file-visible to this feature and
// referenced only from `RecentlyAddedView`.

/// Needs Setup / Failed Files panel. Shown above the session list when either
/// list is non-empty; fully hidden when both are empty.
struct RecentlyAddedNeedsSetupPanel: View {
  let backend: any BackendProvider
  let staging: ImportStagingStore
  @Environment(ImportStore.self) private var importStore

  var body: some View {
    if importStore.pendingSetup.isEmpty && importStore.failedFiles.isEmpty {
      EmptyView()
    } else {
      VStack(alignment: .leading, spacing: 8) {
        if !importStore.pendingSetup.isEmpty {
          Text("Needs Setup").font(.headline)
          ForEach(importStore.pendingSetup) { file in
            RecentlyAddedPendingRow(file: file, backend: backend, staging: staging)
          }
        }
        if !importStore.failedFiles.isEmpty {
          Text("Failed Files").font(.headline)
          ForEach(importStore.failedFiles) { file in
            RecentlyAddedFailedRow(file: file)
          }
        }
      }
      .padding()
      .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
      .padding(.horizontal)
      .padding(.top)
    }
  }
}

struct RecentlyAddedPendingRow: View {
  let file: PendingSetupFile
  let backend: any BackendProvider
  let staging: ImportStagingStore
  @Environment(ImportStore.self) private var importStore
  @State private var setupStore: CSVImportSetupStore?

  var body: some View {
    HStack {
      Image(systemName: "doc.badge.ellipsis")
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      VStack(alignment: .leading) {
        Text(file.originalFilename).font(.subheadline)
        Text(file.detectedParserIdentifier ?? "Unknown parser")
          .font(.caption).foregroundStyle(.secondary)
      }
      .accessibilityElement(children: .combine)
      .accessibilityLabel("\(file.originalFilename), needs setup")
      Spacer()
      Button("Set up\u{2026}") {
        // Build the store lazily on first open so re-renders of the parent
        // don't wipe user-entered form state. Held in @State for stability
        // across sheet dismiss/show cycles.
        setupStore = CSVImportSetupStore(
          pending: file,
          backend: backend,
          importStore: importStore,
          staging: staging)
      }
      .buttonStyle(.borderless)
      Button("Dismiss") {
        Task { await importStore.dismissPending(id: file.id) }
      }
      .buttonStyle(.borderless)
    }
    .sheet(
      isPresented: Binding(
        get: { setupStore != nil },
        set: { if !$0 { setupStore = nil } })
    ) {
      if let setupStore {
        CSVImportSetupView(store: setupStore)
      }
    }
  }
}

struct RecentlyAddedFailedRow: View {
  let file: FailedImportFile
  @Environment(ImportStore.self) private var importStore

  var body: some View {
    HStack {
      Image(systemName: "exclamationmark.triangle")
        .foregroundStyle(.red)
        .accessibilityHidden(true)
      VStack(alignment: .leading) {
        Text(file.originalFilename).font(.subheadline)
        Text(file.error)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
      .accessibilityElement(children: .combine)
      .accessibilityLabel("\(file.originalFilename) failed: \(file.error)")
      Spacer()
      // Always available — we re-read the staged bytes, not the
      // original URL, so retries work even for paste/folder-watch files
      // whose source URLs are gone.
      Button("Retry") {
        Task { await importStore.retryFailed(id: file.id) }
      }
      .buttonStyle(.borderless)
      Button("Dismiss") {
        Task { await importStore.dismissFailed(id: file.id) }
      }
      .buttonStyle(.borderless)
    }
  }
}
