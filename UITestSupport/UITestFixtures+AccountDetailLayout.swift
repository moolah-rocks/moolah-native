import Foundation

/// Parses a UUID literal used in a deterministic test seed. File-private
/// mirror of the helper in `UITestFixtures.swift` — kept local so this
/// extension file has no cross-file dependency for parsing its own
/// literals. Crashes with a clear message on a malformed literal; never
/// substitutes a random UUID (which would make failure artefacts
/// non-diffable).
private func uuidLiteral(_ string: String) -> UUID {
  guard let uuid = UUID(uuidString: string) else {
    fatalError("Malformed UUID literal in test seed: \(string)")
  }
  return uuid
}

extension UITestFixtures {
  /// Fixtures for the `.accountDetailLayout` seed.
  ///
  /// Entities (all fixed, deterministic):
  ///   - Profile `personal` — label "Personal", currency AUD, CloudKit-backed.
  ///   - Account `multiCurrency` — "Multi-Currency", bank, AUD denomination.
  ///     Holds two positions: AUD (host) and USD (non-host). The USD position
  ///     comes from a USD income leg, so
  ///     `AccountDetailLayout.hasNonHostHoldings` returns `true` and the
  ///     macOS layout pins the Positions pane above the bottom toggle.
  ///   - Account `everydayFiat` — "Everyday", bank, AUD denomination.
  ///     Only AUD-denominated legs, so `hasNonHostHoldings` returns `false`
  ///     and the macOS layout renders a single toggle pane with no Positions
  ///     surface.
  ///   - Multi-currency transactions: AUD income (opening balance), AUD
  ///     expense (supermarket), USD income (foreign transfer). The USD income
  ///     leg creates the non-host position. All three give the transaction
  ///     list and balance chart data.
  ///   - Everyday transactions: AUD income (salary), AUD expense (rent),
  ///     AUD expense (groceries). Three entries give visible history for both
  ///     the list and the chart.
  public enum AccountDetailLayout {
    public static let profileId = uuidLiteral("F1000000-0000-0000-0000-000000000001")
    public static let profileLabel = "Personal"
    public static let profileCurrencyCode = "AUD"

    // MARK: - Accounts

    /// Bank account (AUD host) with an additional USD position.
    /// Drives the pinned-positions macOS layout.
    public static let multiCurrencyAccountId = uuidLiteral("F1000000-0000-0000-0000-000000000010")
    public static let multiCurrencyAccountName = "Multi-Currency"

    /// Bank account (AUD host) with AUD-only positions.
    /// Drives the single-toggle-pane macOS layout (no Positions surface).
    public static let everydayAccountId = uuidLiteral("F1000000-0000-0000-0000-000000000011")
    public static let everydayAccountName = "Everyday"

    // MARK: - Multi-currency transactions

    /// 2026-01-01 00:00:00 UTC — opening AUD income.
    public static let multiCurrencyTxn1Id = uuidLiteral("F1000000-0000-0000-0000-000000000020")
    public static let multiCurrencyTxn1Payee = "Opening Balance"
    public static let multiCurrencyTxn1Date = Date(timeIntervalSince1970: 1_735_689_600)
    /// 1,000.00 AUD income.
    public static let multiCurrencyTxn1Cents = 100_000

    /// 2026-01-15 00:00:00 UTC — AUD expense.
    public static let multiCurrencyTxn2Id = uuidLiteral("F1000000-0000-0000-0000-000000000021")
    public static let multiCurrencyTxn2Payee = "Supermarket"
    public static let multiCurrencyTxn2Date = Date(timeIntervalSince1970: 1_736_899_200)
    /// 150.00 AUD expense.
    public static let multiCurrencyTxn2Cents = 15_000

    /// 2026-02-01 00:00:00 UTC — USD income. The USD income leg on the AUD
    /// account creates the non-host position that triggers the macOS
    /// pinned-positions layout.
    public static let multiCurrencyTxn3Id = uuidLiteral("F1000000-0000-0000-0000-000000000022")
    public static let multiCurrencyTxn3Payee = "USD Transfer In"
    public static let multiCurrencyTxn3Date = Date(timeIntervalSince1970: 1_738_368_000)
    /// 500.00 USD income.
    public static let multiCurrencyTxn3Cents = 50_000

    // MARK: - Everyday fiat transactions

    /// 2026-01-10 00:00:00 UTC — salary income.
    public static let everydayTxn1Id = uuidLiteral("F1000000-0000-0000-0000-000000000030")
    public static let everydayTxn1Payee = "Salary"
    public static let everydayTxn1Date = Date(timeIntervalSince1970: 1_736_467_200)
    /// 2,500.00 AUD income.
    public static let everydayTxn1Cents = 250_000

    /// 2026-01-20 00:00:00 UTC — rent expense.
    public static let everydayTxn2Id = uuidLiteral("F1000000-0000-0000-0000-000000000031")
    public static let everydayTxn2Payee = "Rent"
    public static let everydayTxn2Date = Date(timeIntervalSince1970: 1_737_331_200)
    /// 1,200.00 AUD expense.
    public static let everydayTxn2Cents = 120_000

    /// 2026-02-10 00:00:00 UTC — groceries expense.
    public static let everydayTxn3Id = uuidLiteral("F1000000-0000-0000-0000-000000000032")
    public static let everydayTxn3Payee = "Groceries"
    public static let everydayTxn3Date = Date(timeIntervalSince1970: 1_739_145_600)
    /// 80.00 AUD expense.
    public static let everydayTxn3Cents = 8_000
  }
}
