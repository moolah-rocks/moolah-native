import Foundation

protocol AccountRepository: Sendable {
  func fetchAll() async throws -> [Account]
  /// Reactive observation surface. Emits the full account list once
  /// immediately with the current DB contents, then re-emits whenever
  /// the underlying tables change (`account`, `transaction_leg`,
  /// `instrument`). Backed by GRDB's `ValueObservation` with
  /// `removeDuplicates()` so identical snapshots are coalesced.
  ///
  /// Errors are surfaced out-of-band on `observeErrors()` — the value
  /// stream itself is non-throwing so views can subscribe with
  /// `for await` and never crash on a transient SQLite condition.
  func observeAll() -> AsyncStream<[Account]>
  /// Companion error stream for `observeAll()`. A healthy observation
  /// stays quiet here for its lifetime; a programmer-bug or
  /// non-recoverable I/O error from the underlying observation is
  /// yielded once and then the stream completes. Stores typically
  /// surface this to a banner / log path.
  func observeErrors() -> AsyncStream<any Error>
  func create(_ account: Account, openingBalance: InstrumentAmount?) async throws -> Account
  func update(_ account: Account) async throws -> Account
  func delete(id: UUID) async throws
}

extension AccountRepository {
  func create(_ account: Account) async throws -> Account {
    try await create(account, openingBalance: nil)
  }
}
