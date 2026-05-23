import Foundation

enum WebWriter {
  /// Writes the published web copy at `webDir` (typically `site/help/`). Removes
  /// every generated `.html` and the generated `styles.css` first, then writes
  /// fresh output. The `_src/` sibling directory holding the input fragments
  /// is left untouched.
  static func write(inputs: Inputs, webDir: URL) throws {
    let fm = FileManager.default

    if fm.fileExists(atPath: webDir.path) {
      // Clear stale generated files. We can't `removeItem(at: webDir)` because
      // `_src/` lives underneath it.
      for name in try fm.contentsOfDirectory(atPath: webDir.path) {
        if name == "_src" { continue }
        try fm.removeItem(at: webDir.appendingPathComponent(name))
      }
    } else {
      try fm.createDirectory(at: webDir, withIntermediateDirectories: true)
    }

    // Per-topic HTML pages wrapped in the web shell, each carrying the same
    // hierarchical sidebar with the current page highlighted.
    for entry in inputs.toc.entries {
      let sidebar = TOCRenderer.renderHTML(
        toc: inputs.toc,
        currentSlug: entry.slug,
        accessPageSlug: inputs.accessPageSlug
      )
      let rendered = try TemplateRenderer.render(
        template: inputs.webShell,
        tokens: [
          "title": entry.title,
          "sidebar": sidebar,
          "body": inputs.topics[entry.slug]!,
        ]
      )
      let fileName = entry.slug == inputs.accessPageSlug ? "index.html" : "\(entry.slug).html"
      try rendered.write(
        to: webDir.appendingPathComponent(fileName),
        atomically: true, encoding: .utf8)
    }

    try inputs.webCSS.write(
      to: webDir.appendingPathComponent("styles.css"),
      atomically: true, encoding: .utf8)
  }
}
