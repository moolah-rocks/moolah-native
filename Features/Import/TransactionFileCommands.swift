import SwiftUI

/// File-menu commands backed by actions published by the focused window.
struct TransactionFileCommands: Commands {
  @FocusedValue(\.importCSVAction) private var importCSVAction
  @FocusedValue(\.pasteCSVAction) private var pasteCSVAction
  @FocusedValue(\.exportTransactionsAction) private var exportTransactionsAction

  var body: some Commands {
    CommandGroup(replacing: .importExport) {
      Button("Import CSV\u{2026}") {
        importCSVAction?()
      }
      .disabled(importCSVAction == nil)

      Button("Paste CSV") {
        pasteCSVAction?()
      }
      .keyboardShortcut("v", modifiers: [.command, .shift, .option])
      .disabled(pasteCSVAction == nil)

      Button("Export Transactions\u{2026}") {
        exportTransactionsAction?()
      }
      .disabled(exportTransactionsAction == nil)
    }
  }
}
