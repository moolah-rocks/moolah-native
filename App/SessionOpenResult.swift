/// Carrier for the "incompatible" branch of `SessionOpenResult`.
///
/// `profileVersion` is the profile's `dataFormatVersion`; `buildVersion`
/// is `DataFormatVersion.current` at the time the gate fired. The view
/// surfaces both side-by-side to make the upgrade message concrete.
/// The human-readable app version (`CFBundleShortVersionString`) is
/// sourced separately from `AppVersion.shortVersionString` and is not
/// carried here.
struct IncompatibleProfileInfo: Equatable, Sendable {
  let profileLabel: String
  let profileVersion: Int
  let buildVersion: Int
}

/// Result of attempting to open a profile through `SessionManager`.
///
/// `.ready` carries the constructed `ProfileSession` (with its CKSyncEngine
/// zone registered). `.incompatible` is returned when
/// `profile.dataFormatVersion > DataFormatVersion.current`; no
/// `ProfileSession` is constructed and the per-profile zone is not
/// registered with `SyncCoordinator` (issue #764).
enum SessionOpenResult {
  case ready(ProfileSession)
  case cancelled
  case incompatible(IncompatibleProfileInfo)
}
