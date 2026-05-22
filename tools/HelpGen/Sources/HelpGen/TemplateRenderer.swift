import Foundation

enum TemplateRenderer {
  enum RenderError: Error, CustomStringConvertible {
    case unknownToken(String)

    var description: String {
      switch self {
      case .unknownToken(let name):
        return "Unknown template token: {{\(name)}}"
      }
    }
  }

  /// Replaces every `{{name}}` occurrence in `template` with `tokens[name]`.
  /// Throws `unknownToken` if the template references a key that is not in `tokens`.
  static func render(template: String, tokens: [String: String]) throws -> String {
    var output = ""
    output.reserveCapacity(template.count)
    var cursor = template.startIndex
    while let openRange = template.range(of: "{{", range: cursor..<template.endIndex) {
      output.append(contentsOf: template[cursor..<openRange.lowerBound])
      guard
        let closeRange = template.range(
          of: "}}", range: openRange.upperBound..<template.endIndex
        )
      else {
        output.append(contentsOf: template[openRange.lowerBound..<template.endIndex])
        cursor = template.endIndex
        break
      }
      let name = String(template[openRange.upperBound..<closeRange.lowerBound])
        .trimmingCharacters(in: .whitespaces)
      guard let value = tokens[name] else {
        throw RenderError.unknownToken(name)
      }
      output.append(value)
      cursor = closeRange.upperBound
    }
    output.append(contentsOf: template[cursor..<template.endIndex])
    return output
  }
}
