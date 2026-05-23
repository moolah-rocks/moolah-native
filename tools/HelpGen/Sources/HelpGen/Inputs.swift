import Foundation

struct Inputs {
  let toc: TOC
  let topics: [String: String]  // slug -> body fragment HTML
  let webShell: String
  let webCSS: String
  /// The slug HelpGen treats as the access / landing page (mapped to
  /// `index.html` in the web output). Always the first entry in toc.json.
  let accessPageSlug: String

  enum LoadError: Error, CustomStringConvertible {
    case missingFile(String)
    case missingTopic(String)
    case emptyTOC

    var description: String {
      switch self {
      case .missingFile(let path): return "Required file is missing: \(path)"
      case .missingTopic(let slug): return "TOC references unknown topic: \(slug).html"
      case .emptyTOC: return "toc.json has no entries"
      }
    }
  }

  /// Loads every input file relative to `srcDir` (typically `<repo>/site/help/_src`).
  static func load(srcDir: URL) throws -> Inputs {
    let fm = FileManager.default

    func read(_ relative: String) throws -> Data {
      let url = srcDir.appendingPathComponent(relative)
      guard fm.fileExists(atPath: url.path) else {
        throw LoadError.missingFile(relative)
      }
      return try Data(contentsOf: url)
    }

    func readString(_ relative: String) throws -> String {
      String(decoding: try read(relative), as: UTF8.self)
    }

    let tocData = try read("toc.json")
    let toc = try JSONDecoder().decode(TOC.self, from: tocData)
    guard let first = toc.entries.first else { throw LoadError.emptyTOC }

    var topics: [String: String] = [:]
    for entry in toc.entries {
      let relative = "topics/\(entry.slug).html"
      let url = srcDir.appendingPathComponent(relative)
      guard fm.fileExists(atPath: url.path) else {
        throw LoadError.missingTopic(entry.slug)
      }
      topics[entry.slug] = try readString(relative)
    }

    return Inputs(
      toc: toc,
      topics: topics,
      webShell: try readString("template.html.tmpl"),
      webCSS: try readString("styles.css"),
      accessPageSlug: first.slug
    )
  }
}
