import XCTest

/// Per-seed fixture-text helpers consumed by
/// `MoolahUITestCase.collectFailureArtefacts(for:succeeded:)` when
/// rendering `seed.txt`. Split out from `MoolahUITestCase+Artefacts.swift`
/// so the artefact-collection plumbing and the per-seed payload mirror
/// can grow independently — every new seed adds an `appendXxxFixtures`
/// helper here without inflating the host file past SwiftLint's
/// `file_length` threshold.
///
/// All helpers are `internal` so the dispatcher in
/// `MoolahUITestCase+Artefacts.swift` can route to them while staying
/// `private` to the test target.
@MainActor
extension MoolahUITestCase {

  func appendSidebarFooterFixtures(seed: UITestSeed, into lines: inout [String]) {
    switch seed {
    case .sidebarFooterUpToDate:
      lines.append("# SyncProgress driven to .upToDate, lastSettledAt ~5 minutes ago")
    case .sidebarFooterReceiving:
      lines.append("# SyncProgress driven to .receiving with recordsReceivedThisSession=1234")
    case .sidebarFooterSending:
      lines.append("# SyncProgress driven to .upToDate with pendingUploads=12 then settled")
    default:
      break  // unreachable — caller filters to sidebar-footer seeds
    }
  }

  func appendIncompatibleProfileFixtures(into lines: inout [String]) {
    let fixtures = UITestIncompatibleProfileFixtures.self
    lines.append("# fixtures — multi-profile picker with one incompatible row")
    lines.append("compatible.id      = \(fixtures.compatibleProfileId)")
    lines.append("compatible.label   = \(fixtures.compatibleProfileLabel)")
    lines.append("compatible.dataFormatVersion = 0")
    lines.append("incompatible.id    = \(fixtures.profileId)")
    lines.append("incompatible.label = \(fixtures.profileLabel)")
    lines.append("incompatible.dataFormatVersion = DataFormatVersion.current + 1")
  }

  func appendCryptoCatalogPreloadedFixtures(into lines: inout [String]) {
    let fixtures = UITestFixtures.CryptoCatalogPreloaded.self
    lines.append("# fixtures (CloudKit profile reused from TradeBaseline)")
    lines.append("profile.id      = \(fixtures.profileId)")
    lines.append("profile.label   = \(fixtures.profileLabel)")
    lines.append("profile.currency = \(fixtures.profileCurrencyCode)")
    lines.append("# Catalog override: PreloadedCryptoCatalog (single coin)")
    lines.append("catalog.coingeckoId = \(fixtures.coingeckoId)")
    lines.append("catalog.symbol      = \(fixtures.symbol)")
    lines.append("catalog.name        = \(fixtures.name)")
    lines.append("catalog.chainSlug   = \(fixtures.chainSlug)")
    lines.append("catalog.chainId     = \(fixtures.chainId)")
    lines.append("catalog.contract    = \(fixtures.contractAddress)")
    lines.append("instrument.id       = \(fixtures.instrumentId)")
    lines.append("# Resolution stub: PreloadedTokenResolutionClient")
    lines.append("resolve.coingeckoId        = \(fixtures.coingeckoMappingId)")
    lines.append("resolve.binanceSymbol      = \(fixtures.binanceSymbol)")
  }

  func appendTradeReadyFixtures(into lines: inout [String]) {
    let fixtures = UITestFixtures.TradeReady.self
    lines.append("# fixtures")
    lines.append("profile.id       = \(fixtures.profileId)")
    lines.append("profile.label    = \(fixtures.profileLabel)")
    lines.append("profile.currency = \(fixtures.profileCurrencyCode)")
    lines.append("brokerage.id     = \(fixtures.brokerageAccountId)")
    lines.append("brokerage.name   = \(fixtures.brokerageAccountName)")
    lines.append("instrument.id    = \(fixtures.vgsaxInstrumentId)")
    lines.append("instrument.ticker = \(fixtures.vgsaxTicker)")
    lines.append("instrument.exchange = \(fixtures.vgsaxExchange)")
    lines.append("category.id      = \(fixtures.brokerageCategoryId)")
    lines.append("category.name    = \(fixtures.brokerageCategoryName)")
  }

