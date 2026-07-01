import SwiftUI
import os

/// Conditionally wraps a `TransactionListView` (or any other content)
/// in a `PositionsTransactionsSplit` when the account has positions in
/// instruments other than its host currency. Owns the positions
/// valuator `.task(id:)` so the wrapping leaf doesn't need to manage
/// the valuation lifecycle.
///
/// **Decision predicate** — see `shouldShow(rawPositions:hostCurrency:positionsInput:)`.
/// Once the valuator has produced a `positionsInput`, that becomes
/// authoritative because it has already dropped `.knownZero` (`.spam`
/// / `.unpriced`) rows; relying on the raw-positions heuristic alone
/// can otherwise leave the split rendered with an inner
/// `PositionsView` that returns `EmptyView`, manifesting as a large
/// blank pane above the transactions list.
///
/// **Re-fire trigger** — the `.task(id:)` re-fires whenever the
/// positions list changes OR the crypto-registry version bumps (e.g.
/// the user marks a token as `.spam`). Without the version dimension
/// a spam flip in preferences would leave a stale `valuedPositions`
/// on screen — see issue #790 for the original rationale.
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

  private static let logger = Logger(
    subsystem: "com.moolah.app", category: "MultiInstrumentPositionsSplitModifier")

  /// Pure decision helper. Once the valuator produces a
  /// `positionsInput`, that becomes authoritative — its `shouldHide`
  /// has already filtered out `.knownZero` (spam / unpriced) positions
  /// and so agrees with what the inner `PositionsView` will actually
  /// render. Pre-valuation, fall back to a heuristic on raw positions
  /// so the split can render with a `ProgressView` while the valuator
  /// works.
  ///
  /// `nonisolated` so unit tests can call this without spinning up a
  /// `@MainActor` context — the body touches only value-type inputs
  /// (no view state, no actor-isolated dependencies).
  nonisolated static func shouldShow(
    rawPositions: [Position],
    hostCurrency: Instrument,
    positionsInput: PositionsViewInput?
  ) -> Bool {
    if let positionsInput {
      return !positionsInput.shouldHide
    }
    guard !rawPositions.isEmpty else { return false }
    let nonZeroInstruments = Set(
      rawPositions.lazy.filter { $0.quantity != 0 }.map(\.instrument)
    )
    return nonZeroInstruments != [hostCurrency]
  }

  private var shouldShow: Bool {
    Self.shouldShow(
      rawPositions: positions,
      hostCurrency: hostCurrency,
      positionsInput: positionsInput)
  }

  func body(content: Content) -> some View {
    if shouldShow {
      PositionsTransactionsSplit(defaultTab: .transactions) {
        if let positionsInput {
          PositionsView(input: positionsInput, range: $positionsRange)
        } else {
          ProgressView()
            .frame(maxWidth: .infinity)
            .padding()
        }
      } transactions: {
        content
      }
      .task(
        id: PositionsTaskKey(
          positions: positions, registrationsVersion: registrationsVersion, range: positionsRange)
      ) {
        await valuatePositions()
      }
    } else {
      content
    }
  }

  private func valuatePositions() async {
    guard let conversionService, !positions.isEmpty else {
      positionsInput = nil
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
    if !accountIds.isEmpty, let repository = session?.backend.transactions {
      await buildHistoryInput(
        conversionService: conversionService,
        rows: rows,
        assetKeys: assetKeys,
        repository: repository
      )
      return
    }
    positionsInput = PositionsViewInput(
      title: title,
      hostCurrency: hostCurrency,
      positions: rows,
      historicalValue: nil,
      assetKeysByInstrumentId: assetKeys
    )
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
    let context = PositionsAssemblyContext(
      title: title,
      hostCurrency: hostCurrency,
      accountIds: accountIdSet,
      assetKeysByInstrumentId: assetKeys,
      performance: nil,
      alwaysShowsFullSurface: false)
    let input = await assembler.assemble(
      context: context,
      valuedRows: rows,
      transactions: txns,
      range: positionsRange)
    guard !Task.isCancelled else { return }
    positionsInput = input
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
  /// Wraps the view in a `PositionsTransactionsSplit` when the account
  /// has positions in non-host-currency instruments. No-op otherwise.
  /// Owns the positions valuator lifecycle.
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

/// Multi-instrument positions exercise the split-shown branch. The
/// host currency is AUD; the positions include a USD holding so
/// `shouldShow` returns true and the wrapper renders the split.
#Preview("Split shown — multi-instrument") {
  multiInstrumentSplitPreviewContent(
    positions: [
      Position(instrument: .AUD, quantity: 1_000),
      Position(instrument: .USD, quantity: 250),
    ],
    title: "Multi-currency Account")
}

/// Single-instrument positions in the host currency exercise the
/// no-op branch — `shouldShow` returns false and the wrapper passes
/// the content through unchanged.
#Preview("Split hidden — host-currency only") {
  multiInstrumentSplitPreviewContent(
    positions: [Position(instrument: .AUD, quantity: 1_000)],
    title: "Plain Account")
}
