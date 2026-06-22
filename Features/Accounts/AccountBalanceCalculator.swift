import Foundation
import OSLog

/// Computes per-account display balances and aggregate totals for
/// `AccountStore`, isolating the conversion-service orchestration from the
/// store's state management and mutation responsibilities.
///
/// A single `compute(...)` call iterates every account in isolation, so one
/// failure doesn't block balances for other accounts. Aggregate totals are
/// only non-nil when *all* contributing accounts converted successfully —
/// an inaccurate aggregate is worse than no aggregate.
///
/// Callers (the store) re-invoke `compute` from a retry loop until nothing
/// fails; the calculator itself holds no retry state.
@MainActor
struct AccountBalanceCalculator {
  let conversionService: any InstrumentConversionService
  let targetInstrument: Instrument

  /// Everything the store needs to publish after a single conversion pass.
  struct Snapshot: Sendable {
    let balances: [UUID: InstrumentAmount]
    let currentTotal: InstrumentAmount?
    let investmentTotal: InstrumentAmount?
    let netWorth: InstrumentAmount?
    let anyFailed: Bool
  }

  private var logger: Logger {
    Logger(subsystem: "com.moolah.app", category: "AccountBalanceCalculator")
  }

  /// Computes a snapshot of per-account balances + aggregates. Honours
  /// `Task.isCancelled` between phases; when cancelled, returns a snapshot
  /// flagged `anyFailed = false` so callers short-circuit without re-trying.
  func compute(
    allAccounts: [Account],
    currentAccounts: [Account],
    investmentAccounts: [Account],
    investmentValues: InvestmentValueCache
  ) async -> Snapshot {
    var anyFailed = false
    var newBalances: [UUID: InstrumentAmount] = [:]

    // Capture once so every conversion in this pass uses the same `date`.
    // Without this, a pass that crosses midnight would convert some
    // accounts at the previous day's rate and others at the next day's,
    // producing an aggregate that doesn't tie out to any single day.
    let date = Date()

    // Phase 1: per-account display balance in the account's own instrument.
    // Iterate all accounts so per-account display works regardless of showHidden.
    for account in allAccounts {
      do {
        let balance = try await displayBalance(
          for: account,
          investmentValue: investmentValues.value(for: account.id),
          date: date)
        guard !Task.isCancelled else { return cancelledSnapshot() }
        newBalances[account.id] = balance
      } catch {
        anyFailed = true
        logger.warning(
          "Conversion failed for account \(account.name): \(error.localizedDescription)")
      }
    }

    guard !Task.isCancelled else { return cancelledSnapshot() }

    // Phase 2: aggregate totals — only valid when every contributing account
    // converted successfully *and* the per-account → target conversion works.
    let (currentTotal, currentValid) = await sumConverted(
      accounts: currentAccounts, balances: newBalances, on: date)
    guard !Task.isCancelled else { return cancelledSnapshot() }
    let (investmentTotal, investmentValid) = await sumConverted(
      accounts: investmentAccounts, balances: newBalances, on: date)

    guard !Task.isCancelled else { return cancelledSnapshot() }

    if !currentValid || !investmentValid { anyFailed = true }

    return Snapshot(
      balances: newBalances,
      currentTotal: currentValid ? currentTotal : nil,
      investmentTotal: investmentValid ? investmentTotal : nil,
      netWorth: (currentValid && investmentValid) ? (currentTotal + investmentTotal) : nil,
      anyFailed: anyFailed
    )
  }

  /// Sum every account's contribution converted to `target`. Investment
  /// accounts in `recordedValue` mode contribute their cached snapshot (or
  /// zero when none is set); every other account sums positions directly to
  /// `target` in one pass — avoiding the double-conversion a naive
  /// `positions → account instrument → target` implementation would incur.
  ///
  /// Positions whose conversion resolves to `.knownZero` (an `.unpriced`
  /// / `.spam` crypto registration) contribute zero to the total; a
  /// thrown conversion error still propagates as before, marking the
  /// total unavailable per Rule 11. See issue #790.
  func totalConverted(
    for accounts: [Account],
    to target: Instrument,
    using investmentValues: InvestmentValueCache? = nil
  ) async throws -> InstrumentAmount {
    var total = InstrumentAmount.zero(instrument: target)
    let date = Date()
    // recordedValue snapshots keep their existing `convertAmount` semantics
    // (throw on failure, throw on knownZero). Every other account's
    // cross-instrument positions accumulate into one flat batch resolved by a
    // single `convertResultBatch`. Same-instrument positions sum inline
    // (Rule 8). A `.failure` outcome rethrows so the whole total is marked
    // unavailable (Rule 11); `.knownZero` contributes zero (#790).
    var requests: [BatchConversionRequest] = []
    for account in accounts {
      if account.type == .investment, account.valuationMode == .recordedValue {
        let snapshot =
          investmentValues?.value(for: account.id)
          ?? .zero(instrument: account.instrument)
        if snapshot.instrument == target {
          total += snapshot
        } else {
          total += try await conversionService.convertAmount(
            snapshot, to: target, on: date)
        }
        try Task.checkCancellation()
        continue
      }
      for position in account.positions {
        if position.amount.instrument == target {
          total += position.amount
        } else {
          requests.append(
            BatchConversionRequest(amount: position.amount, target: target, date: date))
        }
      }
    }
    let outcomes = try await conversionService.convertResultBatch(requests)
    for outcome in outcomes {
      switch outcome {
      case .value(let converted): total += converted
      case .knownZero: break
      case .failure(let error): throw error
      }
    }
    return total
  }