  func appendTradeBaselineFixtures(into lines: inout [String]) {
    let fixtures = UITestFixtures.TradeBaseline.self
    lines.append("# fixtures")
    lines.append("profile.id      = \(fixtures.profileId)")
    lines.append("profile.label   = \(fixtures.profileLabel)")
    lines.append("profile.currency = \(fixtures.profileCurrencyCode)")
    lines.append("checking.id     = \(fixtures.checkingAccountId)")
    lines.append("checking.name   = \(fixtures.checkingAccountName)")
    lines.append("brokerage.id    = \(fixtures.brokerageAccountId)")
    lines.append("brokerage.name  = \(fixtures.brokerageAccountName)")
    lines.append("usdSavings.id   = \(fixtures.usdAccountId)")
    lines.append("usdSavings.name = \(fixtures.usdAccountName)")
    lines.append("usdSavings.instrument = \(fixtures.usdAccountInstrumentCode)")
    lines.append("trade.id        = \(fixtures.bhpPurchaseId)")
    lines.append("trade.payee     = \(fixtures.bhpPurchasePayee)")
    lines.append("trade.cents     = \(fixtures.bhpPurchaseAmountCents)")
    lines.append("trade.date      = \(fixtures.bhpPurchaseDate)")
    lines.append("historical.amount.cents = \(fixtures.historicalExpenseAmountCents)")
    for (index, historical) in fixtures.historicalPayees.enumerated() {
      let category = historical.categoryId.map(String.init(describing:)) ?? "nil"
      lines.append(
        "historical[\(index)].id/payee/daysAgo/category = "
          + "\(historical.id) / \(historical.payee) / \(historical.daysAgo) / \(category)"
      )
    }
    lines.append(
      "category.groceries.id/name = "
        + "\(fixtures.groceriesCategoryId) / \(fixtures.groceriesCategoryName)")
    lines.append("category.gym.id/name = \(fixtures.gymCategoryId) / \(fixtures.gymCategoryName)")
    lines.append(
      "splitShop.id/payee/date = "
        + "\(fixtures.splitShopId) / \(fixtures.splitShopPayee) / \(fixtures.splitShopDate)")
    lines.append(
      "splitShop.legA.cents / legB.cents = "
        + "\(fixtures.splitShopLegAAmountCents) / \(fixtures.splitShopLegBAmountCents)"
    )
  }

  func appendTransferDetectionFixtures(into lines: inout [String]) {
    let fixtures = UITestFixtures.TransferDetection.self
    lines.append("# fixtures")
    lines.append("profile.id       = \(fixtures.profileId)")
    lines.append("profile.label    = \(fixtures.profileLabel)")
    lines.append("profile.currency = \(fixtures.profileCurrencyCode)")
    lines.append("everyday.id      = \(fixtures.everydayAccountId)")
    lines.append("everyday.name    = \(fixtures.everydayAccountName)")
    lines.append("savings.id       = \(fixtures.savingsAccountId)")
    lines.append("savings.name     = \(fixtures.savingsAccountName)")
    lines.append(
      "merge.outgoing.id/payee/cents/date = "
        + "\(fixtures.mergeOutgoingId) / \(fixtures.mergeOutgoingPayee) "
        + "/ \(fixtures.mergeOutgoingCents) / \(fixtures.mergeOutgoingDate)")
    lines.append(
      "merge.incoming.id/payee/cents/date = "
        + "\(fixtures.mergeIncomingId) / \(fixtures.mergeIncomingPayee) "
        + "/ \(fixtures.mergeIncomingCents) / \(fixtures.mergeIncomingDate)")
    lines.append(
      "dismiss.outgoing.id/payee/cents/date = "
        + "\(fixtures.dismissOutgoingId) / \(fixtures.dismissOutgoingPayee) "
        + "/ \(fixtures.dismissOutgoingCents) / \(fixtures.dismissOutgoingDate)")
    lines.append(
      "dismiss.incoming.id/payee/cents/date = "
        + "\(fixtures.dismissIncomingId) / \(fixtures.dismissIncomingPayee) "
        + "/ \(fixtures.dismissIncomingCents) / \(fixtures.dismissIncomingDate)")
    lines.append("suggestion.suggestedAt = \(fixtures.suggestedAt)")
    lines.append(
      "importedAt    = launch time − 1h (inside the 24h Recently Added "
        + "window; wall-clock-relative by design — one shared value "
        + "across all four transactions)")
    lines.append("# import origin: .single")
  }

