import Foundation
import OSLog

private let logger = Logger(subsystem: "com.moolah.app", category: "AutomationService")

/// Tri-state change to an account's `isHidden` flag used by
/// `AutomationService.updateAccount(...)`. Replaces a `Bool?` so an
/// "unchanged" intent can't be confused with "set to false" at call sites
/// and keeps SwiftLint's `discouraged_optional_boolean` rule satisfied.
enum AccountHiddenChange: Sendable {
  case unchanged
  case setTo(Bool)
}

/// Describes a partial update to an account. Fields left `nil` / `.unchanged`
/// are preserved; set fields are applied.
struct AccountChanges: Sendable {
  var name: String?
  var hidden: AccountHiddenChange

  init(name: String? = nil, hidden: AccountHiddenChange = .unchanged) {
    self.name = name
    self.hidden = hidden
  }
}

@MainActor
final class AutomationService {
  let sessionManager: SessionManager

  init(sessionManager: SessionManager) {
    self.sessionManager = sessionManager
  }

  /// Resolves a profile session by UUID string or case-insensitive name.
  func resolveSession(for identifier: String) throws -> ProfileSession {
    if let uuid = UUID(uuidString: identifier),
      let session = sessionManager.session(forID: uuid)
    {
      return session
    }

    let lowered = identifier.lowercased()
    let matches = sessionManager.openProfiles.filter {
      $0.profile.label.lowercased() == lowered
    }
    guard let session = matches.first else {
      throw AutomationError.profileNotFound(identifier)
    }
    guard matches.count == 1 else {
      throw AutomationError.invalidParameter(
        "Ambiguous profile name '\(identifier)'; use profile id.")
    }
    return session
  }

  /// Returns all currently open profiles.
  func listOpenProfiles() -> [Profile] {
    sessionManager.openProfiles.map(\.profile)
  }

}
