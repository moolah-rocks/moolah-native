import Foundation

enum TOCRenderer {
  /// Renders the help corpus's hierarchical navigation as a `<nav>` block of
  /// nested `<ul>` lists. Every entry is included; the page being rendered is
  /// marked with `aria-current="page"` so the stylesheet can highlight it.
  ///
  /// Output shape:
  /// ```html
  /// <nav class="help-toc" aria-label="Table of contents">
  ///   <ul>
  ///     <li><a href="getting-started.html">Getting started</a>
  ///       <ul>
  ///         <li><a href="create-your-first-profile.html" aria-current="page">Create your first profile</a></li>
  ///         …
  ///       </ul>
  ///     </li>
  ///     …
  ///   </ul>
  /// </nav>
  /// ```
  ///
  /// The access-page slug is rendered as `index.html` (matching `WebWriter`'s
  /// file-naming convention) so links from any page resolve correctly.
  static func renderHTML(toc: TOC, currentSlug: String, accessPageSlug: String) -> String {
    func href(for slug: String) -> String {
      slug == accessPageSlug ? "index.html" : "\(slug).html"
    }
    func current(_ slug: String) -> String {
      slug == currentSlug ? " aria-current=\"page\"" : ""
    }

    let topLevel = toc.entries.filter { $0.parent == nil }
    var html = "<nav class=\"help-toc\" aria-label=\"Table of contents\">\n"
    html += "  <ul>\n"
    for parent in topLevel {
      html +=
        "    <li><a href=\"\(href(for: parent.slug))\"\(current(parent.slug))>\(escape(parent.title))</a>"
      let children = toc.entries.filter { $0.parent == parent.slug }
      if !children.isEmpty {
        html += "\n      <ul>\n"
        for child in children {
          html +=
            "        <li><a href=\"\(href(for: child.slug))\"\(current(child.slug))>\(escape(child.title))</a></li>\n"
        }
        html += "      </ul>\n    "
      }
      html += "</li>\n"
    }
    html += "  </ul>\n"
    html += "</nav>"
    return html
  }
}

private func escape(_ s: String) -> String {
  s.replacingOccurrences(of: "&", with: "&amp;")
    .replacingOccurrences(of: "<", with: "&lt;")
    .replacingOccurrences(of: ">", with: "&gt;")
    .replacingOccurrences(of: "\"", with: "&quot;")
}
