import Foundation
import OSLog
import Observation

@Observable
@MainActor
final class ReportingStore {
  // Published state
  private(set) var profitLoss: [InstrumentProfitLoss] = []
  private(set) var capitalGainsResult: CapitalGainsResult?
  private(set) var capitalGainsSummary: CapitalGainsSummary?
  private(set) var isLoading = false
  private(set) var error: Error?

  /// Category balances for the Reports view, bucketed by transaction type.
  private(set) var incomeBalances: [UUID: InstrumentAmount] = [:]
  private(set) var expenseBalances: [UUID: InstrumentAmount] = [:]
  /// Total of income/expense legs with no category, `nil` when there are
  /// none of that type in range (the Reports view omits the row in that
  /// case rather than treating `nil` as zero).
  private(set) var incomeUncategorised: InstrumentAmount?
  private(set) var expenseUncategorised: InstrumentAmount?
  /// Mirrors `CategoryBalances.hasUnavailableData` (Rule 11) per column —
  /// true when a transient conversion failure caused some rows to be
  /// skipped, so the corresponding totals may be understated.
  private(set) var incomeHasUnavailableData = false
  private(set) var expenseHasUnavailableData = false
  private(set) var isLoadingCategoryBalances = false
  private(set) var categoryBalancesError: Error?

  private let transactionRepository: TransactionRepository
  private let analysisRepository: AnalysisRepository?
  private let conversionService: InstrumentConversionService
  private(set) var profileCurrency: Instrument
  private let userDefaults: UserDefaults
  private let logger = Logger(subsystem: "com.moolah.app", category: "ReportingStore")

  /// Monotonic counters guarding against a superseded load clobbering fresher
  /// published state (issue #1209 class) — same shape as
  /// `AccountStore.snapshotGeneration`. Each `load…` function bumps its
  /// counter *before* suspending and captures the post-bump value; every
  /// publish after an `await` checks the captured value still matches the
  /// live counter before writing, so a call superseded by a newer one
  /// (e.g. `ReportsView`'s `.task(id:)` racing the "Try Again" button) drops
  /// its stale result instead of publishing over the newer one.
  ///
  /// `loadCategoryBalances` gets its own counter (`categoryBalancesGeneration`)
  /// since it publishes an independent set of properties
  /// (`incomeBalances`/`expenseBalances`/…/`isLoadingCategoryBalances`).
  /// `loadProfitLoss` and `loadCapitalGains` share `reportGeneration` because
  /// they publish to the same `isLoading`/`error` pair — a call to either
  /// should be able to supersede the other.
  @ObservationIgnored private var categoryBalancesGeneration: UInt64 = 0
  @ObservationIgnored private var reportGeneration: UInt64 = 0

  /// `true` while the one-shot cross-chain identity migration has not yet
  /// completed. Capital-gains FIFO results are gated on this flag: lots for
  /// the same asset may still be split across retired + canonical ids, so any
  /// figure produced by `CostBasisEngine` would be wrong until migration
  /// finishes and all ids are rewritten to canonical.
  var isMigratingCrossChainIdentity: Bool {
    !UnifiedInstrumentIdentityMigration.isComplete(in: userDefaults)
  }

  init(
    transactionRepository: TransactionRepository,
    analysisRepository: AnalysisRepository? = nil,
    conversionService: InstrumentConversionService,
    profileCurrency: Instrument,
    userDefaults: UserDefaults = .moolahShared
  ) {
    self.transactionRepository = transactionRepository
    self.analysisRepository = analysisRepository
    self.conversionService = conversionService
    self.profileCurrency = profileCurrency
    self.userDefaults = userDefaults
  }

