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
        Button("Cancel", role: .cancel, action: onCancel)
        Spacer()
        Button("Review Later", action: onReviewLater)
        Button("Open Moolah", action: onOpenMoolah)
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.borderedProminent)
      }
    }
    .padding(20)
    .frame(minWidth: 360)
  }

  @ViewBuilder private var content: some View {
    switch viewModel.state {
    case let .success(rows, name):
      Text("Found \(rows) transactions from \(name)").font(.headline)
      Text(
        "Open Moolah now to review and import, or save for later — Moolah will pick it up next time you open the app."
      )
      .font(.body).foregroundStyle(.secondary)
    case .emptyResult(let name):
      Text("No transactions found").font(.headline)
      Text(
        "Couldn't find any transactions on this page. Make sure you're on \(name)'s account activity page and try again."
      )
      .font(.body).foregroundStyle(.secondary)
    case .schemaMismatch:
      Text("Couldn't read this page").font(.headline)
      Text("Moolah didn't understand the data. Update Moolah and try again.")
        .font(.body).foregroundStyle(.secondary)
    case .writeFailed:
      Text("Couldn't save the import").font(.headline)
      Text("Reinstall Moolah from the App Store.").font(.body).foregroundStyle(.secondary)
    }
  }
}
