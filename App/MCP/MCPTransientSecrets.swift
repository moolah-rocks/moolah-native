import Foundation
import MoolahMCP
import Synchronization

/// Test-host and preview composition cannot read or mutate the device's real Keychain.
final class MCPTransientSecrets: Sendable {
  private let data = Mutex<Data?>(nil)
}

extension MCPTransientSecrets: MCPSecretPersisting {
  func readData() throws -> Data? { data.withLock { $0 } }
  func writeData(_ value: Data) throws { data.withLock { $0 = value } }
}
