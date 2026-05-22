import Foundation

enum HelpBookWriter {
  /// Writes the `.help` bundle tree at `bundleURL`. Removes any pre-existing
  /// bundle at that path first. Caller is responsible for running `hiutil`.
  static func write(inputs: Inputs, bundleURL: URL) throws {
    let fm = FileManager.default
    if fm.fileExists(atPath: bundleURL.path) {
      try fm.removeItem(at: bundleURL)
    }

    let contents = bundleURL.appendingPathComponent("Contents")
    let resources = contents.appendingPathComponent("Resources")
    let lproj = resources.appendingPathComponent("en.lproj")
    let shared = resources.appendingPathComponent("shared")
    try fm.createDirectory(at: lproj, withIntermediateDirectories: true)
    try fm.createDirectory(at: shared, withIntermediateDirectories: true)

    // Contents/Info.plist (from Metadata.plist verbatim).
    try inputs.metadataPlistData.write(
      to: contents.appendingPathComponent("Info.plist"))

    // Per-topic HTML pages wrapped in the help-book shell. Inputs.load
    // guarantees every TOC slug has a corresponding body in inputs.topics.
    for entry in inputs.toc.entries {
      let rendered = try TemplateRenderer.render(
        template: inputs.helpBookShell,
        tokens: [
          "title": entry.title,
          "body": inputs.topics[entry.slug]!,
        ]
      )
      try rendered.write(
        to: lproj.appendingPathComponent("\(entry.slug).html"),
        atomically: true, encoding: .utf8)
    }

    // Stylesheet.
    try inputs.helpBookCSS.write(
      to: lproj.appendingPathComponent("styles.css"),
      atomically: true, encoding: .utf8)

    // Help Book icon.
    try inputs.iconData.write(
      to: shared.appendingPathComponent("icon-32.png"))
  }
}
