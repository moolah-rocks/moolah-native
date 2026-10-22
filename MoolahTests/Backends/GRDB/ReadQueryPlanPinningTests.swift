import Foundation
import GRDB
import Testing

@testable import Moolah

struct ReadQueryPlanPinningTests {
  @Test
  func keysetTransactionPagesUseTheDateAndUUIDIndex() throws {
    let database = try PlanPinningTestHelpers.makeDatabase()
    let detail = try PlanPinningTestHelpers.planDetail(
      database,
      query: """
        SELECT id, date FROM "transaction"
        WHERE recur_period IS NULL AND date >= ? AND date < ?
          AND (date < ? OR (date = ? AND id > ?))
        ORDER BY date DESC, id ASC LIMIT ?
        """,
      arguments: [
        Date.distantPast, Date.distantFuture, Date.distantFuture, Date.distantFuture, UUID(), 101,
      ]
    )
    #expect(detail.contains("transaction_by_date_id"))
    #expect(!detail.contains("USE TEMP B-TREE"))
    #expect(!PlanPinningTestHelpers.planHasFullTableScanOf(detail, alias: "transaction"))
  }

  @Test
  func nativePositionsUseTheAccountLegIndex() throws {
    let database = try PlanPinningTestHelpers.makeDatabase()
    let detail = try PlanPinningTestHelpers.planDetail(
      database,
      query: """
        SELECT leg.account_id, leg.instrument_id, SUM(leg.quantity)
        FROM transaction_leg AS leg JOIN "transaction" AS txn ON txn.id = leg.transaction_id
        WHERE txn.recur_period IS NULL AND leg.account_id IN (?)
        GROUP BY leg.account_id, leg.instrument_id
        HAVING SUM(leg.quantity) <> 0
        ORDER BY leg.account_id, leg.instrument_id
        """,
      arguments: [UUID()]
    )
    #expect(detail.contains("leg_by_account"))
    #expect(!PlanPinningTestHelpers.planHasFullTableScanOf(detail, alias: "leg"))
    // Grouping heterogeneous instruments may use a temporary B-tree; the selective account
    // index bounds the contributing rows before that aggregation.
  }
}

extension ReadQueryPlanPinningTests {
  @Test
  func earmarkPositionsUseTheEarmarkLegIndex() throws {
    let database = try PlanPinningTestHelpers.makeDatabase()
    let detail = try PlanPinningTestHelpers.planDetail(
      database,
      query: """
        SELECT leg.earmark_id, leg.instrument_id, SUM(leg.quantity)
        FROM transaction_leg AS leg JOIN "transaction" AS txn ON txn.id = leg.transaction_id
        WHERE txn.recur_period IS NULL AND leg.earmark_id IN (?)
        GROUP BY leg.earmark_id, leg.instrument_id
        HAVING SUM(leg.quantity) <> 0
        ORDER BY leg.earmark_id, leg.instrument_id
        """,
      arguments: [UUID()]
    )
    #expect(
      detail.contains("leg_by_earmark") || detail.contains("leg_analysis_by_earmark_type"),
      "Expected a selective earmark index; actual plan: \(detail)"
    )
    #expect(!PlanPinningTestHelpers.planHasFullTableScanOf(detail, alias: "leg"))
    // As with account positions, instrument grouping may use a temporary B-tree after
    // the earmark index narrows the source rows.
  }
}

extension ReadQueryPlanPinningTests {
  @Test(arguments: ["account_id", "earmark_id", "transaction_id"])
  func boundedLegProbesUseSelectiveIndexes(column: String) throws {
    let database = try PlanPinningTestHelpers.makeDatabase()
    let source =
      column == "transaction_id"
      ? "SELECT 1 FROM transaction_leg AS leg WHERE leg.transaction_id IN (?) LIMIT 10001"
      : """
      SELECT 1 FROM transaction_leg AS leg
      JOIN "transaction" AS txn ON txn.id = leg.transaction_id
      WHERE txn.recur_period IS NULL AND leg.\(column) IN (?) LIMIT 10001
      """
    let detail = try PlanPinningTestHelpers.planDetail(
      database,
      query: "SELECT COUNT(*) FROM (\(source))",
      arguments: [UUID()]
    )
    #expect(detail.contains("SEARCH leg USING"), "\(detail)")
    #expect(!PlanPinningTestHelpers.planHasFullTableScanOf(detail, alias: "leg"))
    #expect(!detail.contains("USE TEMP B-TREE"))
  }

  @Test(arguments: ["account", "category", "earmark"])
  func identifierPagesUsePrimaryKeyIndexes(table: String) throws {
    let database = try PlanPinningTestHelpers.makeDatabase()
    let visibility = table == "account" ? "AND is_hidden = 0" : ""
    let detail = try PlanPinningTestHelpers.planDetail(
      database,
      query: "SELECT id FROM \(table) WHERE id > ? \(visibility) ORDER BY id ASC LIMIT 101",
      arguments: [UUID()]
    )
    #expect(detail.contains("SEARCH \(table) USING"), "\(detail)")
    #expect(!PlanPinningTestHelpers.planHasFullTableScanOf(detail, alias: table))
    #expect(!detail.contains("USE TEMP B-TREE"))
  }

