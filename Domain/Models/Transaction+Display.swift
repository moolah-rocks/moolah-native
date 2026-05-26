import Foundation

// MARK: - Display Helpers

extension Transaction {
  /// Builds a display label for the transaction, handling transfers, earmarks, and payees.
  ///
  /// `accountContext` is the perspective from which the description is phrased.
  /// Callers derive it per-row from the selected view's `accountIds`: exactly one
  /// in-scope leg → that leg's account id; otherwise → nil. The semantics:
  /// - `accountContext == nil` → no-context style ("Transfer from A to B"),
  ///   used by scheduled / all-accounts views and by group views where the
  ///   transaction touches multiple in-scope members.
  /// - `accountContext == some` → perspective style ("Transfer to/from <other>"),
  ///   used by single-account views and by group views where the transaction
  ///   touches exactly one member.
  ///
  /// - Parameters:
  ///   - accountContext: The account perspective to phrase from (nil = no-context).
  ///   - accounts: Account lookup collection.
  ///   - earmarks: Earmark lookup collection.
  /// - Returns: A human-readable label for the transaction.
  func displayPayee(
    accountContext: UUID?, accounts: Accounts, earmarks: Earmarks
  ) -> String {
    if isTransfer {
      if isSimple, let accountContext,
        let otherLeg = legs.first(where: { $0.accountId != accountContext })
      {
        // Account-scoped view: show direction relative to the viewer
        let otherAccountName =
          otherLeg.accountId.flatMap { accounts.by(id: $0) }?.name ?? "Unknown Account"
        let viewingLeg = legs.first(where: { $0.accountId == accountContext })
        let isOutgoing = (viewingLeg?.quantity ?? 0) < 0
        let transferLabel =
          isOutgoing
          ? "Transfer to \(otherAccountName)"
          : "Transfer from \(otherAccountName)"

        if let payee, !payee.isEmpty {
          return "\(payee) (\(transferLabel))"
        }
        return transferLabel
      }

      // No account context (scheduled/upcoming): show "Transfer from A to B"
      let fromAccount = legs.first(where: { $0.quantity < 0 })?.accountId
      let toAccount = legs.first(where: { $0.quantity > 0 })?.accountId
      let fromName = fromAccount.flatMap { accounts.by(id: $0)?.name } ?? "Unknown"
      let toName = toAccount.flatMap { accounts.by(id: $0)?.name } ?? "Unknown"
      return "Transfer from \(fromName) to \(toName)"
    }

    if isTrade {
      // Trade-shaped transactions defer the action sentence to
      // `tradeTitleSegments(scopeReference:spamInstruments:)`, which the row's
      // `titleTextValue` joins in parentheses after the payee. Return just the
      // payee here (or empty), never the "(N sub-transactions)" custom label.
      if let payee, !payee.isEmpty { return payee }
      return ""
    }

    if !isSimple {
      if let payee, !payee.isEmpty {
        return "\(payee) (\(legs.count) sub-transactions)"
      }
      return "\(legs.count) sub-transactions"
    }

    if let payee, !payee.isEmpty {
      return payee
    }

    let earmarkIds = legs.compactMap(\.earmarkId).uniqued()
    let earmarkNames = earmarkIds.compactMap { earmarks.by(id: $0)?.name }
    if !earmarkNames.isEmpty {
      return "Earmark funds for \(earmarkNames.joined(separator: ", "))"
    }

    return ""
  }
}

// MARK: - Trade Title

extension Transaction {
  /// Builds the action sentence segments for a `.trade` row title. Returns
  /// an empty array for non-trade transactions or trades that don't have
  /// exactly two `.trade` legs.
  ///
  /// `scopeReference` is the row's reference instrument: the account's
  /// instrument when account-scoped, the earmark's instrument when
  /// earmark-scoped, otherwise the profile currency. `spamInstruments`
  /// is the set of instruments currently flagged `pricingStatus == .spam`;
  /// any leg whose instrument falls in that set is emitted as
  /// `.spamMagnitude(...)` so the renderer can swap it for the spam marker.
  func tradeTitleSegments(
    scopeReference: Instrument,
    spamInstruments: Set<Instrument>
  ) -> [TradeTitleSegment] {
    guard isTrade else { return [] }
    let tradeLegs = legs.filter { $0.type == .trade }
    guard tradeLegs.count == 2 else { return [] }
    let (legA, legB) = (tradeLegs[0], tradeLegs[1])

    let aMatches = legA.instrument == scopeReference
    let bMatches = legB.instrument == scopeReference
    if aMatches != bMatches {
      let matching = aMatches ? legA : legB
      let other = aMatches ? legB : legA
      let verb = matching.quantity < 0 ? "Bought" : "Sold"
      return [
        .literal("\(verb) "),
        magnitudeSegment(for: other, spamInstruments: spamInstruments),
      ]
    }
    let paid = legA.quantity < 0 ? legA : legB
    let received = legA.quantity < 0 ? legB : legA
    return [
      .literal("Swapped "),
      magnitudeSegment(for: paid, spamInstruments: spamInstruments),
      .literal(" for "),
      magnitudeSegment(for: received, spamInstruments: spamInstruments),
    ]
  }

  private func magnitudeSegment(
    for leg: TransactionLeg,
    spamInstruments: Set<Instrument>
  ) -> TradeTitleSegment {
    let amount = InstrumentAmount(
      quantity: abs(leg.quantity), instrument: leg.instrument)
    if spamInstruments.contains(leg.instrument) {
      return .spamMagnitude(amount)
    }
    return .magnitude(amount)
  }
}
