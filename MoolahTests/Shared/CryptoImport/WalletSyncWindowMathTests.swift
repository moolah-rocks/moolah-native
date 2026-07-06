// MoolahTests/Shared/CryptoImport/WalletSyncWindowMathTests.swift
import Foundation
import Testing

@testable import Moolah

/// Unit tests for `WalletSyncWindowMath` — the pure window / partition /
/// fraction helpers the windowed sync runner walks. Split from the runner
/// suite because these are total functions with no I/O, so they exercise
/// the boundary arithmetic (single-block window, exact multiples, `from >
/// head`, unparseable block numbers, fraction clamps) in isolation.
@Suite("WalletSyncWindowMath — window / partition / fraction")
struct WalletSyncWindowMathTests {
  // MARK: - windows

  @Test("Single-block range yields one [from, from] window")
  func singleBlockWindow() {
    let windows = WalletSyncWindowMath.windows(from: 100, head: 100, size: 250_000)
    #expect(windows == [WalletSyncWindow(from: 100, to: 100)])
  }

  @Test("Multi-window range splits into inclusive size-1-wide windows")
  func multiWindowSplit() {
    let windows = WalletSyncWindowMath.windows(from: 0, head: 600_000, size: 250_000)
    #expect(
      windows == [
        WalletSyncWindow(from: 0, to: 249_999),
        WalletSyncWindow(from: 250_000, to: 499_999),
        WalletSyncWindow(from: 500_000, to: 600_000),
      ])
  }

  @Test("Exact multiple ends the last window on head, no empty trailing window")
  func exactMultipleBoundary() {
    let windows = WalletSyncWindowMath.windows(from: 0, head: 499_999, size: 250_000)
    #expect(
      windows == [
        WalletSyncWindow(from: 0, to: 249_999),
        WalletSyncWindow(from: 250_000, to: 499_999),
      ])
  }

  @Test("from > head yields no windows")
  func fromAboveHeadYieldsNothing() {
    #expect(WalletSyncWindowMath.windows(from: 10, head: 5, size: 250_000).isEmpty)
  }

  @Test("A size larger than the range collapses to one window")
  func sizeLargerThanRange() {
    let windows = WalletSyncWindowMath.windows(from: 100, head: 5_000, size: 250_000)
    #expect(windows == [WalletSyncWindow(from: 100, to: 5_000)])
  }

  // MARK: - partition

  @Test("partition keeps only rows whose blockNum is in [from, to]")
  func partitionKeepsInRange() {
    let rows = [
      makeAlchemyTransfer(
        hash: "0xbelow", from: "0xa", to: "0xb", category: .erc20,
        blockNum: RPCHex.hexQuantity(99)),
      makeAlchemyTransfer(
        hash: "0xlow", from: "0xa", to: "0xb", category: .erc20,
        blockNum: RPCHex.hexQuantity(100)),
      makeAlchemyTransfer(
        hash: "0xmid", from: "0xa", to: "0xb", category: .erc20,
        blockNum: RPCHex.hexQuantity(150)),
      makeAlchemyTransfer(
        hash: "0xhigh", from: "0xa", to: "0xb", category: .erc20,
        blockNum: RPCHex.hexQuantity(200)),
      makeAlchemyTransfer(
        hash: "0xabove", from: "0xa", to: "0xb", category: .erc20,
        blockNum: RPCHex.hexQuantity(201)),
    ]
    let kept = WalletSyncWindowMath.partition(
      rows, into: WalletSyncWindow(from: 100, to: 200))
    #expect(kept.map(\.hash) == ["0xlow", "0xmid", "0xhigh"])
  }

  @Test("partition drops rows with an unparseable blockNum")
  func partitionDropsUnparseable() {
    let rows = [
      makeAlchemyTransfer(
        hash: "0xok", from: "0xa", to: "0xb", category: .erc20,
        blockNum: RPCHex.hexQuantity(150)),
      makeAlchemyTransfer(
        hash: "0xjunk", from: "0xa", to: "0xb", category: .erc20,
        blockNum: "not-a-number"),
    ]
    let kept = WalletSyncWindowMath.partition(
      rows, into: WalletSyncWindow(from: 100, to: 200))
    #expect(kept.map(\.hash) == ["0xok"])
  }

  // MARK: - fraction

  @Test("fraction is the linear position between from and head")
  func fractionMidpoint() {
    #expect(WalletSyncWindowMath.fraction(pos: 150, from: 100, head: 200) == 0.5)
  }

  @Test("fraction is 1.0 when head == from (zero-width range)")
  func fractionZeroWidthIsComplete() {
    #expect(WalletSyncWindowMath.fraction(pos: 100, from: 100, head: 100) == 1.0)
  }

  @Test("fraction clamps below 0 and above 1")
  func fractionClamps() {
    #expect(WalletSyncWindowMath.fraction(pos: 50, from: 100, head: 200) == 0.0)
    #expect(WalletSyncWindowMath.fraction(pos: 300, from: 100, head: 200) == 1.0)
  }

  @Test("fraction is 0.0 at the start of the range")
  func fractionAtStart() {
    #expect(WalletSyncWindowMath.fraction(pos: 100, from: 100, head: 200) == 0.0)
  }
}
