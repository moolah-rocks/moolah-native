import Foundation

/// Builds a human-readable, leg-level CSV projection of filtered transactions.
/// Transaction fields repeat for each leg so transfers and custom split
/// transactions retain every leg's amount and labels.
enum TransactionCSVExportBuilder {
  static let headers = [
    "Date",
    "Payee",
    "Scheduled",
    "Account",
    "Amount",
    "Instrument",
    "Chain ID",
    "ERC20 Contract Address",
    "Transaction Type",
    "Category",
    "Earmark",
    "On-chain Counterparty",
    "On-chain Transaction ID",
    "Block Explorer Link",
    "Notes",
  ]

  @concurrent
  static func csv(
    for transactions: [Transaction],
    context: TransactionCSVExportContext
  ) async throws -> String {
    var lines = [row(headers)]
    for transaction in visibleTransactions(from: transactions, context: context) {
      try Task.checkCancellation()
      for leg in transaction.legs {
        lines.append(row(fields(for: leg, in: transaction, context: context)))
      }
    }
    return lines.joined(separator: "\n") + "\n"
  }
}

extension TransactionCSVExportBuilder {
  private static func visibleTransactions(
    from transactions: [Transaction],
    context: TransactionCSVExportContext
  ) -> [Transaction] {
    transactions.filter { transaction in
      let matchesSearch =
        context.searchText.isEmpty
        || (transaction.payee?.localizedCaseInsensitiveContains(context.searchText) ?? false)
      let isVisibleSpam =
        context.includesSpam || !transaction.isAllSpam(in: context.spamInstruments)
      return matchesSearch && isVisibleSpam
    }
  }

  private static func fields(
    for leg: TransactionLeg,
    in transaction: Transaction,
    context: TransactionCSVExportContext
  ) -> [String] {
    let account = leg.accountId.flatMap { context.accounts.by(id: $0) }
    let category = leg.categoryId.flatMap { context.categories.by(id: $0) }
    let earmark = leg.earmarkId.flatMap { context.earmarks.by(id: $0) }
    let onChainId = leg.externalId.flatMap(BlockExplorerLink.transactionHash) ?? ""
    let explorerURL = explorerURL(for: leg, account: account)?.absoluteString ?? ""
    let chainId = account?.chainId ?? leg.instrument.chainId
    return [
      dateString(for: transaction.date, timeZone: context.timeZone),
      transaction.payee ?? "",
      transaction.isScheduled ? "true" : "false",
      account?.name ?? "",
      NSDecimalNumber(decimal: leg.quantity).stringValue,
      leg.instrument.pickerLabel,
      chainId.map(String.init) ?? "",
      leg.instrument.contractAddress ?? "",
      leg.type.rawValue,
      category?.name ?? "",
      earmark?.name ?? "",
      leg.counterpartyAddress ?? "",
      onChainId,
      explorerURL,
      transaction.notes ?? "",
    ]
  }

  private static func explorerURL(for leg: TransactionLeg, account: Account?) -> URL? {
    guard let externalId = leg.externalId,
      let chainId = account?.chainId ?? leg.instrument.chainId
    else { return nil }
    return BlockExplorerLink.transactionURL(chainId: chainId, externalId: externalId)
  }

  private static func dateString(for date: Date, timeZone: TimeZone) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = Locale(identifier: "en_US_POSIX")
    calendar.timeZone = timeZone
    let components = calendar.dateComponents([.year, .month, .day], from: date)
    guard let year = components.year, let month = components.month, let day = components.day else {
      return ""
    }
    return String(
      format: "%04d-%02d-%02d",
      locale: Locale(identifier: "en_US_POSIX"),
      year,
      month,
      day)
  }

  private static func row(_ fields: [String]) -> String {
    fields.map(escaped).joined(separator: ",")
  }

  private static func escaped(_ field: String) -> String {
    guard
      field.contains(",") || field.contains("\"") || field.contains("\n")
        || field.contains("\r")
    else { return field }
    return "\"\(field.replacingOccurrences(of: "\"", with: "\"\""))\""
  }
}
