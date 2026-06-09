import Foundation

/// Background crypto-price warming kicked off after a wallet sync's apply
/// pass. Lives in its own extension so the warm trigger, the observable
/// `priceWarmingInProgress` setter shim, and the test seam stay together
/// and out of the core store / internals files. See issue #1075.
extension SyncedAccountStore {

  /// Best-effort background price warm for the just-synced accounts'
  /// crypto tokens. Replaces any in-flight warm (the newest sync's
  /// survivor set supersedes). A no-op when no warmer is wired, or when
  /// this pass produced no genuinely-new transactions / had no
  /// participating accounts.
  func startPriceWarming(genuinelyNew: [Transaction], accountIds: Set<UUID>) {
    guard let priceWarmer, !genuinelyNew.isEmpty, !accountIds.isEmpty else { return }
    priceWarmingTask?.cancel()
    setPriceWarmingInProgress(true)
    priceWarmingTask = Task { [weak self] in
      await priceWarmer.warm(transactions: genuinelyNew, accountIds: accountIds)
      self?.setPriceWarmingInProgress(false)
    }
  }

  /// Test seam — awaits the in-flight background price-warm task (if any)
  /// to completion so a test can assert on `priceWarmingInProgress`
  /// having reset and on the injected warmer having been invoked.
  func waitForPriceWarming() async {
    await priceWarmingTask?.value
  }
}
