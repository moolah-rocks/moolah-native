import SwiftUI

/// Groups the CSV-import-specific modifiers (create-rule sheet + drop
/// target) so the main `body` chain stays within the Swift type
/// checker's complexity budget on the long `.onReceive` / `.sheet`
/// chain.
struct TransactionListCSVImportAddons: ViewModifier {
  @Binding var createRuleFromTransaction: Transaction?
  let corpusProvider: () -> [String]
  let forcedAccountId: UUID?
  let ingestDroppedURLs: (_ urls: [URL], _ forcedAccountId: UUID) async -> Void

  func body(content: Content) -> some View {
    content
      .sheet(item: $createRuleFromTransaction) { transaction in
        CreateRuleFromTransactionSheet(
          transaction: transaction,
          corpus: corpusProvider())
      }
      .dropDestination(for: URL.self) { urls, _ in
        guard let accountId = forcedAccountId else { return false }
        Task { await ingestDroppedURLs(urls, accountId) }
        return !urls.isEmpty
      }
  }
}
