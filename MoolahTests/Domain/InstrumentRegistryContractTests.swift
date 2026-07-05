import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("InstrumentRegistryRepository — Contract")
@MainActor
struct InstrumentRegistryContractTests {
  // Test fixture: builds an in-memory GRDBInstrumentRegistryRepository
  // with captured sync-queue hooks, matching the public init signature.
  @MainActor
  final class HookCapture {
    var changedIds: [String] = []
    var deletedIds: [String] = []
  }

  /// Bundle returned by `makeSubject()` — a struct rather than a tuple
  /// so SwiftLint's `large_tuple` rule (max 2 members) stays clean and
  /// call sites can address fields by name.
  @MainActor
  struct Subject {
    let repo: GRDBInstrumentRegistryRepository
    let hooks: HookCapture
    let database: DatabaseQueue
  }

  @MainActor
  func makeSubject() throws -> Subject {
    // The registry's canonical store is the profile-index DB; there is
    // no per-profile `instrument` table. `subject.database` is the
    // registry's own DB, so direct `InstrumentRow` seeding observes
    // exactly what the registry reads.
    let database = try ProfileIndexDatabase.openInMemory()
    let hooks = HookCapture()
    let repo = GRDBInstrumentRegistryRepository(
      database: database,
      onRecordChanged: { [hooks] id in Task { @MainActor in hooks.changedIds.append(id) } },
      onRecordDeleted: { [hooks] id in Task { @MainActor in hooks.deletedIds.append(id) } }
    )
    return Subject(repo: repo, hooks: hooks, database: database)
  }

  @Test("all() on a fresh profile returns every ISO currency and zero non-fiat rows")
  func freshProfileIsFiatOnly() async throws {
    let repo = try makeSubject().repo
    let all = try await repo.all()
    let fiats = all.filter { $0.kind == .fiatCurrency }
    let nonFiats = all.filter { $0.kind != .fiatCurrency }
    #expect(fiats.count == Locale.Currency.isoCurrencies.count)
    #expect(nonFiats.isEmpty)
    #expect(all.contains { $0.id == "AUD" })
    #expect(all.contains { $0.id == "USD" })
  }

  @Test("registerStock makes the stock appear in all()")
  func registerStockAppears() async throws {
    let repo = try makeSubject().repo
    let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    try await repo.registerStock(bhp)
    let all = try await repo.all()
    #expect(all.contains { $0.id == "ASX:BHP.AX" })
  }

  @Test("registerCrypto round-trips all eight crypto fields + three mapping fields")
  func registerCryptoRoundTrip() async throws {
    let repo = try makeSubject().repo
    let eth = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH",
      name: "Ethereum", decimals: 18)
    let mapping = CryptoProviderMapping(
      instrumentId: eth.id,
      coingeckoId: "ethereum",
      binanceSymbol: "ETHUSDT")
    try await repo.registerCrypto(eth, mapping: mapping)

