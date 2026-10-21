import Foundation

/// Bound SQL parameters still interpret LIKE wildcards. Escape literal user input before
/// adding the caller's intentional prefix/contains wildcard; pair with SQL ESCAPE '\'.
enum GRDBLikePattern {
  static func escapedLiteral(_ value: String) -> String {
    value.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "%", with: "\\%")
      .replacingOccurrences(of: "_", with: "\\_")
  }
}
