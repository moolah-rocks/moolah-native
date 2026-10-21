import Foundation

/// Device-local preferences only; neither enablement nor port belongs in shared app defaults.
@MainActor
struct MCPServerPreferences {
  private let defaults: UserDefaults
  private let prefix = "mcp.server."

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  static func portValidationMessage(_ text: String) -> String? {
    guard let port = Int(text), (1024...65535).contains(port) else {
      return "Choose a port from 1024 to 65535."
    }
    return nil
  }

  var isEnabled: Bool {
    get { defaults.bool(forKey: prefix + "enabled") }
    nonmutating set { defaults.set(newValue, forKey: prefix + "enabled") }
  }

  var port: Int {
    get {
      guard defaults.object(forKey: prefix + "port") != nil else { return 49137 }
      return defaults.integer(forKey: prefix + "port")
    }
    nonmutating set { defaults.set(newValue, forKey: prefix + "port") }
  }
}
