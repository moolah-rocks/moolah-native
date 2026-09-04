import Foundation
import Testing

@testable import Moolah

@Suite("ImportStore queue")
@MainActor
struct ImportStoreQueueTests {
  private func makeStore() throws -> (ImportStore, URL) {
    let (backend, _) = try TestBackend.create()
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("import-store-queue-\(UUID().uuidString)", isDirectory: true)
    let staging = try ImportStagingStore(directory: directory)
    return (
      ImportStore(
        backend: backend,
        staging: staging,
        transferDetection: TransferDetectionCoordinator(
          transactions: backend.transactions,
          suggestions: backend.transferSuggestions)),
      directory
    )
  }

  @Test("concurrent imports are admitted in FIFO order")
  func concurrentImportsRunFIFO() async throws {
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (gate, releaseFirst) = AsyncStream<Void>.makeStream()
    var events: [String] = []

    let first = Task {
      await store.enqueueImport {
        events.append("first started")
        var iterator = gate.makeAsyncIterator()
        _ = await iterator.next()
        events.append("first finished")
        return .failed(message: "first")
      }
    }
    await expectEventually("first operation to start") { events == ["first started"] }

    let second = Task {
      await store.enqueueImport {
        events.append("second started")
        return .failed(message: "second")
      }
    }
    await expectEventually("second import to enter the queue") {
      store.importQueueGeneration == 2
    }
    #expect(events == ["first started"])

    releaseFirst.yield()
    releaseFirst.finish()
    _ = await first.value
    _ = await second.value
    #expect(events == ["first started", "first finished", "second started"])
  }

  @Test("cancelling a queued import does not execute it")
  func cancelledQueuedImportDoesNotRun() async throws {
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (gate, releaseFirst) = AsyncStream<Void>.makeStream()
    var firstStarted = false
    var cancelledOperationRan = false

    let first = Task {
      await store.enqueueImport {
        firstStarted = true
        var iterator = gate.makeAsyncIterator()
        _ = await iterator.next()
        return .failed(message: "first")
      }
    }
    await expectEventually("first operation to start") { firstStarted }

    let queued = Task {
      await store.enqueueImport {
        cancelledOperationRan = true
        return .failed(message: "unexpected")
      }
    }
    await expectEventually("second import to enter the queue") {
      store.importQueueGeneration == 2
    }
    queued.cancel()
    releaseFirst.yield()
    releaseFirst.finish()

    _ = await first.value
    let result = await queued.value
    if case .cancelled = result {
      #expect(!cancelledOperationRan)
    } else {
      Issue.record("expected .cancelled; got \(result)")
    }
  }

  @Test("cancelling an admitted retry preserves a recoverable staged file")
  func cancelledAdmittedRetryCompletesReplacement() async throws {
    let (baseBackend, _) = try TestBackend.create()
    let accountId = UUID()
    _ = try await baseBackend.accounts.create(
      Account(
        id: accountId, name: "Cash", type: .bank, instrument: .AUD,
        positions: [], position: 0, isHidden: false),
      openingBalance: nil)
    _ = try await baseBackend.csvImportProfiles.create(
      CSVImportProfile(
        accountId: accountId,
        parserIdentifier: "generic-bank",
        headerSignature: ["date", "description", "debit", "credit", "balance"]))
    let gatedTransactions = GatedFetchAllTransactionRepository(
      wrapping: baseBackend.transactions)
    let backend = TransactionOverrideBackend(
      base: baseBackend, transactions: gatedTransactions)
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("import-store-retry-\(UUID().uuidString)", isDirectory: true)
    let staging = try ImportStagingStore(directory: directory)
    let store = ImportStore(
      backend: backend,
      staging: staging,
      transferDetection: TransferDetectionCoordinator(
        transactions: gatedTransactions,
        suggestions: backend.transferSuggestions))
    defer { try? FileManager.default.removeItem(at: directory) }
    let originalId = UUID()
    let original = FailedImportFile(
      id: originalId,
      originalFilename: "retry.csv",
      stagingPath: await staging.stagingPath(for: originalId),
      error: "Previous import failed.",
      parsedAt: Date())
    let validBytes = Data(
      "Date,Description,Debit,Credit,Balance\n02/04/2024,Coffee,5.50,,994.50\n".utf8)
    try await staging.stageFailed(original, data: validBytes)
    await store.reloadStagingLists()

    let retry = Task { await store.retryFailed(id: original.id) }
    await gatedTransactions.waitUntilFetchAllStarted()
    retry.cancel()
    await gatedTransactions.releaseFetchAll()
    let result = await retry.value

    if case .imported = result {
      let staged = try await store.staging.failedFiles()
      #expect(staged.isEmpty)
      let imported = try await baseBackend.transactions.fetchAll(filter: TransactionFilter())
      #expect(imported.count == 1)
    } else {
      Issue.record("expected successful admitted retry; got \(result)")
    }
  }
}

private struct TransactionOverrideBackend: BackendProvider, @unchecked Sendable {
  let base: any BackendProvider
  let transactions: any TransactionRepository

  var auth: any AuthProvider { base.auth }
  var accounts: any AccountRepository { base.accounts }
  var accountGroups: any AccountGroupRepository { base.accountGroups }
  var insightDismissals: any InsightDismissalRepository { base.insightDismissals }
  var insightDisplayHistory: any InsightDisplayHistoryRepository { base.insightDisplayHistory }
  var categories: any CategoryRepository { base.categories }
  var taxOwners: any TaxOwnerRepository { base.taxOwners }
  var transferSuggestions: any TransferSuggestionRepository { base.transferSuggestions }
  var earmarks: any EarmarkRepository { base.earmarks }
  var analysis: any AnalysisRepository { base.analysis }
  var insightDataSource: any InsightDataSource { base.insightDataSource }
  var conversionService: any InstrumentConversionService { base.conversionService }
  var csvImportProfiles: any CSVImportProfileRepository { base.csvImportProfiles }
  var importRules: any ImportRuleRepository { base.importRules }
  var walletSyncState: any WalletSyncStateRepository { base.walletSyncState }
  var walletSyncCheckpoints: any WalletSyncCheckpointRepository { base.walletSyncCheckpoints }
  var groupUIState: any GroupUIStateRepository { base.groupUIState }
  var instrumentChangeObserver: (any InstrumentChangeObserving)? {
    base.instrumentChangeObserver
  }
  var instrumentRegistry: (any InstrumentRegistryRepository)? { base.instrumentRegistry }
}
