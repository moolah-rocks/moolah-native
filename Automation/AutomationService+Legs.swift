import Foundation

// Leg-editing operations for `AutomationService`: append a leg to an existing
// transaction, edit one leg in place, or drop a leg. Every other leg is
// re-saved exactly as it was read — including its `externalId` and
// `counterpartyAddress` — so a sync-owned leg survives the edit and is not
// re-imported as a duplicate on the next sync. This lets a script assemble
// arbitrary multi-leg (and cross-currency) transactions around legs the
// wallet / exchange importers own. All members are `@MainActor` via the
// containing class.
extension AutomationService {

  /// Describes the new leg to append in `addLeg(profileIdentifier:transactionId:draft:)`.
  /// `instrumentId` omitted (`nil`) defaults to the profile's instrument; an
  /// omitted `categoryName` / `earmarkName` leaves that field unset.
  struct LegDraft: Sendable {
    let accountName: String
    let instrumentId: String?
    let amount: Decimal
    let type: String
    let categoryName: String?
    let earmarkName: String?

    init(
      accountName: String,
      instrumentId: String? = nil,
      amount: Decimal,
      type: String,
      categoryName: String? = nil,
      earmarkName: String? = nil
    ) {
      self.accountName = accountName
      self.instrumentId = instrumentId
      self.amount = amount
      self.type = type
      self.categoryName = categoryName
      self.earmarkName = earmarkName
    }
  }

  /// Describes a partial edit to one leg in
  /// `updateLeg(profileIdentifier:legId:changes:)`. Every field is optional;
  /// a `nil` field keeps the leg's current value.
  struct LegChanges: Sendable {
    let type: String?
    let accountName: String?
    let instrumentId: String?
    let amount: Decimal?
    let categoryName: String?
    let earmarkName: String?

    init(
      type: String? = nil,
      accountName: String? = nil,
      instrumentId: String? = nil,
      amount: Decimal? = nil,
      categoryName: String? = nil,
      earmarkName: String? = nil
    ) {
      self.type = type
      self.accountName = accountName
      self.instrumentId = instrumentId
      self.amount = amount
      self.categoryName = categoryName
      self.earmarkName = earmarkName
    }
  }

  /// Appends a new leg to the transaction identified by `transactionId`.
  ///
  /// The account is resolved by name; the instrument from `draft.instrumentId`
  /// (defaulting to the profile's instrument when omitted); the type from a
  /// `TransactionType` raw value; the optional category / earmark by name.
  /// All existing legs are carried through unchanged so their `externalId` /
  /// `counterpartyAddress` survive (the whole point — a sync-owned leg must
  /// not be re-imported), then the transaction is re-saved by id.
  func addLeg(
    profileIdentifier: String,
    transactionId: UUID,
    draft: LegDraft
  ) async throws -> Transaction {
    let session = try resolveSession(for: profileIdentifier)
    let transaction = try await Self.transaction(id: transactionId, in: session)

    let account = try await resolveAccount(
      named: draft.accountName, profileIdentifier: profileIdentifier)
    let instrument = try await resolveInstrument(draft.instrumentId, session: session)
    let legType = try Self.transactionType(draft.type)
    let categoryId = try resolveOptionalCategory(
      draft.categoryName, profileIdentifier: profileIdentifier)
    let earmarkId = try resolveOptionalEarmark(
      draft.earmarkName, profileIdentifier: profileIdentifier)

    let newLeg = TransactionLeg(
      accountId: account.id,
      instrument: instrument,
      quantity: draft.amount,
      type: legType,
      categoryId: categoryId,
      earmarkId: earmarkId)

    // Keep every existing leg verbatim (id / externalId / counterpartyAddress
    // intact) and append the new manual leg, which carries no externalId.
    var updated = transaction
    updated.legs.append(newLeg)
    return try await save(updated, session: session)
  }

