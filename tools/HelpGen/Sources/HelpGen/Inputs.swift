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
  /// HPDBookTitle from Metadata.plist — the book name HelpViewer shows in its
  /// title bar and matches `CFBundleHelpBookName` in the main app's Info.plist.
  let bookTitle: String
  /// HPDBookAccessPath from Metadata.plist (e.g. `welcome.html`), reduced to
  /// the slug HelpGen uses internally (e.g. `welcome`). Identifies the access
  /// page so the TOC nav and book-title `AppleTitle` are only emitted there.
  let accessPageSlug: String

  enum LoadError: Error, CustomStringConvertible {
    case missingFile(String)
    case missingTopic(String)
    case missingMetadataKey(String)
    case accessPathNotInTOC(String)

    var description: String {
      switch self {
      case .missingFile(let path): return "Required file is missing: \(path)"
      case .missingTopic(let slug): return "TOC references unknown topic: \(slug).html"
      case .missingMetadataKey(let key):
        return "Metadata.plist is missing required key: \(key)"
      case .accessPathNotInTOC(let slug):
        return "HPDBookAccessPath refers to slug '\(slug)' which is not in TOC.json"
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

    let metadataPlistData = try read("Metadata.plist")
    let metadata =
      try PropertyListSerialization.propertyList(
        from: metadataPlistData, options: [], format: nil) as? [String: Any] ?? [:]
    guard let bookTitle = metadata["HPDBookTitle"] as? String else {
      throw LoadError.missingMetadataKey("HPDBookTitle")
    }
    guard let accessPath = metadata["HPDBookAccessPath"] as? String else {
      throw LoadError.missingMetadataKey("HPDBookAccessPath")
    }
    let accessPageSlug = (accessPath as NSString).deletingPathExtension
    guard toc.entries.contains(where: { $0.slug == accessPageSlug }) else {
      throw LoadError.accessPathNotInTOC(accessPageSlug)
    }

    return Inputs(
      toc: toc,
      topics: topics,
      helpBookShell: try readString("Shells/help-book.html.tmpl"),
      webShell: try readString("Shells/web.html.tmpl"),
      helpBookCSS: try readString("Styles/help-book.css"),
      webCSS: try readString("Styles/web.css"),
      metadataPlistData: metadataPlistData,
      iconData: try read("Assets/icon-32.png"),
      bookTitle: bookTitle,
      accessPageSlug: accessPageSlug
    )
  }
}
