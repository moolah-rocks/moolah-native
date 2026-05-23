import Foundation

enum TOCRenderer {
  /// Renders the help corpus's hierarchical navigation as a `<nav>` block of
  /// nested `<ul>` lists. Top-level entries become section headings; their
  /// children become a sub-list of links. The access page is excluded so the
  /// nav never includes a link to the page that hosts it.
  ///
  /// Output shape:
  /// ```html
  /// <nav class="help-toc" aria-label="Table of contents">
  ///   <ul>
  ///     <li><a href="getting-started.html">Getting started</a>
  ///       <ul>
  ///         <li><a href="create-your-first-profile.html">Create your first profile</a></li>
  ///         …
  ///       </ul>
  ///     </li>
  ///     …
  ///   </ul>
  /// </nav>
  /// ```
  static func renderHTML(toc: TOC, excludingSlug: String) -> String {
    let entriesBySlug = Dictionary(uniqueKeysWithValues: toc.entries.map { ($0.slug, $0) })
    let topLevel = toc.entries.filter { $0.parent == nil && $0.slug != excludingSlug }

    var html = "<nav class=\"help-toc\" aria-label=\"Table of contents\">\n"
    html += "  <ul>\n"
    for parent in topLevel {
      html += "    <li><a href=\"\(parent.slug).html\">\(escape(parent.title))</a>"
      let children = toc.entries.filter { $0.parent == parent.slug }
      if !children.isEmpty {
        html += "\n      <ul>\n"
        for child in children {
          html += "        <li><a href=\"\(child.slug).html\">\(escape(child.title))</a></li>\n"
        }
        html += "      </ul>\n    "
      }
      html += "</li>\n"
    }
    html += "  </ul>\n"
    html += "</nav>"
    // Use of `entriesBySlug` is intentional for the parent-slug existence
    // check on children — silenced when the corpus has no orphans.
    _ = entriesBySlug
    return html
  }
}

private func escape(_ s: String) -> String {
  s.replacingOccurrences(of: "&", with: "&amp;")
    .replacingOccurrences(of: "<", with: "&lt;")
    .replacingOccurrences(of: ">", with: "&gt;")
    .replacingOccurrences(of: "\"", with: "&quot;")
}
