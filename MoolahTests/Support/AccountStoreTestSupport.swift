import Foundation
import GRDB
import os

@testable import Moolah

/// Shared fixtures for the AccountStore test suites
/// (`AccountStoreLoadingTests`, `AccountStoreApplyDeltaTests`, etc.).
@MainActor
enum AccountStoreTestSupport {
  static func seedAccount(
    id: UUID = UUID(),
    name: String,
    type: AccountType = .bank,
    instrument: Instrument = .defaultTestInstrument,
    balance: Decimal = 0,
    position: Int = 0,
    isHidden: Bool = false,
    in database: any DatabaseWriter
  ) -> Account {
    let account = Account(
      id: id, name: name, type: type, instrument: instrument, position: position,
      isHidden: isHidden)
    let balanceAmount = InstrumentAmount(quantity: balance, instrument: instrument)
    TestBackend.seed(
      accounts: [(account: account, openingBalance: balanceAmount)],
      in: database,
      instrument: instrument)
    return account
  }
}

/// In-memory AccountRepository whose methods can be toggled to fail, letting
/// tests exercise error-handling paths without spinning up CloudKit.
///
/// Implements a minimal reactive surface so the reactive `AccountStore`
/// can subscribe via `observeAll()` and receive the current accounts
/// list on subscription plus a fresh emission after every mutation.
/// The fake accumulates subscriber continuations under a lock so a
/// single repository can fan out to multiple observers (one per
/// `AccountStore` instance).
final class FailingAccountRepository: AccountRepository, @unchecked Sendable {
  private struct State {
    var accounts: [Account]
    var continuations: [UUID: AsyncStream<[Account]>.Continuation] = [:]
  }

  private let state: OSAllocatedUnfairLock<State>
  var shouldFail = false
  var failOnUpdate = false

  init(accounts: [Account]) {
    self.state = OSAllocatedUnfairLock(initialState: State(accounts: accounts))
  }

  func fetchAll() async throws -> [Account] {
    if shouldFail { throw BackendError.networkUnavailable }
    return state.withLock { $0.accounts }
  }

  /// Reactive surface for the failing fake. Yields the current
  /// accounts on subscription, then re-yields after every mutation.
  /// Lives long enough to be torn down when the subscriber's `Task`
  /// is cancelled (`onTermination`).
  func observeAll() -> AsyncStream<[Account]> {
    AsyncStream { continuation in
      let id = UUID()
      let current = state.withLock { state -> [Account] in
        state.continuations[id] = continuation
        return state.accounts
      }
      continuation.yield(current)
      continuation.onTermination = { [weak self] _ in
        guard let self else { return }
        self.state.withLock { state in
          _ = state.continuations.removeValue(forKey: id)
        }
      }
    }
  }

  /// No-op error stream. The fake does not surface programmer-bug
  /// errors out of band; mutation failures throw from the call site.
  func observeErrors() -> AsyncStream<any Error> {
    AsyncStream { _ in }
  }

  func create(_ account: Account, openingBalance: InstrumentAmount?) async throws -> Account {
    if shouldFail { throw BackendError.networkUnavailable }
    let snapshot = state.withLock { state -> [Account] in
      state.accounts.append(account)
      return state.accounts
    }
    fanOut(snapshot)
    return account
  }

  func update(_ account: Account) async throws -> Account {
    if shouldFail || failOnUpdate { throw BackendError.networkUnavailable }
    let snapshot = state.withLock { state -> [Account] in
      if let idx = state.accounts.firstIndex(where: { $0.id == account.id }) {
        state.accounts[idx] = account
      }
      return state.accounts
    }
    fanOut(snapshot)
    return account
  }

  func delete(id: UUID) async throws {
    if shouldFail { throw BackendError.networkUnavailable }
    let snapshot = state.withLock { state -> [Account] in
      state.accounts.removeAll { $0.id == id }
      return state.accounts
    }
    fanOut(snapshot)
  }

  private func fanOut(_ snapshot: [Account]) {
    let observers = state.withLock { Array($0.continuations.values) }
    for continuation in observers {
      continuation.yield(snapshot)
    }
  }
}
