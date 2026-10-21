import Foundation
import MoolahMCP
import Synchronization

final class MCPTestSecrets: Sendable {
  private let storage = Mutex<Data?>(nil)
}

extension MCPTestSecrets: MCPSecretPersisting {
  func readData() throws -> Data? { storage.withLock { $0 } }
  func writeData(_ data: Data) throws { storage.withLock { $0 = data } }
}
