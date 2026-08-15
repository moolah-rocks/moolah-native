@preconcurrency import CloudKit
import GRDB

extension ProfileDataSyncHandler {
  nonisolated static let syncTableByRecordType: [String: String] = [
    TaxOwnerRow.recordType: "tax_owner",
    CategoryRow.recordType: "category",
    AccountGroupRow.recordType: "account_group",
    InsightDismissalRow.recordType: "insight_dismissal",
    WalletSyncCheckpointRow.recordType: "wallet_sync_checkpoint",
    AccountRow.recordType: "account",
    EarmarkRow.recordType: "earmark",
    EarmarkBudgetItemRow.recordType: "earmark_budget_item",
    TransactionRow.recordType: "transaction",
    TransactionLegRow.recordType: "transaction_leg",
    CSVImportProfileRow.recordType: "csv_import_profile",
    ImportRuleRow.recordType: "import_rule",
    TransferSuggestionRow.recordType: "transfer_suggestion",
  ]

  nonisolated static func mutationTokens(
    recordType: String, ids: [UUID], in database: Database
  ) throws -> [UUID: String] {
    guard let table = Self.syncTableByRecordType[recordType], !ids.isEmpty else {
      return [:]
    }
    let request: SQLRequest<Row> = """
      SELECT id, local_mutation_token
      FROM \(identifier: table)
      WHERE id IN \(ids)
      """
    let rows = try request.fetchAll(database)
    return Dictionary(uniqueKeysWithValues: rows.map { ($0["id"], $0["local_mutation_token"]) })
  }

  nonisolated static func mutationToken(
    recordType: String, id: UUID, in database: Database
  ) throws -> String? {
    guard let table = syncTableByRecordType[recordType] else { return nil }
    let request: SQLRequest<String> = """
      SELECT local_mutation_token
      FROM \(identifier: table)
      WHERE id = \(id)
      """
    return try request.fetchOne(database)
  }

}
