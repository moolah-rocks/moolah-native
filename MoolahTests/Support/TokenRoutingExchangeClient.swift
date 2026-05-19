import Foundation

@testable import Moolah

/// `ExchangeClient` that routes a scripted row list per account token,
/// so one registered `CoinstashSyncSource` can drive several exchange
/// accounts with independently controlled `externalId`s through the
/// real build → apply → detection pipeline. An account whose token maps
/// to an empty list (or is absent) syncs successfully but persists
/// nothing — the apply pass returns an empty survivor set.
struct TokenRoutingExchangeClient: ExchangeClient, Sendable {
  let rowsByToken: [String: [ExchangeImportedTransaction]]

  func fetchTransactions(
    token: String
  ) async throws -> [ExchangeImportedTransaction] {
    rowsByToken[token] ?? []
  }
}