  /// Loads income + expense category balances for a date range. Results are
  /// published to `incomeBalances` / `expenseBalances` (plus
  /// `incomeUncategorised` / `expenseUncategorised` and the
  /// `*HasUnavailableData` flags); failures land on `categoryBalancesError`.
  func loadCategoryBalances(dateRange: ClosedRange<Date>) async {
    guard let analysisRepository else {
      logger.error("loadCategoryBalances called without analysisRepository")
      return
    }
    // Bump-then-capture: see the `categoryBalancesGeneration` doc comment.
    categoryBalancesGeneration &+= 1
    let generation = categoryBalancesGeneration
    isLoadingCategoryBalances = true
    categoryBalancesError = nil
    do {
      let result = try await analysisRepository.fetchCategoryBalancesByType(
        dateRange: dateRange,
        filters: TransactionFilter(),
        targetInstrument: profileCurrency
      )
      guard generation == categoryBalancesGeneration else { return }
      incomeBalances = result.income
      expenseBalances = result.expense
      incomeUncategorised = result.incomeUncategorised
      expenseUncategorised = result.expenseUncategorised
      incomeHasUnavailableData = result.incomeHasUnavailableData
      expenseHasUnavailableData = result.expenseHasUnavailableData
    } catch is CancellationError {
      // `ReportsView`'s `.task(id:)` is cancelled whenever the user
      // changes the date range or navigates away; the cancellation
      // propagates as `CancellationError` from the repository. Treat
      // it as a normal lifecycle event — surfacing it would render
      // "Swift.CancellationError error 1" in the view. A re-mount /
      // re-keyed `.task` issues its own load.
      guard generation == categoryBalancesGeneration else { return }
      isLoadingCategoryBalances = false
      return
    } catch {
      guard generation == categoryBalancesGeneration else { return }
      logger.error("Failed to load category balances: \(error)")
      categoryBalancesError = error
    }
    guard generation == categoryBalancesGeneration else { return }
    isLoadingCategoryBalances = false
  }

  func loadProfitLoss() async {
    // Bump-then-capture: see the `reportGeneration` doc comment.
    reportGeneration &+= 1
    let generation = reportGeneration
    isLoading = true
    error = nil
    do {
      let transactions = try await loadAllLegTransactions()
      let result = try await ProfitLossCalculator.compute(
        transactions: transactions,
        profileCurrency: profileCurrency,
        conversionService: conversionService,
        asOfDate: Date()
      )
      guard generation == reportGeneration else { return }
      profitLoss = result
    } catch is CancellationError {
      // View teardown / supersession — never surface; the next mount
      // issues its own load.
      guard generation == reportGeneration else { return }
      isLoading = false
      return
    } catch {
      guard generation == reportGeneration else { return }
      logger.error("Failed to load P&L: \(error)")
      self.error = error
    }
    guard generation == reportGeneration else { return }
    isLoading = false
  }

  /// Load capital gains for an Australian financial year (1 Jul to 30 Jun).
  ///
  /// Returns immediately (leaving `capitalGainsSummary`/`capitalGainsResult`
  /// nil) while `isMigratingCrossChainIdentity` is true: the FIFO engine keys
  /// lots by `instrument.id`, and lots for the same asset may still be split
  /// across retired + canonical ids until the migration completes.
  func loadCapitalGains(financialYear: Int) async {
    guard !isMigratingCrossChainIdentity else {
      logger.info(
        "loadCapitalGains: skipping — cross-chain identity migration not yet complete")
      return
    }
    // Bump-then-capture: see the `reportGeneration` doc comment.
    reportGeneration &+= 1
    let generation = reportGeneration
    isLoading = true
    error = nil
    do {
      let transactions = try await loadAllLegTransactions()

      // Australian FY: 1 July (year-1) to 30 June (year)
      let calendar = Calendar(identifier: .gregorian)
      guard
        let fyStart = calendar.date(
          from: DateComponents(year: financialYear - 1, month: 7, day: 1)),
        let fyEnd = calendar.date(
          from: DateComponents(year: financialYear, month: 6, day: 30))
      else {
        logger.error("Could not compute financial year \(financialYear) date range")
        guard generation == reportGeneration else { return }
        isLoading = false
        return
      }

      let result = try await CapitalGainsCalculator.computeWithConversion(
        transactions: transactions,
        profileCurrency: profileCurrency,
        conversionService: conversionService,
        sellDateRange: fyStart...fyEnd
      )
      guard generation == reportGeneration else { return }
      capitalGainsResult = result
      capitalGainsSummary = CapitalGainsSummary(
        shortTermGain: result.shortTermGain,
        longTermGain: result.longTermGain,
        totalGain: result.totalRealizedGain,
        eventCount: result.events.count
      )
    } catch is CancellationError {
      // View teardown / supersession — never surface; the next mount
      // issues its own load.
      guard generation == reportGeneration else { return }
      isLoading = false
      return
    } catch {
      guard generation == reportGeneration else { return }
      logger.error("Failed to load capital gains: \(error)")
      self.error = error
    }
    guard generation == reportGeneration else { return }
    isLoading = false
  }

  // MARK: - Private

  private func loadAllLegTransactions() async throws -> [LegTransaction] {
    let page = try await transactionRepository.fetch(
      filter: TransactionFilter(), page: 0, pageSize: Int.max
    )
    return page.transactions.map { transaction in
      LegTransaction(date: transaction.date, legs: transaction.legs)
    }
  }
}
