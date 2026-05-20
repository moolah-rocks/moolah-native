import Foundation

// Spam-hiding filter surface for `TransactionStore`.
//
// The store keeps a raw `unfilteredTransactions` backing list and
// re-publishes the view-visible `transactions` whenever any of the
// three filter inputs change: the raw list itself (data path via
// `setTransactions(_:)`), the `showSpam` toggle, or the set of
// instruments currently flagged as spam (`spamInstruments`).
//
// See `plans/2026-05-20-hide-spam-transactions-design.md`.
extension TransactionStore {

  /// Primes both spam-filter inputs atomically on first mount. The
  /// instrument set is written without publishing (via the internal
  /// `setSpamInstrumentsValue(_:)` helper), then `showSpam`'s `didSet`
  /// fires `publishFilteredTransactions()` exactly once with both
  /// inputs in their final state. Use this from `.onAppear` rather
  /// than two separate assignments — otherwise the intermediate state
  /// transiently publishes with the new `showSpam` but the stale
  /// `spamInstruments`.
  func primeSpamFilter(instruments: Set<Instrument>, showSpam: Bool) {
    setSpamInstrumentsValue(instruments)
    self.showSpam = showSpam
  }

  /// Updates `spamInstruments` and re-publishes the filtered
  /// `transactions` if the set actually changed. No-ops if the new
  /// value equals the current one (avoids spurious view re-renders).
  func setSpamInstruments(_ value: Set<Instrument>) {
    guard value != spamInstruments else { return }
    setSpamInstrumentsValue(value)
    publishFilteredTransactions()
  }

  // Internal (not private) because it is called both from this extension
  // AND from the `showSpam.didSet` observer in `TransactionStore.swift`.
  // A stored property's `didSet` cannot live in an extension, and Swift
  // `private` is file-scoped, so the observer in the main file cannot
  // reach a `private` member declared here. Do not call from feature code.
  //
  // Recomputes `transactions` from `unfilteredTransactions` against
  // the current `showSpam` / `spamInstruments` inputs. Cheap when
  // `showSpam == true` or `spamInstruments.isEmpty` (no walk).
  func publishFilteredTransactions() {
    if showSpam || spamInstruments.isEmpty {
      setFilteredTransactions(unfilteredTransactions)
    } else {
      setFilteredTransactions(
        unfilteredTransactions.filter {
          !$0.transaction.isAllSpam(in: spamInstruments)
        })
    }
  }
}
