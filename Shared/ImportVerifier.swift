import Foundation
// import GRDB justification: ImportVerifier counts rows in the GRDB
// profile database to confirm that `CloudKitDataImporter` wrote every
// record from the export file. The verification has to read the live
// database (not a repository view) so it can catch mid-flight failures
// before the new profile is activated, and `DatabaseReader` is the
// minimal surface that exposes that read. `DATABASE_CODE_GUIDE.md`
// scopes `import GRDB` to `Backends/GRDB/`; this file is a peer to
// `PreviewBackend` and `ExportCoordinator` in `Shared/` — a thin glue
// layer that bridges the export pipeline to the persistence layer
// rather than feature business logic.
import GRDB

struct ImportEntityCounts: Sendable, Equatable {
  let accounts: Int
  let accountGroups: Int
  let categories: Int
  let earmarks: Int
  let transactions: Int
  let investmentValues: Int
}

struct ImportVerificationResult: Sendable {
  let countMatch: Bool
  let expectedCounts: ImportEntityCounts
  let actualCounts: ImportEntityCounts
}

/// Confirms that row counts in the GRDB profile database match the source
/// export file after `CloudKitDataImporter` completes. A count mismatch
/// indicates a partial import (e.g. mid-flight crash or constraint violation)
/// and prevents the coordinator from activating the new profile.
struct ImportVerifier {

  func verify(
    exported: ExportedData,
    database: any DatabaseReader
  ) async throws -> ImportVerificationResult {
    let actualCounts = try await database.read { database in
      try ImportEntityCounts(
        accounts: AccountRow.fetchCount(database),
        accountGroups: AccountGroupRow.fetchCount(database),
        categories: CategoryRow.fetchCount(database),
        earmarks: EarmarkRow.fetchCount(database),
        transactions: TransactionRow.fetchCount(database),
        investmentValues: InvestmentValueRow.fetchCount(database)
      )
    }

    let expectedInvestmentValueCount = exported.investmentValues.values.reduce(0) { $0 + $1.count }
    let expectedCounts = ImportEntityCounts(
      accounts: exported.accounts.count,
      accountGroups: exported.accountGroups.count,
      categories: exported.categories.count,
      earmarks: exported.earmarks.count,
      transactions: exported.transactions.count,
      investmentValues: expectedInvestmentValueCount
    )
    return ImportVerificationResult(
      countMatch: actualCounts == expectedCounts,
      expectedCounts: expectedCounts,
      actualCounts: actualCounts
    )
  }
}