  /// Edits one leg in place, identified by `legId`. Every supplied field in
  /// `changes` is applied; omitted (`nil`) fields keep their current value.
  /// The leg's `id`, `externalId`, and `counterpartyAddress` are always
  /// preserved, as are all other legs. Throws when no transaction contains a
  /// leg with `legId`.
  func updateLeg(
    profileIdentifier: String,
    legId: UUID,
    changes: LegChanges
  ) async throws -> Transaction {
    let session = try resolveSession(for: profileIdentifier)
    let located = try await Self.locateLeg(legId: legId, in: session)

    let resolvedAccountId: UUID? =
      if let accountName = changes.accountName {
        try await resolveAccount(named: accountName, profileIdentifier: profileIdentifier).id
      } else {
        located.leg.accountId
      }
    let resolvedInstrument: Instrument =
      if let instrumentId = changes.instrumentId {
        try await resolveInstrument(instrumentId, session: session)
      } else {
        located.leg.instrument
      }
    let resolvedType: TransactionType =
      if let type = changes.type { try Self.transactionType(type) } else { located.leg.type }
    let resolvedCategoryId: UUID? =
      try resolveOptionalCategory(changes.categoryName, profileIdentifier: profileIdentifier)
      ?? located.leg.categoryId
    let resolvedEarmarkId: UUID? =
      try resolveOptionalEarmark(changes.earmarkName, profileIdentifier: profileIdentifier)
      ?? located.leg.earmarkId

    // Rebuild the leg keeping id / externalId / counterpartyAddress.
    let edited = TransactionLeg(
      id: located.leg.id,
      accountId: resolvedAccountId,
      instrument: resolvedInstrument,
      quantity: changes.amount ?? located.leg.quantity,
      externalId: located.leg.externalId,
      counterpartyAddress: located.leg.counterpartyAddress,
      type: resolvedType,
      categoryId: resolvedCategoryId,
      earmarkId: resolvedEarmarkId)

    var updated = located.transaction
    updated.legs[located.index] = edited
    return try await save(updated, session: session)
  }

  /// Drops the leg identified by `legId` from its transaction. Throws
  /// `operationFailed` rather than silently deleting the transaction when the
  /// leg is its last — a transaction with zero legs is not a valid shape, so
  /// a script that meant to delete the transaction must do so explicitly.
  func removeLeg(profileIdentifier: String, legId: UUID) async throws -> Transaction {
    let session = try resolveSession(for: profileIdentifier)
    let located = try await Self.locateLeg(legId: legId, in: session)

    guard located.transaction.legs.count > 1 else {
      throw AutomationError.operationFailed(
        "Cannot remove the last leg of a transaction; delete the transaction instead.")
    }

    var updated = located.transaction
    updated.legs.remove(at: located.index)
    return try await save(updated, session: session)
  }

  // MARK: - Helpers

  /// Re-saves `transaction` in place via `update(_:)` — an in-place upsert
  /// that diffs legs against the persisted set by stable id, so every
  /// carried-through leg (and the header) keeps its cached
  /// `encoded_system_fields` blob and therefore its CloudKit sync identity.
  ///
  /// This is the load-bearing choice over `replace(deletingIds:creating:)`:
  /// a delete-then-insert nulls those blobs on the re-created same-id rows,
  /// and once such a row goes clean the #1085 modification-date gate fails
  /// open on the nil cache, letting a stale self-echo clobber the edit back
  /// to its previous version (the placeholder-revert data loss — issue #1090
  /// follow-up). `update` re-attaches the blobs, so the gate protects the row
  /// unconditionally. Returns the freshly persisted transaction.
  private func save(
    _ transaction: Transaction, session: ProfileSession
  ) async throws -> Transaction {
    do {
      return try await session.backend.transactions.update(transaction)
    } catch let error as AutomationError {
      throw error
    } catch {
      throw AutomationError.operationFailed(
        "Failed to save transaction: \(error.localizedDescription)")
    }
  }

