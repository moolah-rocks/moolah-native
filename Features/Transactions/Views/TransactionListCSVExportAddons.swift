import SwiftUI

struct TransactionListCSVExportAddons: ViewModifier {
  let context: TransactionCSVExportContext
  let exportStore: TransactionCSVExportStore

  func body(content: Content) -> some View {
    content
      .focusedSceneValue(
        \.exportTransactionsAction,
        exportStore.isExporting ? nil : exportAction
      )
      .toolbar { exportToolbarContent }
      .fileExporter(
        isPresented: presentedBinding,
        document: exportStore.document,
        contentType: .commaSeparatedText,
        defaultFilename: "moolah-transactions.csv"
      ) { result in exportStore.handleSaveResult(result) }
      .alert("Could not export transactions", isPresented: errorBinding) {
        Button("OK", role: .cancel) {}
      } message: {
        Text(exportStore.errorMessage ?? "Unknown export error")
      }
  }

  @ToolbarContentBuilder private var exportToolbarContent: some ToolbarContent {
    #if os(iOS)
      ToolbarItem {
        if exportStore.isExporting {
          ProgressView()
            .accessibilityLabel("Preparing transaction export")
        } else {
          Button(action: exportAction) {
            Label("Export Transactions", systemImage: "square.and.arrow.up")
          }
        }
      }
    #elseif os(macOS)
      if exportStore.isExporting {
        ToolbarItem {
          ProgressView()
            .controlSize(.small)
            .accessibilityLabel("Preparing transaction export")
        }
      }
    #endif
  }

  private var exportAction: () -> Void {
    { Task { await exportStore.export(context: context) } }
  }

  private var presentedBinding: Binding<Bool> {
    Binding(
      get: { exportStore.isPresented },
      set: { exportStore.setPresented($0) })
  }

  private var errorBinding: Binding<Bool> {
    Binding(
      get: { exportStore.errorMessage != nil },
      set: { isPresented in
        if !isPresented { exportStore.dismissError() }
      })
  }
}
