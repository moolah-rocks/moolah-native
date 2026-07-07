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
  /// Rule 11 flags: `true` when a genuine conversion failure during the shared
  /// ledger build marked at least one instrument unavailable, so the
  /// corresponding figure may be understated. Exposes the store-level contract
  /// a future Reports/tax consumer must honour — render "unavailable" for the
  /// affected surface rather than a complete-looking but wrong number — the
  /// same treatment `incomeHasUnavailableData`/`expenseHasUnavailableData`
  /// already receive on the shipped category-balances surface. The Reports
  /// tax surface consumes these flags and renders the affected totals as
  /// unavailable. `profitLoss` still lists the sibling instruments that
  /// resolved.
  private(set) var capitalGainsHasUnavailableData = false
  private(set) var profitLossHasUnavailableData = false
  private(set) var capitalGainsUnavailableInstruments: [Instrument] = []
  private(set) var profitLossUnavailableInstruments: [Instrument] = []
  private(set) var taxReportHoldingsDate: Date?

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

  private let analysisRepository: AnalysisRepository?
  private let conversionService: InstrumentConversionService
  private(set) var profileCurrency: Instrument
  /// The shared profile-wide cost-basis provider. Source of the realised-CGT
  /// events and P&L rows: `loadCapitalGains` / `loadProfitLoss` read the
  /// ledger from here (built once per load, shared with the positions /
  /// performance passes) instead of rebuilding from a full transaction fetch.
  /// `nil` in previews / incidental test construction sites that never call
  /// the reports loads.
  private let holdingsCostLedger: HoldingsCostLedgerStore?
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
    analysisRepository: AnalysisRepository? = nil,
    conversionService: InstrumentConversionService,
    profileCurrency: Instrument,
    holdingsCostLedger: HoldingsCostLedgerStore? = nil,
    userDefaults: UserDefaults = .moolahShared
  ) {
    self.analysisRepository = analysisRepository
    self.conversionService = conversionService
    self.profileCurrency = profileCurrency
    self.holdingsCostLedger = holdingsCostLedger
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
        filters: TransactionFilter(excludesAccountlessUncategorised: true),
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
}

extension ReportingStore {
  func loadProfitLoss(
    asOfDate: Date = Date(),
    ledgerBeforeDate: Date? = nil,
    excluding excludedInstruments: Set<Instrument> = []
  ) async {
    // Bump-then-capture: see the `reportGeneration` doc comment.
    reportGeneration &+= 1
    let generation = reportGeneration
    isLoading = true
    error = nil
    profitLoss = []
    profitLossHasUnavailableData = false
    profitLossUnavailableInstruments = []
    _ = await performProfitLossLoad(
      asOfDate: asOfDate,
      ledgerBeforeDate: ledgerBeforeDate,
      excluding: excludedInstruments,
      generation: generation)
    guard generation == reportGeneration else { return }
    isLoading = false
  }

  private func performProfitLossLoad(
    asOfDate: Date,
    ledgerBeforeDate: Date?,
    excluding excludedInstruments: Set<Instrument>,
    generation: UInt64
  ) async -> Bool {
    guard let holdingsCostLedger else {
      logger.error("loadProfitLoss called without holdingsCostLedger")
      return true
    }
    do {
      // Source the profile-wide ledger from the shared provider so a genuine
      // build failure surfaces as unavailable data, never partial/zero P&L.
      let ledger =
        if let ledgerBeforeDate {
          try await holdingsCostLedger.ledger(before: ledgerBeforeDate)
        } else {
          try await holdingsCostLedger.ledger(through: asOfDate)
        }
      let result = try await ProfitLossCalculator.compute(
        ledger: ledger,
        profileCurrency: profileCurrency,
        conversionService: conversionService,
        asOfDate: asOfDate
      )
      guard generation == reportGeneration else { return false }
      let excludedInstrumentIds = Set(excludedInstruments.map(\.id))
      profitLoss = result.rows.filter { !excludedInstrumentIds.contains($0.instrument.id) }
      // Rule 11: an unavailable instrument's row is omitted; flag it so the
      // view marks the P&L surface unavailable rather than "no position."
      profitLossHasUnavailableData =
        !result.unavailableInstrumentIds.subtracting(excludedInstrumentIds).isEmpty
      profitLossUnavailableInstruments = Self.sortedInstruments(
        result.unavailableInstruments.filter { !excludedInstrumentIds.contains($0.id) })
      return true
    } catch is CancellationError {
      // View teardown / supersession — never surface; the next mount
      // issues its own load.
      guard generation == reportGeneration else { return false }
      return false
    } catch {
      guard generation == reportGeneration else { return false }
      logger.error("Failed to load P&L: \(error)")
      self.error = error
      return true
    }
  }