    let regs = try await repo.allCryptoRegistrations()
    let reg = try #require(regs.first { $0.id == eth.id })
    #expect(reg.instrument.chainId == 1)
    #expect(reg.instrument.contractAddress == nil)
    #expect(reg.instrument.ticker == "ETH")
    #expect(reg.instrument.name == "Ethereum")
    #expect(reg.instrument.decimals == 18)
    #expect(reg.mapping.coingeckoId == "ethereum")
    #expect(reg.mapping.binanceSymbol == "ETHUSDT")
    // Default pricingStatus on a freshly-registered crypto registration
    // is `.priced` — the existing column default in v8 plus the row
    // mapping's `?? .priced` fallback together cover the discriminated
    // distinction the spec requires (unpriced/spam vs rate-unavailable).
    #expect(reg.pricingStatus == .priced)
  }

  @Test("registerCrypto with existing id upserts the mapping")
  func registerCryptoUpserts() async throws {
    let repo = try makeSubject().repo
    let eth = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH",
      name: "Ethereum", decimals: 18)
    let first = CryptoProviderMapping(
      instrumentId: eth.id,
      coingeckoId: "ethereum", binanceSymbol: nil)
    let second = CryptoProviderMapping(
      instrumentId: eth.id,
      coingeckoId: "ethereum", binanceSymbol: "ETHUSDT")
    try await repo.registerCrypto(eth, mapping: first)
    try await repo.registerCrypto(eth, mapping: second)

    let regs = try await repo.allCryptoRegistrations()
    #expect(regs.count == 1)
    #expect(regs.first?.mapping.binanceSymbol == "ETHUSDT")
  }

  @Test("registerCrypto(forcingStatus:) inserts a new row with the forced status + mapping")
  func registerCryptoForcingStatusInserts() async throws {
    let subject = try makeSubject()
    let repo = subject.repo
    let hooks = subject.hooks
    let eth = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH",
      name: "Ethereum", decimals: 18)
    let mapping = CryptoProviderMapping(
      instrumentId: eth.id,
      coingeckoId: "ethereum", binanceSymbol: nil)

    try await repo.registerCrypto(eth, mapping: mapping, forcingStatus: .unpriced)

    let regs = try await repo.allCryptoRegistrations()
    let reg = try #require(regs.first { $0.id == eth.id })
    // The forced status must win over the column default (`.priced`),
    // and the mapping must round-trip in the same write.
    #expect(reg.pricingStatus == .unpriced)
    #expect(reg.mapping.coingeckoId == "ethereum")

    // The whole point of #895: exactly one onRecordChanged fan-out for
    // the single backing-store write — never two. The count-of-one
    // assertion below is the test of record for the issue.
    //
    // Drain pending @MainActor hops from the sync-queue hook closures.
    // Not strictly deterministic — the closure dispatches via
    // `Task { @MainActor … }`, so the 50ms is a best-effort drain, not a
    // barrier. If CI flakes, make the hooks async/awaitable so this can
    // `await` them directly rather than tightening the sleep.
    try await Task.sleep(for: .milliseconds(50))
    #expect(hooks.changedIds == [eth.id])
  }

  @Test("registerCrypto(forcingStatus:) overwrites an existing row's mapping + status in one write")
  func registerCryptoForcingStatusUpserts() async throws {
    let subject = try makeSubject()
    let repo = subject.repo
    let hooks = subject.hooks
    let eth = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH",
      name: "Ethereum", decimals: 18)
    // Seed an existing row via the plain upsert (defaults to `.priced`).
    try await repo.registerCrypto(
      eth,
      mapping: CryptoProviderMapping(
        instrumentId: eth.id, coingeckoId: "old", binanceSymbol: nil))
    try await Task.sleep(for: .milliseconds(50))
    hooks.changedIds.removeAll()

    try await repo.registerCrypto(
      eth,
      mapping: CryptoProviderMapping(
        instrumentId: eth.id, coingeckoId: "new", binanceSymbol: nil),
      forcingStatus: .spam)

    let regs = try await repo.allCryptoRegistrations()
    #expect(regs.count == 1)
    let reg = try #require(regs.first { $0.id == eth.id })
    #expect(reg.pricingStatus == .spam)
    #expect(reg.mapping.coingeckoId == "new")

    // Still exactly one fan-out for the upsert call — the stale-status
    // window the issue describes cannot exist. Not strictly
    // deterministic (see `registerCryptoForcingStatusInserts` for the
    // same @MainActor-hop drain caveat); make the hooks awaitable if CI
    // flakes here.
    try await Task.sleep(for: .milliseconds(50))
    #expect(hooks.changedIds == [eth.id])
  }

  @Test("plain registerCrypto(_:mapping:) preserves an existing row's pricingStatus")
  func registerCryptoPreservesStatusOnUpsert() async throws {
    // Load-bearing invariant: `registerCrypto(_:mapping:forcingStatus:)`
    // exists precisely because the plain overload must NOT change a
    // stored status. If a future `mergeResolvedFields` refactor started
    // writing `pricingStatus`, the discovery path's status decision
    // would silently leak into unrelated mapping-only re-registers.
    let repo = try makeSubject().repo
    let eth = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH",
      name: "Ethereum", decimals: 18)
    // Establish a non-default stored status via the forcing overload.
    try await repo.registerCrypto(
      eth,
      mapping: CryptoProviderMapping(
        instrumentId: eth.id, coingeckoId: "ethereum",
        binanceSymbol: nil),
      forcingStatus: .spam)

    // A plain mapping-only re-register must leave `.spam` intact.
    try await repo.registerCrypto(
      eth,
      mapping: CryptoProviderMapping(
        instrumentId: eth.id, coingeckoId: "ethereum",
        binanceSymbol: nil))

    let regs = try await repo.allCryptoRegistrations()
    let reg = try #require(regs.first { $0.id == eth.id })
    #expect(reg.pricingStatus == .spam)
  }

  @Test("allCryptoRegistrations skips rows whose three mapping fields are all nil")
  func allCryptoSkipsMissingMapping() async throws {
    let subject = try makeSubject()
    let repo = subject.repo
    let database = subject.database
    // Simulate an auto-inserted row: crypto kind, but no mapping fields.
    let ghost = InstrumentRow(
      id: "1:native",
      recordName: "1:native",
      kind: "cryptoToken",
      name: "Ethereum",
      decimals: 18,
      ticker: "ETH",
      exchange: nil,
      chainId: 1,
      contractAddress: nil,
      coingeckoId: nil,
      binanceSymbol: nil,
      encodedSystemFields: nil)
    try await database.write { database in
      try ghost.insert(database)
    }

    let regs = try await repo.allCryptoRegistrations()
    #expect(regs.isEmpty)
    // But it still appears in all() — it's a valid instrument, just unpriced.
    let all = try await repo.all()
    #expect(all.contains { $0.id == "1:native" && $0.kind == .cryptoToken })
  }

  @Test("remove deletes the row and is a no-op for fiat + unknown ids")
  func removeBehaviour() async throws {
    let repo = try makeSubject().repo
    let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    try await repo.registerStock(bhp)

    try await repo.remove(id: bhp.id)
    let all = try await repo.all()
    #expect(all.contains { $0.id == bhp.id } == false)

    // No-op cases: must not throw.
    try await repo.remove(id: "AUD")  // fiat id
    try await repo.remove(id: "DOES_NOT_EXIST:FOO")  // unknown id
  }

  @Test("sync-queue hook fires on registerStock / registerCrypto / remove")
  func syncHooksFire() async throws {
    let subject = try makeSubject()
    let repo = subject.repo
    let hooks = subject.hooks
    let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    try await repo.registerStock(bhp)
    let eth = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH",
      name: "Ethereum", decimals: 18)
    try await repo.registerCrypto(
      eth,
      mapping: CryptoProviderMapping(
        instrumentId: eth.id, coingeckoId: "ethereum",
        binanceSymbol: nil))
    try await repo.remove(id: bhp.id)

    // Drain pending @MainActor hops from the sync-queue hook closures. Not
    // strictly deterministic — if CI flakes, consider making the hooks
    // async/awaitable so the test can `await` them directly.
    try await Task.sleep(for: .milliseconds(50))

    #expect(hooks.changedIds == ["ASX:BHP.AX", "1:native"])
    #expect(hooks.deletedIds == ["ASX:BHP.AX"])
  }

  @Test("sync-queue hook does not fire for fiat register or unknown remove")
  func syncHooksSkipNoops() async throws {
    let subject = try makeSubject()
    let repo = subject.repo
    let hooks = subject.hooks
    // Fiat register is rejected by the type-level split — there is no
    // registerFiat. But unknown remove is a runtime no-op.
    try await repo.remove(id: "DOES_NOT_EXIST:FOO")
    // Drain pending @MainActor hops from the sync-queue hook closures. Not
    // strictly deterministic — if CI flakes, consider making the hooks
    // async/awaitable so the test can `await` them directly.
    try await Task.sleep(for: .milliseconds(50))
    #expect(hooks.changedIds.isEmpty)
    #expect(hooks.deletedIds.isEmpty)
  }

  @Test("observeChanges fans out to multiple consumers")
  func observeChangesFanOut() async throws {
    let repo = try makeSubject().repo
    let streamA = repo.observeChanges()
    let streamB = repo.observeChanges()
    var iteratorA = streamA.makeAsyncIterator()
    var iteratorB = streamB.makeAsyncIterator()

    let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    Task { try? await repo.registerStock(bhp) }

    _ = await iteratorA.next()
    _ = await iteratorB.next()
    // If both iterators advanced we know both got a yield.
  }

  @Test("cancelled observeChanges consumer does not block sibling consumers")
  func observeChangesCancellation() async throws {
    let repo = try makeSubject().repo
    let alive = repo.observeChanges()
    var aliveIterator = alive.makeAsyncIterator()

    let cancelTask = Task {
      var dropped = repo.observeChanges().makeAsyncIterator()
      _ = await dropped.next()
    }
    cancelTask.cancel()

    let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    Task { try? await repo.registerStock(bhp) }

    _ = await aliveIterator.next()  // would hang if the cancelled consumer
    // blocked the fan-out.
  }
}