  @Test(arguments: ["account", "category", "combined", "payee"])
  func filteredKeysetPagesRetainSelectivePlans(variant: String) throws {
    let database = try PlanPinningTestHelpers.makeDatabase()
    var filter = TransactionFilter()
    filter.dateInterval = Date.distantPast..<Date.distantFuture
    switch variant {
    case "account": filter.accountIds = [UUID()]
    case "category": filter.categoryIds = [UUID()]
    case "combined":
      filter.accountIds = [UUID()]
      filter.categoryIds = [UUID()]
    default: filter.payee = "Fixture"
    }
    let request = GRDBReadQueryRepository.transactionRequest(
      filter: filter,
      after: ReadPageKey(id: UUID(), date: Date.distantFuture)
    ).limit(101)
    let detail = try database.read { database in
      let statement = try request.makePreparedRequest(
        database,
        forSingleResult: false
      ).statement
      let sql: SQL = "EXPLAIN QUERY PLAN \(sql: statement.sql, arguments: statement.arguments)"
      return try SQLRequest<Row>(literal: sql).fetchAll(database)
        .compactMap { $0["detail"] as String? }.joined(separator: "; ")
    }
    #expect(
      !PlanPinningTestHelpers.planHasFullTableScanOf(
        detail,
        alias: "transaction"
      ),
      "\(detail)"
    )
    if variant == "payee" {
      #expect(detail.contains("transaction_by_date_id"), "\(detail)")
      #expect(!detail.contains("USE TEMP B-TREE"))
    } else {
      #expect(detail.contains("leg_by_account") || detail.contains("leg_by_category"), "\(detail)")
      #expect(!PlanPinningTestHelpers.planHasFullTableScanOf(detail, alias: "transaction_leg"))
      // An IN subquery selects parent IDs through the leg index, followed by indexed
      // parent lookups. SQLite may sort this selective parent set into date/UUID order.
    }
  }
}

extension ReadQueryPlanPinningTests {
  @Test
  func summaryFlowsSearchDateRangeBeforeTransactionLegs() throws {
    let database = try PlanPinningTestHelpers.makeDatabase()
    let detail = try PlanPinningTestHelpers.planDetail(
      database,
      query: GRDBReadQueryRepository.summaryFlowSQL,
      arguments: StatementArguments([
        "from": Date.distantPast, "through": Date.distantFuture, "maximum": 250_001,
      ])
    )
    let parent = try #require(detail.range(of: "SEARCH txn USING INDEX transaction_by_date"))
    let legs = try #require(detail.range(of: "SEARCH leg USING INDEX leg_by_transaction"))
    #expect(parent.lowerBound < legs.lowerBound)
    #expect(!PlanPinningTestHelpers.planHasFullTableScanOf(detail, alias: "txn"))
    #expect(!PlanPinningTestHelpers.planHasFullTableScanOf(detail, alias: "leg"))
    #expect(!detail.contains("USE TEMP B-TREE"))
  }
}

extension ReadQueryPlanPinningTests {
  @Test(arguments: ["validation", "filtered", "unfiltered"])
  func balanceAccountRequestsUsePrimaryKeySearch(variant: String) throws {
    let database = try PlanPinningTestHelpers.makeDatabase()
    let ids: Set<UUID> = [UUID(), UUID()]
    let detail = try database.read { database in
      let statement: Statement
      if variant == "validation" {
        statement = try GRDBReadQueryRepository.balanceAccountCountRequest(accountIDs: ids)
          .makePreparedRequest(database, forSingleResult: false).statement
      } else {
        statement = try GRDBReadQueryRepository.balanceAccountRequest(
          accountIDs: variant == "filtered" ? ids : [],
          after: ReadPageKey(id: UUID())
        ).limit(101).makePreparedRequest(database, forSingleResult: false).statement
      }
      let sql: SQL = "EXPLAIN QUERY PLAN \(sql: statement.sql, arguments: statement.arguments)"
      return try SQLRequest<Row>(literal: sql).fetchAll(database)
        .compactMap { $0["detail"] as String? }.joined(separator: "; ")
    }
    #expect(detail.contains("SEARCH account USING"), "\(detail)")
    #expect(!PlanPinningTestHelpers.planHasFullTableScanOf(detail, alias: "account"))
    #expect(!detail.contains("USE TEMP B-TREE"), "\(detail)")
  }
}

extension ReadQueryPlanPinningTests {
  @Test(arguments: [ReadPositionQuery.balances, .earmarks, .netWorth])
  func streamingPositionsSearchOwnersBeforeTransactions(query: ReadPositionQuery) throws {
    let queue = try PlanPinningTestHelpers.makeDatabase()
    let detail = try queue.read { database in
      let statement = try GRDBReadQueryRepository.positionRequest(ids: [UUID()], query: query)
        .makePreparedRequest(database, forSingleResult: false).statement
      let sql: SQL = "EXPLAIN QUERY PLAN \(sql: statement.sql, arguments: statement.arguments)"
      return try SQLRequest<Row>(literal: sql).fetchAll(database)
        .compactMap { $0["detail"] as String? }.joined(separator: "; ")
    }
    #expect(
      detail.contains("SEARCH leg USING INDEX")
        || detail.contains("SEARCH leg USING COVERING INDEX"),
      "\(detail)"
    )
    #expect(detail.contains("SEARCH txn USING INDEX"), "\(detail)")
    #expect(!PlanPinningTestHelpers.planHasFullTableScanOf(detail, alias: "leg"))
    #expect(!PlanPinningTestHelpers.planHasFullTableScanOf(detail, alias: "txn"))
    #expect(!detail.contains("USE TEMP B-TREE"))
  }
}
