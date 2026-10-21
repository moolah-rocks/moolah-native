import CryptoKit
import Foundation
import Security

enum MCPSecureBytes {
  static func random(count: Int) throws -> Data {
    var bytes = [UInt8](repeating: 0, count: count)
    guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else {
      throw MCPStorageFailure.unavailable
    }
    return Data(bytes)
  }

  static func verifier(_ token: String) -> Data {
    Data(SHA256.hash(data: Data(token.utf8)))
  }

  static func equal(_ first: Data, _ second: Data) -> Bool {
    guard first.count == second.count else { return false }
    var difference: UInt8 = 0
    for (left, right) in zip(first, second) { difference |= left ^ right }
    return difference == 0
  }

  static func encoded(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
  }

  static func decoded(_ string: String) -> Data? {
    guard
      string.utf8.allSatisfy({
        (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
          || $0 == 45 || $0 == 95
      })
    else { return nil }
    let normalized = string.replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    let padding = String(repeating: "=", count: (4 - normalized.count % 4) % 4)
    guard let result = Data(base64Encoded: normalized + padding), encoded(result) == string else {
      return nil
    }
    return result
  }
}
