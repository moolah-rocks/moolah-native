// MoolahTests/Domain/Models/CryptoInstrumentIDTests.swift
import Foundation
import Testing

@testable import Moolah

@Suite("CryptoInstrumentID")
struct CryptoInstrumentIDTests {
  @Test("chainId parses the prefix")
  func chainIdParses() {
    #expect(CryptoInstrumentID.chainId(from: "1:native") == 1)
    #expect(CryptoInstrumentID.chainId(from: "8453:0xabc") == 8453)
    #expect(CryptoInstrumentID.chainId(from: "notacrypto") == nil)
  }

  @Test("contractAddress is nil for native, else the suffix")
  func addressParses() {
    #expect(CryptoInstrumentID.contractAddress(from: "1:native") == nil)
    #expect(CryptoInstrumentID.contractAddress(from: "1:0xABC") == "0xABC")
    #expect(CryptoInstrumentID.contractAddress(from: "nocolon") == nil)
  }
}
