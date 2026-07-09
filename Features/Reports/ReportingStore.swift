import Foundation
import OSLog
import Observation

@Observable
@MainActor
final class ReportingStore {
  private(set) var profitLoss: [InstrumentProfitLoss] = []
  private(set) var capitalGainsResult: CapitalGainsResult?
  private(set) var capitalGainsSummary: CapitalGainsSummary?
  private(set) var isLoading = false
  private(set) var error: Error?
  private(set) var capitalGainsHasUnavailableData = false
  private(set) var profitLossHasUnavailableData = false
  private(set) var capitalGainsUnavailableInstruments: [Instrument] = []
  private(set) var profitLossUnavailableInstruments: [Instrument] = []
  private(set) var taxReportHoldingsDate: Date?
  private(set) var taxIncomeExpenseSummaries: [TaxIncomeExpenseSummary] = []
  private(set) var taxIncomeExpenseDateInterval: Range<Date>?
  private(set) var taxIncomeExpenseError: Error?
  private(set) var taxOwnerNames: [UUID: String]

  private(set) var incomeBalances: [UUID: InstrumentAmount] = [:]
  private(set) var expenseBalances: [UUID: InstrumentAmount] = [:]
  private(set) var incomeUncategorised: InstrumentAmount?
  private(set) var expenseUncategorised: InstrumentAmount?
  private(set) var incomeHasUnavailableData = false
  private(set) var expenseHasUnavailableData = false
  private(set) var isLoadingCategoryBalances = false
  private(set) var categoryBalancesError: Error?

  private let analysisRepository: AnalysisRepository?
  private let conversionService: InstrumentConversionService
  private(set) var profileCurrency: Instrument
  private let holdingsCostLedger: HoldingsCostLedgerStore?
  private let taxOwnerRepository: TaxOwnerRepository?
  private let accountRepository: AccountRepository?
  private let userDefaults: UserDefaults
  private(set) var defaultTaxOwnerId: UUID
  private let logger = Logger(subsystem: "com.moolah.app", category: "ReportingStore")

  @ObservationIgnored private var categoryBalancesGeneration: UInt64 = 0
  @ObservationIgnored private var reportGeneration: UInt64 = 0
  @ObservationIgnored private var accountObservationTask: Task<Void, Never>?
  var isMigratingCrossChainIdentity: Bool {
    !UnifiedInstrumentIdentityMigration.isComplete(in: userDefaults)
  }
  var taxIncomeExpenseRollup: TaxIncomeExpenseSummary? {
    Self.taxIncomeExpenseRollup(from: taxIncomeExpenseSummaries, instrument: profileCurrency)
  }

  init(
    analysisRepository: AnalysisRepository? = nil,
    conversionService: InstrumentConversionService,
    profileCurrency: Instrument,
    holdingsCostLedger: HoldingsCostLedgerStore? = nil,
    taxOwnerRepository: TaxOwnerRepository? = nil,
    accountRepository: AccountRepository? = nil,
    accountChanges: AsyncStream<[Account]>? = nil,
    defaultTaxOwnerId: UUID = UUID(),
    taxOwnerNames: [UUID: String] = [:],
    userDefaults: UserDefaults = .moolahShared
  ) {
    self.analysisRepository = analysisRepository
    self.conversionService = conversionService
    self.profileCurrency = profileCurrency
    self.holdingsCostLedger = holdingsCostLedger
    self.taxOwnerRepository = taxOwnerRepository
    self.accountRepository = accountRepository
    self.defaultTaxOwnerId = defaultTaxOwnerId
    self.taxOwnerNames = taxOwnerNames
    self.userDefaults = userDefaults
    startAccountObservation(accountChanges)
  }

  deinit { accountObservationTask?.cancel() }

  func updateDefaultTaxOwnerId(_ id: UUID) {
    guard defaultTaxOwnerId != id else { return }
    defaultTaxOwnerId = id
    reportGeneration &+= 1
    clearCapitalGains()
    taxIncomeExpenseSummaries = []
    taxIncomeExpenseError = nil
    isLoading = false
  }

  private func startAccountObservation(_ accountChanges: AsyncStream<[Account]>?) {
    guard let accountChanges else { return }
    accountObservationTask = Task { [weak self] in
      var sawInitialEmission = false
      for await _ in accountChanges {
        guard sawInitialEmission else {
          sawInitialEmission = true
          continue
        }
        self?.invalidateOwnerDependentReports()
      }
    }
  }