  /// Authoritative by-id transaction lookup. There is no by-id fetch on the
  /// repository, so the full filtered set is fetched and searched — matching
  /// the pattern used by `mergeTransactions`.
  private static func transaction(
    id: UUID, in session: ProfileSession
  ) async throws -> Transaction {
    let all = try await session.backend.transactions.fetchAll(filter: TransactionFilter())
    guard let transaction = all.first(where: { $0.id == id }) else {
      throw AutomationError.transactionNotFound(id.uuidString)
    }
    return transaction
  }

  /// The result of finding a leg across all transactions: the owning
  /// transaction, the leg, and its index within `transaction.legs`.
  private struct LocatedLeg {
    let transaction: Transaction
    let leg: TransactionLeg
    let index: Int
  }

  /// Finds the transaction containing a leg with `legId`, throwing
  /// `transactionNotFound` when no leg matches. (No dedicated leg-not-found
  /// case exists; the leg id stands in for the missing reference.)
  private static func locateLeg(
    legId: UUID, in session: ProfileSession
  ) async throws -> LocatedLeg {
    let all = try await session.backend.transactions.fetchAll(filter: TransactionFilter())
    for transaction in all {
      if let index = transaction.legs.firstIndex(where: { $0.id == legId }) {
        return LocatedLeg(
          transaction: transaction, leg: transaction.legs[index], index: index)
      }
    }
    throw AutomationError.transactionNotFound("leg \(legId.uuidString)")
  }

  /// Parses a `TransactionType` raw value, throwing on an unknown string.
  private static func transactionType(_ raw: String) throws -> TransactionType {
    guard let type = TransactionType(rawValue: raw) else {
      let valid = TransactionType.userSelectableTypes.map(\.rawValue).joined(separator: ", ")
      throw AutomationError.invalidParameter("Unknown leg type '\(raw)'. Use: \(valid)")
    }
    return type
  }

  /// Resolves an optional category name to its id, or `nil` when unset.
  private func resolveOptionalCategory(
    _ name: String?, profileIdentifier: String
  ) throws -> UUID? {
    guard let name else { return nil }
    return try resolveCategory(named: name, profileIdentifier: profileIdentifier).id
  }

  /// Resolves an optional earmark name to its id, or `nil` when unset.
  private func resolveOptionalEarmark(
    _ name: String?, profileIdentifier: String
  ) throws -> UUID? {
    guard let name else { return nil }
    return try resolveEarmark(named: name, profileIdentifier: profileIdentifier).id
  }

  /// Resolves an `instrumentId` string to an `Instrument`.
  ///
  /// Mechanism:
  /// - `nil` → the profile's own instrument (`session.profile.instrument`).
  /// - Otherwise the instrument is looked up in the profile's instrument
  ///   registry via `all()`, which merges the database's stock / crypto rows
  ///   with the ambient fiat ISO list — so a fiat code ("AUD"), a stock id
  ///   ("ASX:BHP"), and a registered crypto id ("1:native", "1:0x…") all
  ///   resolve through the same authoritative read.
  /// - For a degraded session with no registry, a fiat-shaped id (no ":")
  ///   falls back to `Instrument.fiat(code:)`.
  /// Throws `invalidParameter` when the id cannot be resolved.
  private func resolveInstrument(
    _ instrumentId: String?, session: ProfileSession
  ) async throws -> Instrument {
    guard let instrumentId else { return session.profile.instrument }
    if instrumentId == session.profile.instrument.id { return session.profile.instrument }

    if let registry = session.instrumentRegistry {
      let all = try await registry.all()
      if let match = all.first(where: { $0.id == instrumentId }) {
        return match
      }
    }

    // Registry absent or did not carry the id. A fiat code is synthesizable
    // without the registry; anything else (a stock / crypto id) is not.
    if !instrumentId.contains(":") {
      return Instrument.fiat(code: instrumentId)
    }

    throw AutomationError.invalidParameter(
      "Unknown instrument id '\(instrumentId)'. Use a fiat code (e.g. AUD), "
        + "a stock id (EXCHANGE:TICKER), or a registered crypto id (chainId:address).")
  }
}
