import Foundation

/// Persistence seam for the per-profile "last time the weekly recap was shown"
/// date. Keyed by profile id so each profile has independent once-per-week
/// tracking (each profile has its own data set — issue #1042).
///
/// The production implementation persists to `UserDefaults.moolahShared`;
/// tests inject `InMemoryRecapLastShownStore` so there are no shared-defaults
/// side effects.
protocol RecapLastShownStoring: Sendable {
  func lastShown(forProfile profileId: UUID) -> Date?
  func setLastShown(_ date: Date, forProfile profileId: UUID)
}

/// `UserDefaults`-backed implementation of `RecapLastShownStoring`. Keys are
/// scoped by profile id: `"weeklyRecapLastShown.<profileId>"` in the
/// `moolahShared` suite so the date is shared between app and extensions and
/// is CloudKit-environment-scoped (matching the rest of `moolahShared`).
struct UserDefaultsRecapLastShownStore: Sendable {
  private static func key(for profileId: UUID) -> String {
    "weeklyRecapLastShown.\(profileId.uuidString.lowercased())"
  }
}

extension UserDefaultsRecapLastShownStore: RecapLastShownStoring {
  func lastShown(forProfile profileId: UUID) -> Date? {
    let key = Self.key(for: profileId)
    return UserDefaults.moolahShared.object(forKey: key) as? Date
  }

  func setLastShown(_ date: Date, forProfile profileId: UUID) {
    UserDefaults.moolahShared.set(date, forKey: Self.key(for: profileId))
  }
}