  func appendWelcomeSingleProfileFixtures(into lines: inout [String]) {
    lines.append("# fixtures")
    lines.append(
      "household.id/label = "
        + "\(UITestWelcomeFixtures.householdProfileId) "
        + "/ \(UITestWelcomeFixtures.householdProfileLabel)"
    )
  }

  func appendWelcomeMultipleProfileFixtures(into lines: inout [String]) {
    lines.append("# fixtures")
    lines.append(
      "household.id/label = "
        + "\(UITestWelcomeFixtures.householdProfileId) "
        + "/ \(UITestWelcomeFixtures.householdProfileLabel)"
    )
    lines.append(
      "sideBusiness.id/label = "
        + "\(UITestWelcomeFixtures.sideBusinessProfileId) "
        + "/ \(UITestWelcomeFixtures.sideBusinessProfileLabel)"
    )
  }

  func appendInsightsForYouFixtures(into lines: inout [String]) {
    let fixtures = UITestFixtures.InsightsForYou.self
    lines.append("# fixtures — tradeBaseline profile + three injected fixture insights")
    lines.append("largeTxn.id/title    = \(fixtures.largeTxnId) / \(fixtures.largeTxnTitle)")
    lines.append("priceHike.id/title   = \(fixtures.priceHikeId) / \(fixtures.priceHikeTitle)")
    lines.append("milestone.id/title   = \(fixtures.milestoneId) / \(fixtures.milestoneTitle)")
    lines.append(
      "largeTxn references checking account "
        + "\(UITestFixtures.TradeBaseline.checkingAccountId) "
        + "(\(UITestFixtures.TradeBaseline.checkingAccountName)) → has 'View'")
    lines.append("scripted.narration = \(UITestFixtures.InsightsForYou.scriptedNarration)")
    lines.append(
      "largeTxn carries a 6-month bar chart (anomaly spike in the final month) "
        + "→ has an inline chart Button that zooms to the detail sheet")
  }

  func appendGroupFilterScopeFixtures(into lines: inout [String]) {
    let fixtures = UITestFixtures.GroupFilterScope.self
    lines.append("# fixtures")
    lines.append("profile.id       = \(fixtures.profileId)")
    lines.append("profile.label    = \(fixtures.profileLabel)")
    lines.append("profile.currency = \(fixtures.profileCurrencyCode)")
    lines.append("group.id/name    = \(fixtures.filterGroupId) / \(fixtures.filterGroupName)")
    lines.append(
      "memberOne.id/name = \(fixtures.memberOneId) / \(fixtures.memberOneName) (in group)")
    lines.append(
      "memberTwo.id/name = \(fixtures.memberTwoId) / \(fixtures.memberTwoName) (in group)")
    lines.append(
      "outsider.id/name  = \(fixtures.outsiderId) / \(fixtures.outsiderName) (standalone)")
    lines.append("expense.amount.cents = \(fixtures.expenseAmountCents)")
    lines.append(
      "memberOneTxn.id/payee/daysAgo = \(fixtures.memberOneTxnId) "
        + "/ \(fixtures.memberOneTxnPayee) / \(fixtures.memberOneTxnDaysAgo)")
    lines.append(
      "memberTwoTxn.id/payee/daysAgo = \(fixtures.memberTwoTxnId) "
        + "/ \(fixtures.memberTwoTxnPayee) / \(fixtures.memberTwoTxnDaysAgo)")
    lines.append(
      "outsiderTxn.id/payee/daysAgo  = \(fixtures.outsiderTxnId) "
        + "/ \(fixtures.outsiderTxnPayee) / \(fixtures.outsiderTxnDaysAgo)")
    lines.append(
      "# transaction dates are anchored days-before-launch so the filter "
        + "dialog's default [now − 1 month, now] range matches all three")
  }

