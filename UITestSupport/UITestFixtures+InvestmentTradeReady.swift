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
  /// Fixtures for the `.investmentTradeReady` seed.
  ///
  /// Entities (all fixed, deterministic):
  ///   - Profile `personal` — label "Personal", currency AUD, CloudKit-backed.
  ///   - Account `portfolio` — "Portfolio", **investment**, AUD denomination,
  ///     `valuationMode = .calculatedFromTrades`. Two buy trade transactions
  ///     produce a net 30 VGS.AX position (non-host holding), which
  ///     triggers both the Increment-4
  ///     `AccountDetailView(alwaysShowsFullSurface: true)` routing and the
  ///     macOS pinned-positions layout (`hasNonHostHoldings == true`).
  ///   - Instrument `vgsax` — VGS.AX stock on ASX (same values as `TradeReady`);
  ///     registered in the shared profile-index instrument registry.
  ///   - Transaction `trade1` — 14-Apr-26 buy: −$300 AUD → +20 VGS.AX.
  ///   - Transaction `trade2` — 21-Apr-26 buy: −$160 AUD → +10 VGS.AX.
  ///
  /// Additive — does NOT modify any existing seed. The `A4000000-…` UUID
  /// range is reserved for this seed family.
  public enum InvestmentTradeReady {
    public static let profileId = uuidLiteral("A4000000-0000-0000-0000-000000000001")
    public static let profileLabel = "Personal"
    public static let profileCurrencyCode = "AUD"

    /// `.investment` account in `.calculatedFromTrades` mode. Two buy trades
    /// produce a net 30 VGS.AX position so `hasNonHostHoldings == true`
    /// triggers the macOS pinned-positions layout.
    public static let portfolioAccountId = uuidLiteral("A4000000-0000-0000-0000-000000000010")
    public static let portfolioAccountName = "Portfolio"

    /// VGS.AX instrument — same ticker/exchange/name as `TradeReady`; registered
    /// separately so this seed is self-contained and non-breaking.
    public static let vgsaxInstrumentId = "ASX:VGS.AX"
    public static let vgsaxTicker = "VGS.AX"
    public static let vgsaxExchange = "ASX"
    public static let vgsaxName = "VGS"

    // MARK: - Trade transactions

    /// 14-Apr-26 buy: −$300 AUD → +20 VGS.AX.
    public static let trade1Id = uuidLiteral("A4000000-0000-0000-0000-000000000020")
    /// 21-Apr-26 buy: −$160 AUD → +10 VGS.AX.
    public static let trade2Id = uuidLiteral("A4000000-0000-0000-0000-000000000021")
  }
}
