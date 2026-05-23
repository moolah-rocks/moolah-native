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

    let toc = TOCRenderer.renderHTML(toc: inputs.toc, excludingSlug: inputs.accessPageSlug)

    // Per-topic HTML pages wrapped in the help-book shell. Inputs.load
    // guarantees every TOC slug has a corresponding body in inputs.topics.
    for entry in inputs.toc.entries {
      let isAccessPage = entry.slug == inputs.accessPageSlug
      // The access page's `AppleTitle` must match `CFBundleHelpBookName` in
      // the main app's Info.plist — that's how `helpd` resolves "show the
      // book for this app". Every other page carries its own per-page
      // AppleTitle, used for breadcrumbs and search results.
      let appleTitle = isAccessPage ? inputs.bookTitle : entry.title

      // Pre-process body for the access page so the `{{toc}}` token in
      // welcome.html expands to the hierarchical nav. Other pages don't
      // contain the token, so this render is a no-op for them.
      let body = try TemplateRenderer.render(
        template: inputs.topics[entry.slug]!,
        tokens: ["toc": isAccessPage ? toc : ""]
      )

      let rendered = try TemplateRenderer.render(
        template: inputs.helpBookShell,
        tokens: [
          "title": entry.title,
          "appleTitle": appleTitle,
          "body": body,
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