  func appendWalletHeaderFixtures(into lines: inout [String]) {
    let fixtures = UITestFixtures.WalletHeaderSyncError.self
    lines.append("# fixtures — crypto wallet with a seeded sync error")
    lines.append("profile.id       = \(fixtures.profileId)")
    lines.append("profile.label    = \(fixtures.profileLabel)")
    lines.append("profile.currency = \(fixtures.profileCurrencyCode)")
    lines.append("wallet.id        = \(fixtures.walletAccountId)")
    lines.append("wallet.name      = \(fixtures.walletAccountName)")
    lines.append("wallet.address   = \(fixtures.walletAddress)")
    lines.append("wallet.chainId   = \(fixtures.walletChainId)")
    lines.append("# wallet_sync_state: seeded WalletSyncError.network, lastSyncedAt=.distantPast")
  }

  func appendPendingWebImportFixtures(into lines: inout [String]) {
    let fixtures = UITestFixtures.PendingWebImportOneChaseInbox.self
    lines.append("# fixtures — tradeBaseline profile + one pre-written inbox payload")
    lines.append("payload.id        = \(fixtures.payloadId)")
    lines.append("payload.sourceHost = \(fixtures.sourceHost)")
    lines.append("payload.sourceURL  = \(fixtures.sourceURL)")
    lines.append("payload.accountHint = \(fixtures.accountHint)")
    lines.append("payload.currencyHint = \(fixtures.currencyHint)")
    lines.append("payload.capturedAt = \(fixtures.capturedAt)")
    lines.append("expected.banner.label = \(fixtures.expectedBannerText)")
  }

  func appendAccountDetailLayoutFixtures(into lines: inout [String]) {
    let fixtures = UITestFixtures.AccountDetailLayout.self
    lines.append("# fixtures — two bank accounts: multi-currency (AUD+USD) + fiat-only (AUD)")
    lines.append("profile.id       = \(fixtures.profileId)")
    lines.append("profile.label    = \(fixtures.profileLabel)")
    lines.append("profile.currency = \(fixtures.profileCurrencyCode)")
    lines.append(
      "multiCurrency.id/name = \(fixtures.multiCurrencyAccountId) "
        + "/ \(fixtures.multiCurrencyAccountName) (AUD host + USD position)")
    lines.append(
      "everyday.id/name      = \(fixtures.everydayAccountId) "
        + "/ \(fixtures.everydayAccountName) (AUD-only)")
    lines.append(
      "multiCurrency.txn1.id/payee/date = \(fixtures.multiCurrencyTxn1Id) "
        + "/ \(fixtures.multiCurrencyTxn1Payee) / \(fixtures.multiCurrencyTxn1Date)")
    lines.append(
      "multiCurrency.txn2.id/payee/date = \(fixtures.multiCurrencyTxn2Id) "
        + "/ \(fixtures.multiCurrencyTxn2Payee) / \(fixtures.multiCurrencyTxn2Date)")
    lines.append(
      "multiCurrency.txn3.id/payee/date = \(fixtures.multiCurrencyTxn3Id) "
        + "/ \(fixtures.multiCurrencyTxn3Payee) / \(fixtures.multiCurrencyTxn3Date) "
        + "(USD income — creates non-host position)")
    lines.append(
      "everyday.txn1.id/payee/date = \(fixtures.everydayTxn1Id) "
        + "/ \(fixtures.everydayTxn1Payee) / \(fixtures.everydayTxn1Date)")
    lines.append(
      "everyday.txn2.id/payee/date = \(fixtures.everydayTxn2Id) "
        + "/ \(fixtures.everydayTxn2Payee) / \(fixtures.everydayTxn2Date)")
    lines.append(
      "everyday.txn3.id/payee/date = \(fixtures.everydayTxn3Id) "
        + "/ \(fixtures.everydayTxn3Payee) / \(fixtures.everydayTxn3Date)")
  }
}
