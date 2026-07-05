// MoolahTests/Shared/CryptoImport/RPCHexTests.swift
import Foundation
import Testing

@testable import Moolah

/// Contract tests for `RPCHex` — the hex-quantity / address-topic
/// conversions the `eth_getLogs` pipeline (Tasks 3+) builds on. Pins the
/// exact string shapes (`0x`-prefixed, lowercased, no leading zeros for
/// quantities) and the round-trip between a 20-byte address and its
/// 32-byte zero-padded topic form.
@Suite("RPCHex")
struct RPCHexTests {
  // MARK: - hexQuantity

  @Test("hexQuantity encodes a small value with no leading zeros")
  func hexQuantityEncodesSmallValue() {
    #expect(RPCHex.hexQuantity(12) == "0xc")
  }

  @Test("hexQuantity encodes zero as 0x0")
  func hexQuantityEncodesZero() {
    #expect(RPCHex.hexQuantity(0) == "0x0")
  }

  @Test("hexQuantity encodes a large value")
  func hexQuantityEncodesLargeValue() {
    #expect(RPCHex.hexQuantity(16) == "0x10")
    #expect(RPCHex.hexQuantity(255) == "0xff")
  }

  // MARK: - parseUInt64

  @Test("parseUInt64 parses a 0x-prefixed quantity")
  func parseUInt64ParsesPrefixedQuantity() {
    #expect(RPCHex.parseUInt64("0xc") == 12)
  }

  @Test("parseUInt64 parses an odd-length hex string")
  func parseUInt64ParsesOddLengthHex() {
    #expect(RPCHex.parseUInt64("0xf") == 15)
    #expect(RPCHex.parseUInt64("0x1") == 1)
  }

  @Test("parseUInt64 parses 0x0 as zero")
  func parseUInt64ParsesZero() {
    #expect(RPCHex.parseUInt64("0x0") == 0)
  }

  @Test("parseUInt64 parses an unprefixed hex string")
  func parseUInt64ParsesUnprefixedHex() {
    #expect(RPCHex.parseUInt64("c") == 12)
  }

  @Test("parseUInt64 is case-insensitive on the 0x prefix and digits")
  func parseUInt64IsCaseInsensitive() {
    #expect(RPCHex.parseUInt64("0XFF") == 255)
  }

  @Test("parseUInt64 returns nil on malformed input")
  func parseUInt64ReturnsNilOnMalformedInput() {
    #expect(RPCHex.parseUInt64("0xzz") == nil)
    #expect(RPCHex.parseUInt64("") == nil)
    #expect(RPCHex.parseUInt64("0x") == nil)
  }

  @Test("hexQuantity and parseUInt64 round-trip")
  func hexQuantityAndParseUInt64RoundTrip() {
    for value: UInt64 in [0, 1, 12, 255, 4096, .max] {
      #expect(RPCHex.parseUInt64(RPCHex.hexQuantity(value)) == value)
    }
  }

  // MARK: - hexData

  @Test("hexData encodes 18 decimals as 0x12")
  func hexDataEncodesDecimals() {
    #expect(RPCHex.hexData(18) == "0x12")
  }

  @Test("hexData encodes zero as 0x0")
  func hexDataEncodesZero() {
    #expect(RPCHex.hexData(0) == "0x0")
  }

  // MARK: - addressTopic

  @Test("addressTopic left-pads a 20-byte address to a 32-byte topic")
  func addressTopicPadsToTopicWidth() {
    let address = "0x1234567890123456789012345678901234567890"
    let topic = RPCHex.addressTopic(address)
    #expect(topic == "0x0000000000000000000000001234567890123456789012345678901234567890")
    #expect(topic.count == 66)  // "0x" + 64 hex chars
  }

  @Test("addressTopic lowercases a mixed-case address")
  func addressTopicLowercasesInput() {
    let address = "0xABCDEF0123456789ABCDEF0123456789ABCDEF01"
    let topic = RPCHex.addressTopic(address)
    #expect(topic == "0x000000000000000000000000abcdef0123456789abcdef0123456789abcdef01")
  }

  // MARK: - addressFromTopic

  @Test("addressFromTopic extracts the last 40 hex chars as a 0x-prefixed address")
  func addressFromTopicExtractsLast40Chars() {
    let topic = "0x0000000000000000000000001234567890123456789012345678901234567890"
    #expect(RPCHex.addressFromTopic(topic) == "0x1234567890123456789012345678901234567890")
  }

  @Test("addressFromTopic lowercases mixed-case topic hex")
  func addressFromTopicLowercasesInput() {
    let topic = "0x000000000000000000000000ABCDEF0123456789ABCDEF0123456789ABCDEF01"
    #expect(RPCHex.addressFromTopic(topic) == "0xabcdef0123456789abcdef0123456789abcdef01")
  }

  // MARK: - Round-trip

  @Test("addressFromTopic(addressTopic(a)) round-trips to the lowercased address")
  func addressTopicRoundTrips() {
    let addresses = [
      "0x1234567890123456789012345678901234567890",
      "0xABCDEF0123456789ABCDEF0123456789ABCDEF01",
      "0x0000000000000000000000000000000000000000",
    ]
    for address in addresses {
      #expect(RPCHex.addressFromTopic(RPCHex.addressTopic(address)) == address.lowercased())
    }
  }
}
