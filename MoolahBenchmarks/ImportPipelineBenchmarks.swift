import Foundation
import GRDB
import XCTest

@testable import Moolah

/// Benchmarks for the CSV import pipeline per `plans/2026-04-18-csv-import-design.md`
/// § Benchmarks. Each test isolates one stage so regressions in parse vs dedup
/// vs rules vs end-to-end can be pinpointed by xctest output.
///
/// Fixtures are synthesised in-memory (no file I/O) so the benchmarks measure
/// Swift work rather than filesystem variance.
final class ImportPipelineBenchmarks: XCTestCase {

  nonisolated(unsafe) private static var _backend: CloudKitBackend?
  nonisolated(unsafe) private static var _database: DatabaseQueue?
  nonisolated(unsafe) private static var _accountId: UUID?

  override static func setUp() {
    super.setUp()
    let result = expecting("benchmark TestBackend.create failed") {
      try TestBackend.create()
    }
    let accountId = UUID()
    _backend = result.backend
    _database = result.database
    _accountId = accountId
    awaitSyncExpecting { @MainActor in
      _ = try await result.backend.accounts.create(
        Account(
          id: accountId, name: "Bench", type: .bank, instrument: .AUD,
          positions: [], position: 0, isHidden: false),
        openingBalance: nil)
      _ = try await result.backend.csvImportProfiles.create(
        CSVImportProfile(
          accountId: accountId,
          parserIdentifier: "generic-bank",
          headerSignature: ["date", "description", "debit", "credit", "balance"]))
    }
  }

  override static func tearDown() {
    _backend = nil
    _database = nil
    _accountId = nil
    super.tearDown()
  }

  private var backend: CloudKitBackend {
    guard let backend = Self._backend else {
      fatalError("setUp must initialise _backend before tests run")
    }
    return backend
  }
  private var accountId: UUID {
    guard let accountId = Self._accountId else {
      fatalError("setUp must initialise _accountId before tests run")
    }
    return accountId
  }

  private var metrics: [XCTMetric] { [XCTClockMetric(), XCTMemoryMetric()] }
  private var options: XCTMeasureOptions {
    let opts = XCTMeasureOptions()
    opts.iterationCount = 10
    return opts
  }

  // MARK: - Synthetic CSV

  /// A valid CBA-style CSV with `rowCount` data rows plus a header.
  private static func makeCBAData(rowCount: Int) -> Data {
    var lines: [String] = ["Date,Description,Debit,Credit,Balance"]
    lines.reserveCapacity(rowCount + 1)
    var balance = Decimal(1000)
    for i in 0..<rowCount {
      let amount = Decimal(-5) - Decimal(i % 7)
      balance += amount
      let day = (i % 28) + 1
      let dayStr = String(format: "%02d", day)
      let description = "MERCHANT \(i % 50) SYDNEY"
      let amountStr = "\(amount)"
      let balStr = "\(balance)"
      lines.append("\(dayStr)/04/2024,\(description),\(amountStr),,\(balStr)")
    }
    return Data(lines.joined(separator: "\n").utf8)
  }

  private static func makeExisting(count: Int, accountId: UUID) -> [Transaction] {
    var out: [Transaction] = []
    out.reserveCapacity(count)
    let sessionId = UUID()
    for i in 0..<count {
      let origin = ImportOrigin(
        rawDescription: "MERCHANT \(i % 50) SYDNEY",
        bankReference: "REF-\(i)",
        rawAmount: Decimal(-5),
        rawBalance: nil,
        importedAt: Date(),
        importSessionId: sessionId,
        sourceFilename: "bulk.csv",
        parserIdentifier: "generic-bank")
      out.append(
        Transaction(
          date: Date(timeIntervalSince1970: Double(i * 86_400)),
          legs: [
            TransactionLeg(
              accountId: accountId, instrument: .AUD,
              quantity: Decimal(-5), type: .expense,
              categoryId: nil, earmarkId: nil)
          ],
          importOrigin: .single(origin)))
    }
    return out
  }

