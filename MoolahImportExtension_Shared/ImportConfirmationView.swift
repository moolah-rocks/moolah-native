import ImportExtensionKit
import SwiftUI

struct ImportConfirmationView: View {
  let viewModel: ImportConfirmationViewModel
  let onCancel: () -> Void
  let onReviewLater: () -> Void
  let onOpenMoolah: () -> Void

  var body: some View {
    VStack(spacing: 16) {
      content
      HStack {
        cancelButton
        Spacer()
        Button("Review Later", action: onReviewLater)
          .buttonStyle(.bordered)
        Button("Open Moolah", action: onOpenMoolah)
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.borderedProminent)
      }
    }
    .padding(20)
    #if os(macOS)
      .frame(minWidth: 420, minHeight: 280)
    #endif
  }

  // `role: .cancel` is the platform default for Escape on iOS but on
  // the macOS action-extension host the routing is unreliable; pinning
  // the shortcut explicitly guarantees Escape dismisses the sheet.
  private var cancelButton: some View {
    #if os(macOS)
      Button("Cancel", role: .cancel, action: onCancel)
        .keyboardShortcut(.escape, modifiers: [])
    #else
      Button("Cancel", role: .cancel, action: onCancel)
    #endif
  }

  @ViewBuilder private var content: some View {
    switch viewModel.state {
    case let .success(rows, name):
      Group {
        Text("Found \(rows) transactions from \(name)").font(.headline)
        Text(
          "Open Moolah now to review and import, or save for later — Moolah will pick it up next time you open the app."
        )
        .font(.body).foregroundStyle(.secondary)
      }
      .accessibilityElement(children: .combine)
    case .emptyResult(let name):
      Group {
        Text("No transactions found").font(.headline)
        Text(
          "Couldn't find any transactions on this page. Make sure you're on \(name)'s account activity page and try again."
        )
        .font(.body).foregroundStyle(.secondary)
      }
      .accessibilityElement(children: .combine)
    case .schemaMismatch:
      Group {
        Text("Couldn't read this page").font(.headline)
        Text("Moolah didn't understand the data. Update Moolah and try again.")
          .font(.body).foregroundStyle(.secondary)
      }
      .accessibilityElement(children: .combine)
    case .writeFailed:
      Group {
        Text("Something went wrong saving the import").font(.headline)
        Text("Try again, or open Moolah and use the import menu directly.")
          .font(.body).foregroundStyle(.secondary)
      }
      .accessibilityElement(children: .combine)
    }
  }
}

#if DEBUG
  #Preview("success") {
    ImportConfirmationView(
      viewModel: ImportConfirmationViewModel(state: .success(rows: 12, displayName: "Chase")),
      onCancel: {},
      onReviewLater: {},
      onOpenMoolah: {})
  }

  #Preview("emptyResult") {
    ImportConfirmationView(
      viewModel: ImportConfirmationViewModel(state: .emptyResult(displayName: "Chase")),
      onCancel: {},
      onReviewLater: {},
      onOpenMoolah: {})
  }

  #Preview("schemaMismatch") {
    ImportConfirmationView(
      viewModel: ImportConfirmationViewModel(state: .schemaMismatch),
      onCancel: {},
      onReviewLater: {},
      onOpenMoolah: {})
  }

  #Preview("writeFailed") {
    ImportConfirmationView(
      viewModel: ImportConfirmationViewModel(state: .writeFailed),
      onCancel: {},
      onReviewLater: {},
      onOpenMoolah: {})
  }
#endif
