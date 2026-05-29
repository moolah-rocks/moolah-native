import Foundation

/// Single constant for the "Check for Updates" button. Until the app is
/// listed publicly on the App Store this resolves to GitHub Releases;
/// swap the URL when a public listing exists.
enum AppStoreURL {
  // Compile-time-constant HTTPS URL: parse failure here is a programming
  // error, not a runtime condition. Force-unwrap is the idiomatic shape
  // for this case; any typo lands on the first call site in development.
  static let update = URL(
    string: "https://github.com/moolah-rocks/moolah-native/releases/latest")!  // swiftlint:disable:this force_unwrapping
}
