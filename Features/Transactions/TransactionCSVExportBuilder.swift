import Foundation

/// Builds a human-readable, leg-level CSV projection of filtered transactions.
/// Transaction fields repeat for each leg so transfers and custom split
/// transactions retain every leg's amount and labels.
enum TransactionCSVExportBuilder {
  private struct RowPlan: Sendable {
    let transaction: Transaction
    let leg: TransactionLeg
    let conversionIndex: Int?
  }

  @concurrent
  static func csv(
    for transactions: [Transaction],
    context: TransactionCSVExportContext,
    baseInstrument: Instrument,
    conversionService: any InstrumentConversionService
  ) async throws -> String {
    var plannedRows: [RowPlan] = []
    var requests: [BatchConversionRequest] = []
    for transaction in visibleTransactions(from: transactions, context: context) {
      try Task.checkCancellation()
      for leg in transaction.legs {
        let conversionIndex: Int?
        if leg.instrument == baseInstrument {
          conversionIndex = nil
        } else {
          conversionIndex = requests.count
          requests.append(
            BatchConversionRequest(
              amount: leg.amount,
              target: baseInstrument,
              date: transaction.date))
        }
        plannedRows.append(
          RowPlan(
            transaction: transaction,
            leg: leg,
            conversionIndex: conversionIndex))
      }
    }

    let outcomes = try await conversionService.convertResultBatch(requests)
    var lines = [row(headers(baseInstrument: baseInstrument))]
    for plannedRow in plannedRows {
      try Task.checkCancellation()
      let baseQuantity: Decimal
      if let conversionIndex = plannedRow.conversionIndex {
        switch outcomes[conversionIndex] {
        case .value(let amount): baseQuantity = amount.quantity
        case .knownZero: baseQuantity = 0
        case .failure(let error): throw error
        }
      } else {
        baseQuantity = plannedRow.leg.quantity
      }
      lines.append(
        row(
          fields(
            for: plannedRow.leg,
            in: plannedRow.transaction,
            baseQuantity: baseQuantity,
            context: context)))
    }
    return lines.joined(separator: "\n") + "\n"
  }
}

extension TransactionCSVExportBuilder {
  private static func headers(baseInstrument: Instrument) -> [String] {
    [
      "Date",
      "Payee",
      "Account",
      "Amount",
      "Instrument",
      "Base Currency Amount (\(baseInstrument.shortCode))",
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
  }

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
    baseQuantity: Decimal,
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
      account?.name ?? "",
      NSDecimalNumber(decimal: leg.quantity).stringValue,
      leg.instrument.pickerLabel,
      NSDecimalNumber(decimal: baseQuantity).stringValue,
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
