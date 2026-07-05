import SwiftUI
import os

/// Wraps any content (typically a `TransactionListView`) in the
/// `PositionsChartTransactionsSplit` unified account-detail container.
/// Chart and Transactions are **always** present; the Positions pane
/// is gated on `hasPositions` (non-host-currency holdings). Owns the
/// positions valuator `.task(id:)` lifecycle so callers don't manage it.
///
/// **Positions gate** — `hasPositions` delegates to
/// `AccountDetailLayout.hasNonHostHoldings`. Once the valuator
/// produces a `positionsInput` it is authoritative — its `shouldHide`
/// has already dropped `.knownZero` (`.spam` / `.unpriced`) rows, so
/// it agrees with what the table will render. Pre-valuation, the raw
/// heuristic acts as a stand-in so the tab / pane can render with a
/// `ProgressView` while the valuator works.
///
/// **Re-fire trigger** — the `.task(id:)` re-fires whenever the
/// positions list changes OR the crypto-registry version bumps (e.g.
/// the user marks a token as `.spam`). Without the version dimension
/// a spam flip in preferences would leave stale content on screen —
/// see issue #790 for the original rationale.
struct MultiInstrumentPositionsSplitModifier: ViewModifier {
  let positions: [Position]
  let hostCurrency: Instrument
  let title: String
  let conversionService: (any InstrumentConversionService)?
  let registrationsVersion: Int
  let accountIds: [UUID]
  /// The owning account's `Account.chainId`, forwarded to the valuator so the
  /// built `ValuedPosition`s carry chain context. Only meaningful for a single
  /// chain-scoped (crypto) account host; guarded to `accountIds.count == 1`
  /// before it reaches the valuator so multi-account group hosts never stamp a
  /// misleading chain.
  let accountChainId: Int?

  @Environment(ProfileSession.self) private var session: ProfileSession?

  @State private var positionsInput: PositionsViewInput?
  @State private var positionsRange: PositionsTimeRange = .threeMonths
  @State private var selection: PositionSelection?

  private static let logger = Logger(
    subsystem: "com.moolah.app", category: "MultiInstrumentPositionsSplitModifier")

  private var hasPositions: Bool {
    AccountDetailLayout.hasNonHostHoldings(
      rawPositions: positions,
      hostCurrency: hostCurrency,
      positionsInput: positionsInput)
  }

  func body(content: Content) -> some View {
    PositionsChartTransactionsSplit(hasPositions: hasPositions) {
      content
    } positions: {
      if let positionsInput {
        PositionsPane(input: positionsInput, selection: $selection)
      } else {
        ProgressView()
          .frame(maxWidth: .infinity)
          .padding()
          .accessibilityLabel("Loading positions")
      }
    } chart: {
      if let positionsInput {
        PositionsChartPane(
          input: positionsInput, range: $positionsRange, selection: $selection)
      } else {
        ProgressView()
          .frame(maxWidth: .infinity)
          .padding()
          .accessibilityLabel("Loading chart")
      }
    }
    .task(
      id: PositionsTaskKey(
        positions: positions,
        registrationsVersion: registrationsVersion,
        range: positionsRange)
    ) {
      await valuatePositions()
    }
    #if os(macOS)
      .onExitCommand { selection = nil }
    #endif
    .onChange(of: positionsInput) { _, _ in selection = nil }
  }

