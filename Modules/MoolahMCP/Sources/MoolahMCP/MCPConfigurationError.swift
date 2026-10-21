/// Local endpoint settings failed validation; no listener is started.
public enum MCPConfigurationError: Error {
  /// Port or browser-origin configuration is unsafe or malformed.
  case invalidEndpoint
  /// Tool registration is duplicated or outside the read-only catalogue.
  case invalidTool
}
