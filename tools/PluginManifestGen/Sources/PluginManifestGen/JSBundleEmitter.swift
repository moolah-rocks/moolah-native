import Foundation

/// Concatenates the hand-maintained `extension-entry.js` dispatcher with any
/// shared helper scripts (`Plugins/_shared/*.js`) and each plugin's
/// `parser.js`, replacing the placeholder `const plugins = {};` declaration
/// with a host → plugin-class map. Safari loads the resulting bundle as the
/// action extension's single `NSExtensionJavaScriptPreprocessingFile`.
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

  public static func emit(
    entry: String,
    sharedScripts: [String] = [],
    parsers: [Parser]
  ) -> String {
    let unique = deduplicate(parsers)
    let replacement: String
    if unique.isEmpty {
      // Leave the placeholder verbatim — keeps the bundle byte-stable when
      // there are no plugins and avoids `{  }` (literal-empty-braces with
      // padding) appearing in the diff.
      replacement = "const plugins = {};"
    } else {
      let map = unique.map { #""\#($0.host)": \#($0.className)"# }
        .joined(separator: ", ")
      replacement = "const plugins = { \(map) };"
    }
    // Replace ONLY the placeholder inside the marker block — a literal
    // `replacingOccurrences(of:)` would also rewrite the same text in
    // the header comment that describes what the codegen does, leaving
    // a misleading documentation diff.
    let markerStart = "/* GENERATED-PLUGIN-MAP-START */"
    let markerEnd = "/* GENERATED-PLUGIN-MAP-END */"
    let dispatcher: String
    if let startRange = entry.range(of: markerStart),
      let endRange = entry.range(of: markerEnd, range: startRange.upperBound..<entry.endIndex)
    {
      var rewritten = entry
      rewritten.replaceSubrange(
        startRange.upperBound..<endRange.lowerBound,
        with: "\n    \(replacement)\n    ")
      dispatcher = rewritten
    } else {
      // Defensive fallback — the markers are required, but if they're
      // missing, fall back to a one-off replacement of the placeholder
      // so we don't silently emit an unrewritten bundle.
      if let range = entry.range(of: "const plugins = {};") {
        var rewritten = entry
        rewritten.replaceSubrange(range, with: replacement)
        dispatcher = rewritten
      } else {
        dispatcher = entry
      }
    }
    let appendedParsers = unique.map { $0.source }.joined(separator: "\n\n")
    let appendedShared = sharedScripts.joined(separator: "\n\n")
    var parts: [String] = [dispatcher]
    if !appendedShared.isEmpty { parts.append(appendedShared) }
    if !appendedParsers.isEmpty { parts.append(appendedParsers) }
    return parts.joined(separator: "\n\n")
  }

  /// Two manifest rows are allowed to point at the same parser `file` (and
  /// therefore the same host + class) — e.g. Amex `/dashboard` and
  /// `/activity` both map to one parser via different `pathPrefix`es. Emit
  /// each (host, className) only once in the map and append each source
  /// only once, preserving manifest order for the first occurrence.
  private static func deduplicate(_ parsers: [Parser]) -> [Parser] {
    var seen = Set<String>()
    var result: [Parser] = []
    for p in parsers {
      let key = "\(p.host)|\(p.className)"
      if seen.insert(key).inserted {
        result.append(p)
      }
    }
    return result
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
