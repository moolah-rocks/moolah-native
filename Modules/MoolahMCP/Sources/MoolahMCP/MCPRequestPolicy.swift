import Foundation
import MCP

/// Exact endpoint checks are independent of authentication. Forwarded headers are never trusted.
public struct MCPRequestPolicy: Sendable {
  /// Stable high port on the fixed IPv4 loopback listener.
  public let port: Int
  /// Exact browser origins allowed to call the listener; absent Origin remains allowed.
  public let allowedOrigins: Set<String>

  /// Validates settings before any socket is opened.
  /// - Parameters:
  ///   - port: A port in 1024...65535.
  ///   - allowedOrigins: Exact HTTP origins on 127.0.0.1, including their port.
  /// - Throws: `MCPConfigurationError.invalidEndpoint` for unsafe settings.
  public init(port: Int, allowedOrigins: Set<String> = []) throws {
    guard (1024...65_535).contains(port),
      allowedOrigins.allSatisfy(Self.isValidOrigin)
    else { throw MCPConfigurationError.invalidEndpoint }
    self.port = port
    self.allowedOrigins = allowedOrigins
  }

  /// Rejects an unexpected Host, unapproved Origin, or endpoint path.
  /// - Parameter request: The decoded incoming request, with duplicate headers joined.
  /// - Returns: A generic HTTP error, or nil when endpoint checks pass.
  public func rejection(for request: HTTPRequest) -> HTTPResponse? {
    guard request.header("Host") == "127.0.0.1:\(port)" else {
      return .error(statusCode: 403, .invalidRequest("Forbidden"))
    }
    if let origin = request.header("Origin"), !allowedOrigins.contains(origin) {
      return .error(statusCode: 403, .invalidRequest("Forbidden"))
    }
    guard request.path == "/mcp" else {
      return .error(statusCode: 404, .invalidRequest("Not Found"))
    }
    return nil
  }
}

extension MCPRequestPolicy {
  private static func isValidOrigin(_ value: String) -> Bool {
    guard let url = URLComponents(string: value),
      url.scheme == "http", url.host == "127.0.0.1",
      url.user == nil, url.password == nil,
      url.path.isEmpty, url.query == nil, url.fragment == nil,
      let port = url.port, (1024...65_535).contains(port)
    else { return false }
    return value == "http://127.0.0.1:\(port)"
  }
}
