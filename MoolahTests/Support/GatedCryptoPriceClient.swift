import Foundation

@testable import Moolah

/// Test double that lets a test hold the first `dailyPrices` fetch open while
/// a second concurrent request arrives, so coalescing behaviour can be
/// asserted deterministically. Counts every fetch; parks fetches on a gate
/// until `openGate()` is called. Range-filters its stored prices the same way
/// the live providers do.
actor GatedCryptoPriceClient: CryptoPriceClient {
  nonisolated let syncProvider: SyncProvider

  private let prices: [String: [String: Decimal]]
  private(set) var fetchCount = 0
  private var open = false
  private var gateWaiters: [CheckedContinuation<Void, Never>] = []
  private var firstFetchObserved = false
  private var firstFetchWaiter: CheckedContinuation<Void, Never>?

  init(prices: [String: [String: Decimal]], syncProvider: SyncProvider = .coinGecko) {
    self.prices = prices
    self.syncProvider = syncProvider
  }

  /// Suspends until the first `dailyPrices` fetch has begun (and parked).
  /// Single-waiter: calling twice before the first fetch is a test bug.
  func awaitFirstFetch() async {
    if firstFetchObserved { return }
    await withCheckedContinuation { continuation in
      precondition(firstFetchWaiter == nil, "awaitFirstFetch() already pending")
      firstFetchWaiter = continuation
    }
  }

  /// Releases every parked fetch and lets all later fetches pass straight
  /// through.
  func openGate() {
    open = true
    let waiters = gateWaiters
    gateWaiters = []
    for waiter in waiters { waiter.resume() }
  }

  func dailyPrice(for mapping: CryptoProviderMapping, on date: Date) async throws -> Decimal {
    let dateString = dateFormatter.string(from: date)
    let prices = try await dailyPrices(for: mapping, in: date...date)
    guard let price = prices[dateString] else {
      throw CryptoPriceError.noPriceAvailable(tokenId: mapping.instrumentId, date: dateString)
    }
    return price
  }

  func dailyPrices(
    for mapping: CryptoProviderMapping, in range: ClosedRange<Date>
  ) async throws -> [String: Decimal] {
    fetchCount += 1
    if !firstFetchObserved {
      firstFetchObserved = true
      firstFetchWaiter?.resume()
      firstFetchWaiter = nil
    }
    if !open {
      await withCheckedContinuation { gateWaiters.append($0) }
    }
    guard let tokenPrices = prices[mapping.instrumentId] else { return [:] }
    let calendar = Calendar(identifier: .gregorian)
    var filtered: [String: Decimal] = [:]
    var current = range.lowerBound
    while current <= range.upperBound {
      let key = dateFormatter.string(from: current)
      if let price = tokenPrices[key] { filtered[key] = price }
      guard let next = calendar.date(byAdding: .day, value: 1, to: current) else { break }
      current = next
    }
    return filtered
  }

  func currentPrices(for mappings: [CryptoProviderMapping]) async throws -> [String: Decimal] {
    [:]
  }

  private let dateFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    return formatter
  }()
}