  private func valuatePositions() async {
    // A superseded task (SwiftUI cancels the old `.task(id:)` before starting
    // the new one) must not run its body at all — otherwise the early-return
    // empty-seed below could land after a newer task's correct write and clobber
    // it to blank until the next key change. Mirrors the post-`await` guards.
    guard !Task.isCancelled else { return }
    guard let conversionService, !positions.isEmpty else {
      // Nothing to value (no conversion service, or an account with no
      // positions). Settle to an empty input so the always-present Chart
      // tab renders a header rather than a perpetual loading spinner.
      positionsInput = PositionsViewInput(
        title: title, hostCurrency: hostCurrency, positions: [], historicalValue: nil)
      return
    }
    let valuator = PositionsValuator(conversionService: conversionService)
    // Only a single-account host has one unambiguous owning chain; group hosts
    // (plural `accountIds`) leave it nil so the fold derives no false chain.
    let owningChainId = accountIds.count == 1 ? accountChainId : nil
    let rows = await valuator.valuate(
      positions: positions,
      hostCurrency: hostCurrency,
      costBasis: [:],
      on: Date(),
      accountChainId: owningChainId
    )
    // The valuator cooperates with cancellation by breaking out of its
    // per-row loop, but it cannot signal cancellation through the
    // non-throwing return — re-check here so a stale (or partial) `rows`
    // from a superseded task never overwrites the freshly-emitting one.
    guard !Task.isCancelled else { return }
    var assetKeys: [String: String] = [:]
    do {
      assetKeys = try await CryptoRegistration.assetKeys(from: session?.backend.instrumentRegistry)
    } catch is CancellationError {
      return
    } catch {
      Self.logger.warning(
        "allCryptoRegistrations failed, asset rollup disabled: \(error.localizedDescription, privacy: .public)"
      )
    }
    guard !Task.isCancelled else { return }
    // Progressive render: show the positions table immediately with the
    // current valuation; the historical chart fills in from buildHistoryInput
    // below. isHistoryLoading drives the chart-area loading placeholder.
    if !accountIds.isEmpty {
      // Preserve the previously-built series (if any) so a re-fire
      // (range change, routine positions refresh) doesn't wipe an
      // already-rendered chart back to a spinner. On genuine first load
      // `positionsInput` is nil, so this is nil and the placeholder
      // still shows.
      positionsInput = loadingBaseInput(
        rows: rows,
        assetKeys: assetKeys,
        historicalValue: positionsInput?.historicalValue,
        isHistoryLoading: true)
    }
    if !accountIds.isEmpty, let repository = session?.backend.transactions {
      await buildHistoryInput(
        conversionService: conversionService,
        rows: rows,
        assetKeys: assetKeys,
        repository: repository
      )
      return
    }
    positionsInput = loadingBaseInput(
      rows: rows,
      assetKeys: assetKeys,
      historicalValue: nil,
      isHistoryLoading: false)
  }

  /// Shared `PositionsViewInput` construction for `valuatePositions()`'s two
  /// non-history-assembled sites (the stage-1 loading assignment and the
  /// no-account-ids fallback). They differ only in `historicalValue` and
  /// `isHistoryLoading`.
  private func loadingBaseInput(
    rows: [ValuedPosition],
    assetKeys: [String: String],
    historicalValue: HistoricalValueSeries?,
    isHistoryLoading: Bool
  ) -> PositionsViewInput {
    PositionsViewInput(
      title: title,
      hostCurrency: hostCurrency,
      positions: rows,
      historicalValue: historicalValue,
      assetKeysByInstrumentId: assetKeys,
      isHistoryLoading: isHistoryLoading)
  }

  private func buildHistoryInput(
    conversionService service: any InstrumentConversionService,
    rows: [ValuedPosition],
    assetKeys: [String: String],
    repository: any TransactionRepository
  ) async {
    let accountIdSet = Set(accountIds)
    let assembler = MultiInstrumentPositionsAssembler(conversionService: service)
    let txns: [Transaction]
    do {
      txns = try await assembler.fetchTransactions(
        repository: repository, accountIds: accountIdSet)
    } catch is CancellationError {
      return
    } catch {
      Self.logger.warning(
        "history txn fetch failed: \(error.localizedDescription, privacy: .public)")
      txns = []
    }
    guard !Task.isCancelled else { return }
    let performance = await computePerformance(
      accountIds: accountIdSet,
      transactions: txns,
      rows: rows,
      conversionService: service)
    guard !Task.isCancelled else { return }
    let context = PositionsAssemblyContext(
      title: title,
      hostCurrency: hostCurrency,
      accountIds: accountIdSet,
      assetKeysByInstrumentId: assetKeys,
      performance: performance,
      alwaysShowsFullSurface: false)
    let input = await assembler.assemble(
      context: context,
      valuedRows: rows,
      transactions: txns,
      range: positionsRange)
    guard !Task.isCancelled else { return }
    positionsInput = input
  }

