// MoolahTests/Shared/CryptoImport/LiveAlchemyClientAttributionTests.swift
import Foundation
import Testing

@testable import Moolah

@Suite("LiveAlchemyClient provider attribution")
struct LiveAlchemyClientAttributionTests {
  @Test("A network failure from getAssetTransfers is attributed to .alchemy")
  func networkErrorIsAttributed() async throws {
    let client = AlchemyTestSupport.makeClient { _ in
      throw URLError(.notConnectedToInternet)
    }
    do {
      _ = try await client.getAssetTransfers(
        chain: .ethereum, walletAddress: "0xabc", fromBlock: 0)
      Issue.record("expected throw")
    } catch let error as WalletSyncError {
      #expect(error.provider == .alchemy)
    }
  }

  @Test("A network failure from getTransactionReceipt is attributed to .alchemy")
  func transactionReceiptNetworkErrorIsAttributed() async throws {
    let client = AlchemyTestSupport.makeClient { _ in
      throw URLError(.notConnectedToInternet)
    }
    do {
      _ = try await client.getTransactionReceipt(
        chain: .ethereum, hash: "0xdeadbeef")
      Issue.record("expected throw")
    } catch let error as WalletSyncError {
      #expect(error.provider == .alchemy)
    }
  }
}
