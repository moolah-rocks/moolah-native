import Foundation

/// Concatenates the hand-maintained `extension-entry.js` dispatcher with each
/// plugin's `parser.js`, replacing the placeholder `const plugins = {};`
/// declaration with a host → plugin-class map. Safari loads the resulting
/// bundle as the action extension's single `NSExtensionJavaScriptPreprocessingFile`.
public enum JSBundleEmitter {
  public struct Parser {
    public let host: String
    public let className: String
    public let source: String
    public init(host: String, className: String, source: String) {
      self.host = host
      self.className = className
      self.source = source
    }
  }

  public static func emit(entry: String, parsers: [Parser]) -> String {
    let replacement: String
    if parsers.isEmpty {
      // Leave the placeholder verbatim — keeps the bundle byte-stable when
      // there are no plugins and avoids `{  }` (literal-empty-braces with
      // padding) appearing in the diff.
      replacement = "const plugins = {};"
    } else {
      let map = parsers.map { #""\#($0.host)": \#($0.className)"# }.joined(separator: ", ")
      replacement = "const plugins = { \(map) };"
    }
    let dispatcher = entry.replacingOccurrences(
      of: #"const plugins = {};"#,
      with: replacement)
    let appended = parsers.map { $0.source }.joined(separator: "\n\n")
    return dispatcher + "\n\n" + appended
  }

  /// Derives a JavaScript class name from a manifest `file` path of the form
  /// `<host>/parser.js`. The first dot-separated segment of the host is
  /// stripped of non-alphanumeric characters, capitalised, and suffixed with
  /// `Importer`. Examples:
  ///   - `chase.com/parser.js`        → `ChaseImporter`
  ///   - `commbank.com.au/parser.js`  → `CommbankImporter`
  public static func className(for file: String) -> String {
    let host = (file as NSString).deletingLastPathComponent
    let firstSegment = host.split(separator: ".").first.map(String.init) ?? "Plugin"
    let cleaned = firstSegment.filter { $0.isLetter || $0.isNumber }
    return cleaned.prefix(1).uppercased() + cleaned.dropFirst() + "Importer"
  }
}
