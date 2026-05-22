import Foundation

struct Inputs {
  let toc: TOC
  let topics: [String: String]  // slug -> body fragment HTML
  let helpBookShell: String
  let webShell: String
  let helpBookCSS: String
  let webCSS: String
  let metadataPlistData: Data
  let iconData: Data

  enum LoadError: Error, CustomStringConvertible {
    case missingFile(String)
    case missingTopic(String)

    var description: String {
      switch self {
      case .missingFile(let path): return "Required file is missing: \(path)"
      case .missingTopic(let slug): return "TOC references unknown topic: \(slug).html"
      }
    }
  }

  /// Loads every input file relative to `helpDir` (typically `<repo>/Help`).
  static func load(helpDir: URL) throws -> Inputs {
    let fm = FileManager.default

    func read(_ relative: String) throws -> Data {
      let url = helpDir.appendingPathComponent(relative)
      guard fm.fileExists(atPath: url.path) else {
        throw LoadError.missingFile(relative)
      }
      return try Data(contentsOf: url)
    }

    func readString(_ relative: String) throws -> String {
      String(decoding: try read(relative), as: UTF8.self)
    }

    let tocData = try read("TOC.json")
    let toc = try JSONDecoder().decode(TOC.self, from: tocData)

    var topics: [String: String] = [:]
    for entry in toc.entries {
      let relative = "Topics/\(entry.slug).html"
      let url = helpDir.appendingPathComponent(relative)
      guard fm.fileExists(atPath: url.path) else {
        throw LoadError.missingTopic(entry.slug)
      }
      topics[entry.slug] = try readString(relative)
    }

    return Inputs(
      toc: toc,
      topics: topics,
      helpBookShell: try readString("Shells/help-book.html.tmpl"),
      webShell: try readString("Shells/web.html.tmpl"),
      helpBookCSS: try readString("Styles/help-book.css"),
      webCSS: try readString("Styles/web.css"),
      metadataPlistData: try read("Metadata.plist"),
      iconData: try read("Assets/icon-32.png")
    )
  }
}
