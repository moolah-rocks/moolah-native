import Foundation
import OSLog
import Observation

/// Coordinates complete-snapshot transaction exports independently of the
/// paginated list store and owns the exporter's presentation state.
@Observable
@MainActor
final class TransactionCSVExportStore {
  private let repository: any TransactionRepository
  private let logger = Logger(subsystem: "com.moolah.app", category: "TransactionCSVExportStore")

  private(set) var document = TransactionCSVDocument(csv: "")
  private(set) var isExporting = false
  private(set) var isPresented = false
  private(set) var errorMessage: String?

  init(repository: any TransactionRepository) {
    self.repository = repository
  }

  func export(context: TransactionCSVExportContext) async {
    guard !isExporting else { return }
    isExporting = true
    errorMessage = nil
    defer { isExporting = false }

    do {
      let transactions = try await repository.fetchAll(filter: context.filter)
      try Task.checkCancellation()
      let csv = try await TransactionCSVExportBuilder.csv(for: transactions, context: context)
      try Task.checkCancellation()
      document = TransactionCSVDocument(csv: csv)
      isPresented = true
    } catch is CancellationError {
      return
    } catch {
      logger.error("Transaction CSV export failed: \(error.localizedDescription, privacy: .public)")
      errorMessage = error.userMessage
    }
  }

  func setPresented(_ value: Bool) {
    isPresented = value
  }

  func dismissError() {
    errorMessage = nil
  }

  func handleSaveResult(_ result: Result<URL, any Error>) {
    guard case let .failure(error) = result, !Self.isCancellation(error) else { return }
    logger.error("Transaction CSV save failed: \(error.localizedDescription, privacy: .public)")
    errorMessage = "Moolah couldn’t save the CSV. Choose a different folder and try again."
  }

}

extension TransactionCSVExportStore {
  private static func isCancellation(_ error: any Error) -> Bool {
    if error is CancellationError { return true }
    let cocoaError = error as NSError
    return cocoaError.domain == NSCocoaErrorDomain && cocoaError.code == NSUserCancelledError
  }
}