  func loadTaxReport(
    financialYear: Int,
    excluding excludedInstruments: Set<Instrument> = [],
    today: Date = Date()
  ) async {
    reportGeneration &+= 1
    let generation = reportGeneration
    capitalGainsResult = nil
    capitalGainsSummary = nil
    capitalGainsHasUnavailableData = false
    capitalGainsUnavailableInstruments = []
    profitLoss = []
    profitLossHasUnavailableData = false
    profitLossUnavailableInstruments = []
    isLoading = true
    error = nil
    let dates = taxReportLoadDates(financialYear: financialYear, today: today)
    taxReportHoldingsDate = dates.valuationDate
    guard
      await performCapitalGainsLoad(
        financialYear: financialYear,
        excluding: excludedInstruments,
        sellDateInterval: dates.sellDateInterval,
        generation: generation)
    else {
      finishLoadingIfCurrentGeneration(generation)
      return
    }
    guard generation == reportGeneration else { return }
    guard error == nil, !isMigratingCrossChainIdentity else {
      isLoading = false
      return
    }
    let priceDate =
      TaxReportPresentation.holdingsValuationDate(
        observationDate: dates.valuationDate)
    guard
      await performProfitLossLoad(
        asOfDate: priceDate,
        ledgerBeforeDate: dates.ledgerBeforeDate,
        excluding: excludedInstruments,
        generation: generation)
    else {
      finishLoadingIfCurrentGeneration(generation)
      return
    }
    guard generation == reportGeneration else { return }
    isLoading = false
  }

  private func taxReportLoadDates(financialYear: Int, today: Date) -> TaxReportLoadDates {
    let valuationDate = TaxReportPresentation.holdingsObservationDate(
      financialYear: financialYear,
      today: today)
    let ledgerBeforeDate = TaxReportPresentation.holdingsLedgerCutoffDate(
      financialYear: financialYear,
      observationDate: valuationDate)
    let sellDateInterval =
      TaxReportPresentation.financialYearInterval(financialYear).flatMap { financialYearInterval in
        ledgerBeforeDate.map { financialYearInterval.lowerBound..<$0 }
      }
    return TaxReportLoadDates(
      valuationDate: valuationDate,
      ledgerBeforeDate: ledgerBeforeDate,
      sellDateInterval: sellDateInterval)
  }

  private func finishLoadingIfCurrentGeneration(_ generation: UInt64) {
    guard generation == reportGeneration else { return }
    isLoading = false
  }

  func loadCapitalGains(
    financialYear: Int,
    excluding excludedInstruments: Set<Instrument> = [],
    sellDateInterval requestedSellDateInterval: Range<Date>? = nil
  ) async {
    // Bump-then-capture: see the `reportGeneration` doc comment.
    reportGeneration &+= 1
    let generation = reportGeneration
    capitalGainsResult = nil
    capitalGainsSummary = nil
    capitalGainsHasUnavailableData = false
    capitalGainsUnavailableInstruments = []
    guard !isMigratingCrossChainIdentity else {
      logger.info(
        "loadCapitalGains: skipping — cross-chain identity migration not yet complete")
      return
    }
    isLoading = true
    error = nil
    _ = await performCapitalGainsLoad(
      financialYear: financialYear,
      excluding: excludedInstruments,
      sellDateInterval: requestedSellDateInterval,
      generation: generation)
    guard generation == reportGeneration else { return }
    isLoading = false
  }

  private func performCapitalGainsLoad(
    financialYear: Int,
    excluding excludedInstruments: Set<Instrument>,
    sellDateInterval requestedSellDateInterval: Range<Date>?,
    generation: UInt64
  ) async -> Bool {
    guard !isMigratingCrossChainIdentity else {
      logger.info(
        "loadCapitalGains: skipping — cross-chain identity migration not yet complete")
      return true
    }
    guard let holdingsCostLedger else {
      logger.error("loadCapitalGains called without holdingsCostLedger")
      return true
    }
    do {
      guard
        let financialYearInterval = TaxReportPresentation.financialYearInterval(financialYear)
      else {
        logger.error("Could not compute financial year \(financialYear) date range")
        guard generation == reportGeneration else { return false }
        return true
      }
      let sellDateInterval = requestedSellDateInterval ?? financialYearInterval

      // A genuine ledger build failure throws and is surfaced as `error`,
      // never a partial realised set.
      let ledger = try await holdingsCostLedger.ledger(before: sellDateInterval.upperBound)
      let result = CapitalGainsCalculator.compute(
        ledger: ledger, sellDateInterval: sellDateInterval)
      guard generation == reportGeneration else { return false }
      let excludedInstrumentIds = Set(excludedInstruments.map(\.id))
      let visibleResult = Self.capitalGainsResult(result, excluding: excludedInstrumentIds)
      capitalGainsResult = visibleResult
      // Rule 11: a conversion failure may have dropped a disposal, so the
      // realised total may be understated — flag it (a tax figure must never
      // render complete-but-wrong).
      capitalGainsHasUnavailableData = visibleResult.hasUnavailableData
      capitalGainsUnavailableInstruments = Self.sortedInstruments(
        visibleResult.unavailableInstruments)
      capitalGainsSummary = Self.capitalGainsSummary(from: visibleResult.events)
      return true
    } catch is CancellationError {
      // View teardown / supersession — never surface; the next mount
      // issues its own load.
      guard generation == reportGeneration else { return false }
      return false
    } catch {
      guard generation == reportGeneration else { return false }
      logger.error("Failed to load capital gains: \(error)")
      self.error = error
      return true
    }
  }

}