  /// The display balance for an account in its own instrument. Investment
  /// accounts in `recordedValue` mode return the externally-provided
  /// snapshot (or zero when absent); all other accounts sum every position
  /// converted via the conversion service.
  ///
  /// Positions whose conversion resolves to `.knownZero` (an `.unpriced`
  /// / `.spam` crypto registration) contribute zero to the displayed
  /// balance; a thrown conversion error still propagates so the balance
  /// is marked unavailable per Rule 11. See issue #790.
  ///
  /// A `.crypto` account's `instrument` is the profile currency (set at
  /// creation), so this loop converts each native-token position into the
  /// profile currency on `date` — the current-value read the user expects
  /// for a wallet's worth. The native token is never the account
  /// instrument, so the same-instrument fast path below only fires for a
  /// position that already happens to be in the profile currency.
  ///
  /// Pass `date` to share a conversion timestamp across a multi-account
  /// pass; defaults to `Date()` for one-shot callers.
  func displayBalance(
    for account: Account, investmentValue: InstrumentAmount?, date: Date = Date()
  ) async throws -> InstrumentAmount {
    if account.type == .investment, account.valuationMode == .recordedValue {
      return investmentValue ?? .zero(instrument: account.instrument)
    }
    let target = account.instrument
    var total = InstrumentAmount.zero(instrument: target)
    // Sum same-instrument positions inline (Rule 8 fast path); batch the
    // rest into a single `convertResultBatch`. A `.failure` outcome rethrows
    // so the caller marks the balance unavailable (Rule 11); `.knownZero`
    // contributes nothing (#790).
    var requests: [BatchConversionRequest] = []
    for position in account.positions {
      if position.amount.instrument == target {
        total += position.amount
      } else {
        requests.append(
          BatchConversionRequest(amount: position.amount, target: target, date: date))
      }
    }
    let outcomes = try await conversionService.convertResultBatch(requests)
    for outcome in outcomes {
      switch outcome {
      case .value(let converted): total += converted
      case .knownZero: break
      case .failure(let error): throw error
      }
    }
    return total
  }

  /// Sums the per-account balances converted to `targetInstrument`. Returns
  /// `(total, valid)`; `valid` is false if any account is missing from
  /// `balances` or if its target conversion throws. Bails out on the first
  /// failure so we don't keep issuing conversion calls whose results would
  /// be discarded.
  private func sumConverted(
    accounts list: [Account],
    balances: [UUID: InstrumentAmount],
    on date: Date
  ) async -> (InstrumentAmount, Bool) {
    // Collect one request per account, bailing if any account is missing
    // from `balances` (same as the serial guard). Resolve all in one
    // `convertResultBatch`; any `.failure` marks the whole aggregate
    // unavailable — an inaccurate aggregate is worse than no aggregate.
    var requests: [BatchConversionRequest] = []
    requests.reserveCapacity(list.count)
    for account in list {
      guard let balance = balances[account.id] else {
        return (.zero(instrument: targetInstrument), false)
      }
      requests.append(
        BatchConversionRequest(amount: balance, target: targetInstrument, date: date))
    }
    let outcomes: [BatchConversionOutcome]
    do {
      outcomes = try await conversionService.convertResultBatch(requests)
    } catch {
      // Cancellation: caller re-checks `Task.isCancelled` and short-circuits.
      return (.zero(instrument: targetInstrument), false)
    }
    var total = InstrumentAmount.zero(instrument: targetInstrument)
    for (account, outcome) in zip(list, outcomes) {
      switch outcome {
      case .value(let converted): total += converted
      case .knownZero:
        // Unreachable today: each request converts a per-account display
        // balance, which is always fiat / the profile currency and so can't
        // resolve to a `.knownZero` (.unpriced / .spam) crypto source. Guard
        // it anyway — a future account type with a crypto display instrument
        // would land here, and silently folding it to zero would understate
        // the aggregate. Mark the total unavailable instead (#790).
        assertionFailure(
          "Aggregate display balance resolved to .knownZero for \(account.name); "
            + "display balances are expected to be fiat / profile currency.")
        return (.zero(instrument: targetInstrument), false)
      case .failure(let error):
        logger.warning(
          "Aggregate conversion failed for \(account.name): \(error.localizedDescription)")
        return (.zero(instrument: targetInstrument), false)
      }
    }
    return (total, true)
  }

  private func cancelledSnapshot() -> Snapshot {
    Snapshot(
      balances: [:], currentTotal: nil, investmentTotal: nil, netWorth: nil, anyFailed: false)
  }
}