  /// Computes the account-level `AccountPerformance` that feeds the Chart
  /// pane's tiles. Gated so fiat-only accounts skip it (→ `nil` → the pane
  /// falls back to the plain `PositionsHeader`) and never pay for the flow
  /// conversions. Returns `nil` on cancellation so a superseding valuator
  /// pass owns the write. Reuses
  /// `AccountPerformanceCalculator.computeMultiInstrument` — no
  /// Modified-Dietz reimplementation here.
  private func computePerformance(
    accountIds: Set<UUID>,
    transactions: [Transaction],
    rows: [ValuedPosition],
    conversionService: any InstrumentConversionService
  ) async -> AccountPerformance? {
    guard
      AccountDetailLayout.showsPerformanceTiles(
        valuedRows: rows, hostCurrency: hostCurrency)
    else { return nil }
    do {
      return try await AccountPerformanceCalculator.computeMultiInstrument(
        accountIds: accountIds,
        transactions: transactions,
        valuedPositions: rows,
        profileCurrency: hostCurrency,
        conversionService: conversionService)
    } catch {
      // `computeMultiInstrument` throws only `CancellationError`: a
      // superseding pass owns the write now, so drop this one.
      return nil
    }
  }
}

/// Composite id for the positions-valuation `.task(id:)`. Re-fires when
/// the positions list changes, the crypto-registry version bumps
/// (spam flip in preferences), or the selected time range changes.
/// Issue #790.
private struct PositionsTaskKey: Hashable {
  let positions: [Position]
  let registrationsVersion: Int
  let range: PositionsTimeRange
}

extension View {
  /// Wraps the view in `PositionsChartTransactionsSplit` — chart and
  /// transactions are always present; the Positions pane appears only
  /// when the account has non-host-currency holdings. Owns the
  /// positions valuator lifecycle.
  func multiInstrumentPositionsSplit(
    positions: [Position],
    hostCurrency: Instrument,
    title: String,
    conversionService: (any InstrumentConversionService)?,
    registrationsVersion: Int = 0,
    accountIds: [UUID] = [],
    accountChainId: Int? = nil
  ) -> some View {
    modifier(
      MultiInstrumentPositionsSplitModifier(
        positions: positions,
        hostCurrency: hostCurrency,
        title: title,
        conversionService: conversionService,
        registrationsVersion: registrationsVersion,
        accountIds: accountIds,
        accountChainId: accountChainId))
  }
}

// MARK: - Preview

@MainActor
private func multiInstrumentSplitPreviewContent(
  positions: [Position],
  title: String
) -> some View {
  let backend = PreviewBackend.create()
  return Text("Transactions list goes here")
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .multiInstrumentPositionsSplit(
      positions: positions,
      hostCurrency: .AUD,
      title: title,
      conversionService: backend.conversionService)
}

/// Multi-instrument positions: `hasPositions` is true so the pinned
/// Positions pane appears alongside `[Transactions | Chart]`.
#Preview("Split shown — multi-instrument") {
  multiInstrumentSplitPreviewContent(
    positions: [
      Position(instrument: .AUD, quantity: 1_000),
      Position(instrument: .USD, quantity: 250),
    ],
    title: "Multi-currency Account")
}

/// Fiat-only account: `hasPositions` is false so no Positions pane,
/// but the wrapper still renders `[Transactions | Chart]` — the chart
/// tab shows the balance line rather than the old bare transaction list.
#Preview("Chart + transactions — fiat only (no positions pane)") {
  multiInstrumentSplitPreviewContent(
    positions: [Position(instrument: .AUD, quantity: 1_000)],
    title: "Plain Account")
}