  private static func makeCandidates(count: Int) -> [ParsedTransaction] {
    var out: [ParsedTransaction] = []
    out.reserveCapacity(count)
    for i in 0..<count {
      out.append(
        ParsedTransaction(
          date: Date(timeIntervalSince1970: Double(i * 86_400)),
          legs: [
            ParsedLeg(
              accountId: nil, instrument: .AUD,
              quantity: Decimal(-5), type: .expense,
              isInstrumentPlaceholder: true)
          ],
          rawRow: [],
          rawDescription: "MERCHANT \(i % 50) SYDNEY",
          rawAmount: Decimal(-5),
          rawBalance: Decimal(1000),
          bankReference: "REF-\(i)"))
    }
    return out
  }

  private static func makeRules(count: Int) -> [ImportRule] {
    var out: [ImportRule] = []
    for i in 0..<count {
      out.append(
        ImportRule(
          name: "rule-\(i)",
          position: i,
          matchMode: .any,
          conditions: [.descriptionContains(["MERCHANT \(i % 50)"])],
          actions: [.setPayee("Payee \(i % 50)"), .appendNote("note-\(i)")]))
    }
    return out
  }

  // MARK: - Stage benchmarks

  /// Parse 1 000 rows of generic-bank CSV (tokenize + parse, no I/O).
  func testImportPipelineParse1000Rows() {
    let data = Self.makeCBAData(rowCount: 1000)
    let parser = GenericBankCSVParser()
    measure(metrics: metrics, options: options) {
      let rows = (try? CSVTokenizer.parse(data)) ?? []
      _ = (try? parser.parse(rows: rows)) ?? []
    }
  }

  /// Dedup 1 000 candidates against 10 000 existing transactions.
  func testImportPipelineDedup1000Against10000Existing() {
    let accountId = self.accountId
    let candidates = Self.makeCandidates(count: 1_000)
    let existing = Self.makeExisting(count: 10_000, accountId: accountId)
    measure(metrics: metrics, options: options) {
      _ = CSVDeduplicator.filter(
        candidates, against: existing, accountId: accountId)
    }
  }

  /// Run 20 rules against 1 000 candidates.
  func testImportPipelineRules1000RowsWith20Rules() {
    let accountId = self.accountId
    let candidates = Self.makeCandidates(count: 1_000)
    let rules = Self.makeRules(count: 20)
    measure(metrics: metrics, options: options) {
      for candidate in candidates {
        _ = ImportRulesEngine.evaluate(
          candidate, routedAccountId: accountId, rules: rules)
      }
    }
  }

  /// End-to-end: 10 files × 1 000 rows each against a fresh TestBackend per
  /// iteration so numbers are comparable: accumulating transactions
  /// across iterations would inflate dedup cost.
  /// Measures tokenize + parse + profile match + dedup + rules + persist +
  /// the cleanup steps. One of the most realistic benchmarks.
  func testImportPipelineEndToEnd10Files1000RowsEach() throws {
    let data = Self.makeCBAData(rowCount: 1000)
    measure(metrics: metrics, options: options) {
      awaitSyncExpecting { @MainActor in
        // Fresh backend + staging per iteration — no state leaks between
        // runs so the reported time measures a clean 10-file ingest.
        let (backend, _) = try TestBackend.create()
        let accountId = UUID()
        _ = try await backend.accounts.create(
          Account(
            id: accountId, name: "Bench", type: .bank, instrument: .AUD,
            positions: [], position: 0, isHidden: false),
          openingBalance: nil)
        _ = try await backend.csvImportProfiles.create(
          CSVImportProfile(
            accountId: accountId,
            parserIdentifier: "generic-bank",
            headerSignature: ["date", "description", "debit", "credit", "balance"]))
        let dir = FileManager.default.temporaryDirectory
          .appendingPathComponent("bench-\(UUID().uuidString)")
        let staging = try ImportStagingStore(directory: dir)
        let importStore = ImportStore(
          backend: backend, staging: staging,
          transferDetection: TransferDetectionCoordinator(
            transactions: backend.transactions,
            suggestions: backend.transferSuggestions))
        for _ in 0..<10 {
          _ = await importStore.ingest(
            data: data,
            source: .pickedFile(
              url: URL(fileURLWithPath: "/tmp/bench.csv"),
              securityScoped: false))
        }
      }
    }
  }
}
