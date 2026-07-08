import Foundation

enum CategoryNameValidation {
  static func normalized(_ name: String) -> String {
    name.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func isBlank(_ name: String) -> Bool {
    normalized(name).isEmpty
  }
}
