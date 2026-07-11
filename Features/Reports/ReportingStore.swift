// ReportingStore coordinates one observable report state machine; splitting it would expose private loading invariants.
// swiftlint:disable file_length

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
  private(set) var capitalGainsHasUnavailableDataByOwner: [UUID: Bool] = [:]
  private(set) var ownerUnavailableCapitalGainsInstruments: [UUID: [Instrument]] = [:]
  private(set) var profitLossUnavailableInstruments: [Instrument] = []
  private(set) var profitLossByOwner: [UUID: [InstrumentProfitLoss]] = [:]
  private(set) var profitLossHasUnavailableDataByOwner: [UUID: Bool] = [:]
  private(set) var profitLossUnavailableInstrumentsByOwner: [UUID: [Instrument]] = [:]
  private(set) var taxReportHoldingsDate: Date?
  private(set) var taxIncomeExpenseSummaries: [TaxIncomeExpenseSummary] = []
  private(set) var taxIncomeExpenseDateInterval: Range<Date>?
  private(set) var taxIncomeExpenseError: Error?
  private(set) var taxOwnerNames: [UUID: String]
  private(set) var taxOwnerKinds: [UUID: TaxOwnerKind]
  private(set) var ownerDependentReportInvalidation: UInt64 = 0

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
  private let categoryRepository: CategoryRepository?
  private let userDefaults: UserDefaults
  private(set) var defaultTaxOwnerId: UUID
  private let logger = Logger(subsystem: "com.moolah.app", category: "ReportingStore")

  @ObservationIgnored private var categoryBalancesGeneration: UInt64 = 0
  @ObservationIgnored private var reportGeneration: UInt64 = 0
  @ObservationIgnored private var accountObservationTask: Task<Void, Never>?
  @ObservationIgnored private var categoryObservationTask: Task<Void, Never>?
  @ObservationIgnored private var taxOwnerObservationTask: Task<Void, Never>?
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
    categoryRepository: CategoryRepository? = nil,
    accountChanges: AsyncStream<[Account]>? = nil,
    categoryChanges: AsyncStream<[Category]>? = nil,
    defaultTaxOwnerId: UUID = UUID(),
    taxOwnerNames: [UUID: String] = [:],
    taxOwnerKinds: [UUID: TaxOwnerKind] = [:],
    userDefaults: UserDefaults = .moolahShared
  ) {
    self.analysisRepository = analysisRepository
    self.conversionService = conversionService
    self.profileCurrency = profileCurrency
    self.holdingsCostLedger = holdingsCostLedger
    self.taxOwnerRepository = taxOwnerRepository
    self.accountRepository = accountRepository
    self.categoryRepository = categoryRepository
    self.defaultTaxOwnerId = defaultTaxOwnerId
    self.taxOwnerNames = taxOwnerNames
    self.taxOwnerKinds = taxOwnerKinds
    self.userDefaults = userDefaults
    accountObservationTask = makeOwnerDependentObservationTask(accountChanges)
    categoryObservationTask = makeOwnerDependentObservationTask(categoryChanges)
    taxOwnerObservationTask = makeTaxOwnerObservationTask(taxOwnerRepository)
  }

  deinit {
    accountObservationTask?.cancel()
    categoryObservationTask?.cancel()
    taxOwnerObservationTask?.cancel()
  }

  func updateDefaultTaxOwnerId(_ id: UUID) {
    guard defaultTaxOwnerId != id else { return }
    defaultTaxOwnerId = id
    reportGeneration &+= 1
    ownerDependentReportInvalidation &+= 1
    clearCapitalGains()
    clearProfitLoss()
    clearTaxIncomeExpense()
    isLoading = false
  }

  func fetchTaxIncomeExpenseDetails(
    dateInterval: Range<Date>,
    ownerId: UUID?,
    type: TransactionType
  ) async throws -> [TaxIncomeExpenseDetailRow] {
    guard let analysisRepository else { return [] }
    return try await analysisRepository.fetchTaxIncomeExpenseDetails(
      dateInterval: dateInterval,
      targetInstrument: profileCurrency,
      defaultTaxOwnerId: defaultTaxOwnerId,
      ownerId: ownerId,
      type: type)
  }

  private func makeOwnerDependentObservationTask<T>(
    _ changes: AsyncStream<[T]>?
  ) -> Task<Void, Never>? {
    guard let changes else { return nil }
    return Task { [weak self] in
      var sawInitialEmission = false
      for await _ in changes {
        guard sawInitialEmission else {
          sawInitialEmission = true
          continue
        }
        self?.invalidateOwnerDependentReports()
      }
    }
  }

  private func makeTaxOwnerObservationTask(
    _ repository: TaxOwnerRepository?
  ) -> Task<Void, Never>? {
    guard let repository else { return nil }
    return Task { [weak self] in
      var sawInitialEmission = false
      for await owners in repository.observeAll() {
        self?.updateTaxOwners(owners)
        guard sawInitialEmission else {
          sawInitialEmission = true
          continue
        }
        self?.invalidateOwnerDependentReports()
      }
    }
  }

  private func updateTaxOwners(_ owners: [TaxOwner]) {
    taxOwnerNames = Dictionary(uniqueKeysWithValues: owners.map { ($0.id, $0.name) })
    taxOwnerKinds = Dictionary(uniqueKeysWithValues: owners.map { ($0.id, $0.kind) })
  }

  private func invalidateOwnerDependentReports() {
    reportGeneration &+= 1
    ownerDependentReportInvalidation &+= 1
    clearCapitalGains()
    clearProfitLoss()
    clearTaxIncomeExpense()
    isLoading = false
  }

  private func clearCapitalGains() {
    capitalGainsResult = nil
    capitalGainsSummary = nil
    capitalGainsHasUnavailableData = false
    capitalGainsUnavailableInstruments = []
    capitalGainsHasUnavailableDataByOwner = [:]
    ownerUnavailableCapitalGainsInstruments = [:]
  }

  private func clearProfitLoss() {
    profitLoss = []
    profitLossHasUnavailableData = false
    profitLossUnavailableInstruments = []
    profitLossByOwner = [:]
    profitLossHasUnavailableDataByOwner = [:]
    profitLossUnavailableInstrumentsByOwner = [:]
  }

  private func clearTaxIncomeExpense() {
    taxIncomeExpenseSummaries = []
    taxIncomeExpenseError = nil
    taxIncomeExpenseDateInterval = nil
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
      let resolver = try await taxOwnershipResolver()
      let ledger = try await profitLossLedger(
        asOfDate: asOfDate,
        ledgerBeforeDate: ledgerBeforeDate,
        taxOwnershipResolver: resolver,
        holdingsCostLedger: holdingsCostLedger)
      let result = try await ProfitLossCalculator.compute(
        ledger: ledger,
        profileCurrency: profileCurrency,
        conversionService: conversionService,
        asOfDate: asOfDate
      )
      let excludedInstrumentIds = Set(excludedInstruments.map(\.id))
      let visibleProfitLoss = result.rows.filter {
        !excludedInstrumentIds.contains($0.instrument.id)
      }
      let visibleProfitLossHasUnavailableData =
        !result.unavailableInstrumentIds.subtracting(excludedInstrumentIds).isEmpty
      let visibleProfitLossUnavailableInstruments = Self.sortedInstruments(
        result.unavailableInstruments.filter { !excludedInstrumentIds.contains($0.id) })
      guard
        let ownerBreakdown = try await profitLossOwnerBreakdown(
          ledger: ledger,
          asOfDate: asOfDate,
          excludedInstrumentIds: excludedInstrumentIds,
          generation: generation)
      else { return false }
      guard generation == reportGeneration, !Task.isCancelled else { return false }
      profitLoss = visibleProfitLoss
      profitLossHasUnavailableData = visibleProfitLossHasUnavailableData
      profitLossUnavailableInstruments = visibleProfitLossUnavailableInstruments
      profitLossByOwner = ownerBreakdown.rowsByOwner
      profitLossHasUnavailableDataByOwner = ownerBreakdown.unavailableByOwner
      profitLossUnavailableInstrumentsByOwner = ownerBreakdown.unavailableInstrumentsByOwner
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
    clearProfitLoss()
    clearTaxIncomeExpense()
    isLoading = true
    error = nil
    let dates = Self.taxReportLoadDates(financialYear: financialYear, today: today)
    taxReportHoldingsDate = dates.valuationDate
    guard
      await performTaxIncomeExpenseLoad(
        financialYear: financialYear,
        dates: dates,
        generation: generation)
    else {
      finishLoadingIfCurrentGeneration(generation)
      return
    }
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
  ) async -> Bool {
    guard let analysisRepository else { return true }
    guard
      let dateRange = Self.taxIncomeExpenseDateRange(
        financialYear: financialYear,
        dates: dates)
    else { return true }
    do {
      async let summariesLoad = analysisRepository.fetchTaxIncomeExpenseSummaries(
        dateInterval: dateRange,
        targetInstrument: profileCurrency,
        defaultTaxOwnerId: defaultTaxOwnerId)
      async let ownersLoad = fetchTaxOwnersForReport()
      let (summaries, owners) = try await (summariesLoad, ownersLoad)
      guard generation == reportGeneration, !Task.isCancelled else { return false }
      taxIncomeExpenseDateInterval = dateRange
      taxIncomeExpenseSummaries = summaries
      taxOwnerNames = Dictionary(uniqueKeysWithValues: owners.map { ($0.id, $0.name) })
      taxOwnerKinds = Dictionary(uniqueKeysWithValues: owners.map { ($0.id, $0.kind) })
      return true
    } catch is CancellationError {
      guard generation == reportGeneration else { return false }
      return false
    } catch {
      guard generation == reportGeneration else { return false }
      logger.error("Failed to load tax income/expense: \(error)")
      taxIncomeExpenseError = error
      return true
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

      let resolver = try await taxOwnershipResolver()
      let ledger = try await holdingsCostLedger.ledger(
        before: sellDateInterval.upperBound,
        taxOwnershipResolver: resolver)
      let result = CapitalGainsCalculator.compute(
        ledger: ledger, sellDateInterval: sellDateInterval)
      guard generation == reportGeneration, !Task.isCancelled else { return false }
      let excludedInstrumentIds = Set(excludedInstruments.map(\.id))
      let visibleResult = Self.capitalGainsResult(result, excluding: excludedInstrumentIds)
      let ownerAvailability = capitalGainsOwnerAvailability(
        ledger: ledger,
        sellDateInterval: sellDateInterval,
        excludedInstrumentIds: excludedInstrumentIds)
      capitalGainsResult = visibleResult
      capitalGainsHasUnavailableData = visibleResult.hasUnavailableData
      capitalGainsUnavailableInstruments = Self.sortedInstruments(
        visibleResult.unavailableInstruments)
      capitalGainsHasUnavailableDataByOwner = ownerAvailability.unavailableByOwner
      ownerUnavailableCapitalGainsInstruments =
        ownerAvailability.unavailableInstrumentsByOwner
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

  private func taxOwnershipResolver() async throws -> TaxOwnershipResolver {
    let accounts = try await accountRepository?.fetchAll() ?? []
    let categories = try await categoryRepository?.fetchAll() ?? []
    return TaxOwnershipResolver(
      profileDefaultOwnerId: defaultTaxOwnerId, accounts: accounts, categories: categories)
  }

  private func profitLossLedger(
    asOfDate: Date,
    ledgerBeforeDate: Date?,
    taxOwnershipResolver: TaxOwnershipResolver,
    holdingsCostLedger: HoldingsCostLedgerStore
  ) async throws -> HoldingsCostLedger {
    if let ledgerBeforeDate {
      try await holdingsCostLedger.ledger(
        before: ledgerBeforeDate,
        taxOwnershipResolver: taxOwnershipResolver)
    } else {
      try await holdingsCostLedger.ledger(
        through: asOfDate,
        taxOwnershipResolver: taxOwnershipResolver)
    }
  }

  private func profitLossOwnerBreakdown(
    ledger: HoldingsCostLedger,
    asOfDate: Date,
    excludedInstrumentIds: Set<String>,
    generation: UInt64
  ) async throws -> ProfitLossOwnerBreakdown? {
    var rowsByOwner: [UUID: [InstrumentProfitLoss]] = [:]
    var unavailableByOwner: [UUID: Bool] = [:]
    var unavailableInstrumentsByOwner: [UUID: [Instrument]] = [:]
    for ownerId in taxOwnerNames.keys {
      let ownerResult = try await ProfitLossCalculator.compute(
        ledger: ledger,
        profileCurrency: profileCurrency,
        conversionService: conversionService,
        asOfDate: asOfDate,
        ownerId: ownerId)
      guard generation == reportGeneration, !Task.isCancelled else { return nil }
      rowsByOwner[ownerId] = ownerResult.rows.filter {
        !excludedInstrumentIds.contains($0.instrument.id)
      }
      unavailableByOwner[ownerId] =
        !ownerResult.unavailableInstrumentIds.subtracting(excludedInstrumentIds).isEmpty
      unavailableInstrumentsByOwner[ownerId] = Self.sortedInstruments(
        ownerResult.unavailableInstruments.filter { !excludedInstrumentIds.contains($0.id) })
    }
    return ProfitLossOwnerBreakdown(
      rowsByOwner: rowsByOwner,
      unavailableByOwner: unavailableByOwner,
      unavailableInstrumentsByOwner: unavailableInstrumentsByOwner)
  }

  private func capitalGainsOwnerAvailability(
    ledger: HoldingsCostLedger,
    sellDateInterval: Range<Date>,
    excludedInstrumentIds: Set<String>
  ) -> CapitalGainsOwnerAvailability {
    var unavailableByOwner: [UUID: Bool] = [:]
    var unavailableInstrumentsByOwner: [UUID: [Instrument]] = [:]
    for ownerId in taxOwnerNames.keys {
      let ownerResult = CapitalGainsCalculator.compute(
        ledger: ledger, sellDateInterval: sellDateInterval, ownerId: ownerId)
      let visibleOwnerResult = Self.capitalGainsResult(
        ownerResult, excluding: excludedInstrumentIds)
      unavailableByOwner[ownerId] = visibleOwnerResult.hasUnavailableData
      unavailableInstrumentsByOwner[ownerId] = Self.sortedInstruments(
        visibleOwnerResult.unavailableInstruments)
    }
    return CapitalGainsOwnerAvailability(
      unavailableByOwner: unavailableByOwner,
      unavailableInstrumentsByOwner: unavailableInstrumentsByOwner)
  }
}

private struct ProfitLossOwnerBreakdown {
  let rowsByOwner: [UUID: [InstrumentProfitLoss]]
  let unavailableByOwner: [UUID: Bool]
  let unavailableInstrumentsByOwner: [UUID: [Instrument]]
}

private struct CapitalGainsOwnerAvailability {
  let unavailableByOwner: [UUID: Bool]
  let unavailableInstrumentsByOwner: [UUID: [Instrument]]
}
