import Foundation

extension UserDefaults {
  /// Defaults suite scoped to the current CloudKit environment so a
  /// Development build cannot read or write state owned by a Production
  /// build (and vice versa). Production code paths inject this in place
  /// of `.standard`. Tests continue to inject their own
  /// `UserDefaults(suiteName:)` for isolation.
  ///
  /// `nonisolated(unsafe)` because `UserDefaults` itself is not declared
  /// `Sendable` by Foundation but is documented as thread-safe. The
  /// instance is initialised once at first access and never reassigned,
  /// so concurrent access is sound.
  nonisolated(unsafe) static let moolahShared: UserDefaults = makeSharedSuite(for: .resolved())

  // MARK: - Key constants

  /// Kill-switch for the on-device narration feature. Absent key is treated as
  /// `true` (default on) — check `object(forKey:) == nil` before reading to
  /// distinguish "absent" from "explicitly off".
  static let insightsNarrationEnabledKey = "insightsNarrationEnabled"

  /// Opt-in key for the weekly recap narration card. Absent key is treated as
  /// `false` (default off) — the user must explicitly enable the recap.
  static let weeklyRecapEnabledKey = "weeklyRecapEnabled"

  // MARK: - Factory

  /// Factory used by `moolahShared`. Exposed so tests can verify the
  /// suite-name format for both environments without process-level
  /// Info.plist swapping. Mirrors the `CloudKitEnvironment.resolve(from:)`
  /// pattern that `CloudKitEnvironmentTests` uses.
  static func makeSharedSuite(for env: CloudKitEnvironment) -> UserDefaults {
    let suiteName = "rocks.moolah.app.\(env.storageSubdirectory.lowercased())"
    // `UserDefaults(suiteName:)` returns `nil` only for reserved suite
    // names (e.g. literal `"Apple Global Domain"`). Neither of our
    // env-suffixed names is reserved, so the fallback is unreachable in
    // practice but keeps the return type non-optional.
    return UserDefaults(suiteName: suiteName) ?? .standard
  }
}