  private func invalidateOwnerDependentReports() {
    reportGeneration &+= 1
    clearCapitalGains()
    isLoading = false
  }

  private func clearCapitalGains() {
    capitalGainsResult = nil
    capitalGainsSummary = nil
    capitalGainsHasUnavailableData = false
    capitalGainsUnavailableInstruments = []
  }

  func loadCategoryBalances(dateRange: ClosedRange<Date>) async {
    guard let analysisRepository else {
      logger.error("loadCategoryBalances called without analysisRepository")
      return
    }
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
      profitLossHasUnavailableData =
        !result.unavailableInstrumentIds.subtracting(excludedInstrumentIds).isEmpty
      profitLossUnavailableInstruments = Self.sortedInstruments(
        result.unavailableInstruments.filter { !excludedInstrumentIds.contains($0.id) })
      return true
    } catch is CancellationError {
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
    clearCapitalGains()
    profitLoss = []
    profitLossHasUnavailableData = false
    profitLossUnavailableInstruments = []
    taxIncomeExpenseSummaries = []
    taxIncomeExpenseError = nil
    taxIncomeExpenseDateInterval = nil
    isLoading = true
    error = nil
    let dates = Self.taxReportLoadDates(financialYear: financialYear, today: today)
    taxReportHoldingsDate = dates.valuationDate
    await performTaxIncomeExpenseLoad(
      financialYear: financialYear,
      dates: dates,
      generation: generation)
    guard generation == reportGeneration else { return }
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

  private func performTaxIncomeExpenseLoad(
    financialYear: Int,
    dates: TaxReportLoadDates,
    generation: UInt64
  ) async {
    guard let analysisRepository else { return }
    guard
      let dateRange = Self.taxIncomeExpenseDateRange(
        financialYear: financialYear,
        dates: dates)
    else { return }
    do {
      async let summariesLoad = analysisRepository.fetchTaxIncomeExpenseSummaries(
        dateInterval: dateRange,
        targetInstrument: profileCurrency,
        defaultTaxOwnerId: defaultTaxOwnerId)
      async let ownersLoad = fetchTaxOwnersForReport()
      let (summaries, owners) = try await (summariesLoad, ownersLoad)
      guard generation == reportGeneration else { return }
      taxIncomeExpenseDateInterval = dateRange
      taxIncomeExpenseSummaries = summaries
      taxOwnerNames = Dictionary(uniqueKeysWithValues: owners.map { ($0.id, $0.name) })
    } catch is CancellationError {
      return
    } catch {
      guard generation == reportGeneration else { return }
      logger.error("Failed to load tax income/expense: \(error)")
      taxIncomeExpenseError = error
    }
  }

  private func fetchTaxOwnersForReport() async throws -> [TaxOwner] {
    guard let taxOwnerRepository else { return [] }
    return try await taxOwnerRepository.fetchAll()
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
    reportGeneration &+= 1
    let generation = reportGeneration
    clearCapitalGains()
    guard !isMigratingCrossChainIdentity else {
      logger.info("loadCapitalGains: skipping — cross-chain identity migration not yet complete")
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
      logger.info("loadCapitalGains: skipping — cross-chain identity migration not yet complete")
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

      let accounts = try await accountRepository?.fetchAll() ?? []
      let resolver = TaxOwnershipResolver(
        profileDefaultOwnerId: defaultTaxOwnerId, accounts: accounts, categories: [])
      let ledger = try await holdingsCostLedger.ledger(
        before: sellDateInterval.upperBound,
        taxOwnershipResolver: resolver)
      let result = CapitalGainsCalculator.compute(
        ledger: ledger, sellDateInterval: sellDateInterval)
      guard generation == reportGeneration else { return false }
      let excludedInstrumentIds = Set(excludedInstruments.map(\.id))
      let visibleResult = Self.capitalGainsResult(result, excluding: excludedInstrumentIds)
      capitalGainsResult = visibleResult
      capitalGainsHasUnavailableData = visibleResult.hasUnavailableData
      capitalGainsUnavailableInstruments = Self.sortedInstruments(
        visibleResult.unavailableInstruments)
      capitalGainsSummary = Self.capitalGainsSummary(from: visibleResult.events)
      return true
    } catch is CancellationError {
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
