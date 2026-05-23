import Foundation

enum WebWriter {
  /// Writes the web copy at `webDir` (typically `site/help/`). Removes any
  /// pre-existing tree at that path first.
  static func write(inputs: Inputs, webDir: URL) throws {
    let fm = FileManager.default
    if fm.fileExists(atPath: webDir.path) {
      try fm.removeItem(at: webDir)
    }
    try fm.createDirectory(at: webDir, withIntermediateDirectories: true)

    let toc = TOCRenderer.renderHTML(toc: inputs.toc, excludingSlug: inputs.accessPageSlug)

    // Per-topic HTML pages wrapped in the web shell. Inputs.load guarantees
    // every TOC slug has a corresponding body in inputs.topics.
    for entry in inputs.toc.entries {
      let isAccessPage = entry.slug == inputs.accessPageSlug

      let body = try TemplateRenderer.render(
        template: inputs.topics[entry.slug]!,
        tokens: ["toc": isAccessPage ? toc : ""]
      )

      let rendered = try TemplateRenderer.render(
        template: inputs.webShell,
        tokens: [
          "title": entry.title,
          "body": body,
        ]
      )
      let fileName = isAccessPage ? "index.html" : "\(entry.slug).html"
      try rendered.write(
        to: webDir.appendingPathComponent(fileName),
        atomically: true, encoding: .utf8)
    }

    // Stylesheet.
    try inputs.webCSS.write(
      to: webDir.appendingPathComponent("styles.css"),
      atomically: true, encoding: .utf8)
  }
}
