import Foundation

extension Transaction {
  /// Maps each leg produced by background sync to its source, keyed by leg id.
  /// Empty for manually-created transactions and for user-initiated CSV / bank
  /// / web imports — only wallet and exchange background sync qualify.
  ///
  /// A leg is included only when it carries an `externalId` (the importer's
  /// per-leg dedup key, set on every synced leg and `nil` on manually-added
  /// legs) *and* the transaction's import origin resolves to a
  /// `BackgroundSyncSource`. For a `.merged` cross-account transfer each side
  /// keeps its own source: an outgoing (negative-quantity) leg maps to the
  /// outgoing origin, an incoming leg to the incoming origin, falling back to
  /// whichever side resolved when only one is a background-sync source.
  func backgroundSyncedLegSources() -> [UUID: BackgroundSyncSource] {
    switch importOrigin {
    case nil:
      return [:]
    case let .single(origin):
      guard let source = BackgroundSyncSource(parserIdentifier: origin.parserIdentifier)
      else { return [:] }
      return syncedLegMap { _ in source }
    case let .merged(merged):
      let outgoing = merged.outgoing.flatMap {
        BackgroundSyncSource(parserIdentifier: $0.parserIdentifier)
      }
      let incoming = merged.incoming.flatMap {
        BackgroundSyncSource(parserIdentifier: $0.parserIdentifier)
      }
      guard outgoing != nil || incoming != nil else { return [:] }
      return syncedLegMap { leg in
        (leg.quantity < 0 ? outgoing : incoming) ?? outgoing ?? incoming
      }
    }
  }
}

extension Transaction {
  /// Builds the leg-id → source map over legs that carry an `externalId`,
  /// resolving each leg's source via `source`. Legs whose `source` returns
  /// `nil` are omitted.
  private func syncedLegMap(
    _ source: (TransactionLeg) -> BackgroundSyncSource?
  ) -> [UUID: BackgroundSyncSource] {
    var result: [UUID: BackgroundSyncSource] = [:]
    for leg in legs where leg.externalId != nil {
      if let resolved = source(leg) {
        result[leg.id] = resolved
      }
    }
    return result
  }
}
