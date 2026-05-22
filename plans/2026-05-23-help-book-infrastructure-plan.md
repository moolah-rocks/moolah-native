# Help Book Infrastructure Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the duplicate "Moolah Help" menu entries with a working Apple Help Book that shares hand-authored HTML with a `moolah.rocks/help` web copy. Ship the build pipeline, menu wiring, and a placeholder welcome page only; comprehensive content is deferred to follow-up PRs.

**Architecture:** Shared HTML body fragments under `Help/Topics/` are wrapped by two shell templates (`Help/Shells/help-book.html.tmpl`, `Help/Shells/web.html.tmpl`) into a macOS `.help` bundle and a checked-in `site/help/` tree. A small Swift CLI (`tools/HelpGen/`) does the wrapping; change detection lives in the `justfile` using the same stamp pattern as `tools/CKDBSchemaGen`. Apple's `hiutil` indexes the bundle for HelpViewer search.

**Tech Stack:** Swift 6.0, Foundation (`Codable` for `TOC.json`, `FileManager` for I/O), Swift Testing for tool tests, XCTest/XCUITest for UI regression. xcodegen drives the Xcode project; macOS is the only host that builds the help bundle.

**Working tree:** `.claude/worktrees/fix-duplicate-help-menu/` on branch `worktree-fix-duplicate-help-menu`. All paths in this plan are relative to that worktree's root.

**Companion spec:** `plans/2026-05-23-help-book-infrastructure-design.md`. Read §4, §6 for the wiring details before starting.

---

## Section A — `tools/HelpGen` Swift CLI

### Task 1: Bootstrap the HelpGen Swift package

**Files:**
- Create: `tools/HelpGen/Package.swift`
- Create: `tools/HelpGen/Sources/HelpGen/main.swift`

- [ ] **Step 1: Create `tools/HelpGen/Package.swift`**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "HelpGen",
  platforms: [.macOS(.v13)],
  products: [
    .executable(name: "help-gen", targets: ["HelpGen"])
  ],
  targets: [
    .executableTarget(name: "HelpGen"),
    .testTarget(name: "HelpGenTests", dependencies: ["HelpGen"]),
  ]
)
```

- [ ] **Step 2: Create a stub `tools/HelpGen/Sources/HelpGen/main.swift`**

```swift
import Foundation

print("help-gen: stub — full implementation in subsequent tasks")
```

- [ ] **Step 3: Verify it builds**

Run from the worktree root:
```bash
swift build --package-path tools/HelpGen
```
Expected: `Build complete!` with no warnings.

- [ ] **Step 4: Verify it runs**

```bash
swift run --package-path tools/HelpGen help-gen
```
Expected output (single line): `help-gen: stub — full implementation in subsequent tasks`

- [ ] **Step 5: Commit**

```bash
git add tools/HelpGen/Package.swift tools/HelpGen/Sources/HelpGen/main.swift
git commit -m "feat(help-gen): bootstrap empty Swift package"
```

---

### Task 2: Add `Help/` source content (placeholder welcome page + shells + metadata)

**Files (all created):**
- `Help/TOC.json`
- `Help/Topics/welcome.html`
- `Help/Shells/help-book.html.tmpl`
- `Help/Shells/web.html.tmpl`
- `Help/Metadata.plist`
- `Help/Styles/help-book.css`
- `Help/Styles/web.css`
- `Help/Assets/icon-32.png`

- [ ] **Step 1: Create `Help/TOC.json`**

```json
{
  "version": "1",
  "entries": [
    { "slug": "welcome", "title": "Welcome to Moolah", "parent": null }
  ]
}
```

- [ ] **Step 2: Create `Help/Topics/welcome.html`**

```html
<article>
  <h1>Welcome to Moolah Help</h1>
  <p>
    Full help content is being written. Check
    <a href="https://moolah.rocks/help">moolah.rocks/help</a> for updates.
  </p>
</article>
```

- [ ] **Step 3: Create `Help/Shells/help-book.html.tmpl`**

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="AppleTitle" content="{{title}}">
  <meta name="AppleIcon" content="shared/icon-32.png">
  <title>{{title}}</title>
  <link rel="stylesheet" href="styles.css">
</head>
<body>
  {{body}}
</body>
</html>
```

- [ ] **Step 4: Create `Help/Shells/web.html.tmpl`**

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>{{title}} — moolah.rocks help</title>
  <link rel="stylesheet" href="styles.css">
</head>
<body>
  <header class="help-header">
    <a href="/" aria-label="moolah.rocks home">moolah.rocks</a>
  </header>
  <main class="help-content">
    {{body}}
  </main>
  <footer class="help-footer">
    &copy; 2026 moolah.rocks
  </footer>
</body>
</html>
```

- [ ] **Step 5: Create `Help/Metadata.plist`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleIdentifier</key>
  <string>rocks.moolah.app.help</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Moolah Help</string>
  <key>CFBundlePackageType</key>
  <string>BNDL</string>
  <key>CFBundleSignature</key>
  <string>hbwr</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>HPDBookTitle</key>
  <string>Moolah Help</string>
  <key>HPDBookAccessPath</key>
  <string>welcome.html</string>
  <key>HPDBookIconPath</key>
  <string>shared/icon-32.png</string>
  <key>HPDBookIndexPath</key>
  <string>Moolah.helpindex</string>
</dict>
</plist>
```

- [ ] **Step 6: Create `Help/Styles/help-book.css`**

```css
body {
  font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
  font-size: 14px;
  line-height: 1.5;
  color: #1d1d1f;
  max-width: 640px;
  margin: 2em auto;
  padding: 0 1em;
}

h1 { font-size: 1.5em; margin-bottom: 0.5em; }
p  { margin: 0.5em 0; }
a  { color: #0066cc; }
```

- [ ] **Step 7: Create `Help/Styles/web.css`**

```css
:root {
  font-family: "Poppins", -apple-system, sans-serif;
  color: #07102e;
  background: #ffffff;
}

body { margin: 0; padding: 0; }

.help-header,
.help-footer {
  padding: 1em 1.5em;
  font-size: 0.875em;
}

.help-header a {
  color: #07102e;
  font-weight: 700;
  text-decoration: none;
}

.help-content {
  max-width: 720px;
  margin: 2em auto;
  padding: 0 1.5em;
  line-height: 1.6;
}

.help-content h1 { font-size: 1.75em; }
.help-content a  { color: #0066cc; }
```

- [ ] **Step 8: Create `Help/Assets/icon-32.png`**

Use the existing brand icon as a 32×32 PNG. Run:
```bash
sips -z 32 32 Brand/Logo/Mark-Light.png --out Help/Assets/icon-32.png
```
(If `Brand/Logo/Mark-Light.png` does not exist, list `Brand/Logo/` and pick the closest mark/icon source PNG. `sips` is built into macOS.)

Expected: a 32×32 PNG file at `Help/Assets/icon-32.png`. Verify with:
```bash
file Help/Assets/icon-32.png
```
Expected output contains `PNG image data, 32 x 32`.

- [ ] **Step 9: Commit**

```bash
git add Help/
git commit -m "feat(help): add placeholder Help/ source tree (welcome page, shells, metadata)"
```

---

### Task 3: TOC type and decoding tests

**Files:**
- Create: `tools/HelpGen/Sources/HelpGen/TOC.swift`
- Create: `tools/HelpGen/Tests/HelpGenTests/TOCTests.swift`

- [ ] **Step 1: Write the failing tests in `tools/HelpGen/Tests/HelpGenTests/TOCTests.swift`**

```swift
import Testing
import Foundation

@testable import HelpGen

@Suite("TOC decoding")
struct TOCTests {
  @Test("decodes a single-entry TOC")
  func decodesSingleEntry() throws {
    let json = """
      {
        "version": "1",
        "entries": [
          { "slug": "welcome", "title": "Welcome to Moolah", "parent": null }
        ]
      }
      """.data(using: .utf8)!
    let toc = try JSONDecoder().decode(TOC.self, from: json)
    #expect(toc.version == "1")
    #expect(toc.entries.count == 1)
    #expect(toc.entries[0].slug == "welcome")
    #expect(toc.entries[0].title == "Welcome to Moolah")
    #expect(toc.entries[0].parent == nil)
  }

  @Test("decodes nested entries via parent")
  func decodesParent() throws {
    let json = """
      {
        "version": "1",
        "entries": [
          { "slug": "accounts", "title": "Accounts", "parent": null },
          { "slug": "creating-an-account", "title": "Creating an Account", "parent": "accounts" }
        ]
      }
      """.data(using: .utf8)!
    let toc = try JSONDecoder().decode(TOC.self, from: json)
    #expect(toc.entries[1].parent == "accounts")
  }

  @Test("rejects malformed JSON")
  func rejectsMalformed() {
    let json = #"{ "version": "1" }"#.data(using: .utf8)!
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(TOC.self, from: json)
    }
  }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
swift test --package-path tools/HelpGen
```
Expected: build failure — `Cannot find 'TOC' in scope`.

- [ ] **Step 3: Implement `tools/HelpGen/Sources/HelpGen/TOC.swift`**

```swift
import Foundation

struct TOC: Decodable {
  let version: String
  let entries: [Entry]

  struct Entry: Decodable {
    let slug: String
    let title: String
    let parent: String?
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
swift test --package-path tools/HelpGen
```
Expected: `Test Suite 'All tests' passed` with 3 tests.

- [ ] **Step 5: Commit**

```bash
git add tools/HelpGen/Sources/HelpGen/TOC.swift tools/HelpGen/Tests/HelpGenTests/TOCTests.swift
git commit -m "feat(help-gen): TOC.json Codable type and tests"
```

---

### Task 4: TemplateRenderer with tests

**Files:**
- Create: `tools/HelpGen/Sources/HelpGen/TemplateRenderer.swift`
- Create: `tools/HelpGen/Tests/HelpGenTests/TemplateRendererTests.swift`

- [ ] **Step 1: Write the failing tests in `tools/HelpGen/Tests/HelpGenTests/TemplateRendererTests.swift`**

```swift
import Testing
import Foundation

@testable import HelpGen

@Suite("TemplateRenderer")
struct TemplateRendererTests {
  @Test("substitutes a single token")
  func substitutesSingleToken() throws {
    let rendered = try TemplateRenderer.render(
      template: "Hello, {{name}}!",
      tokens: ["name": "world"]
    )
    #expect(rendered == "Hello, world!")
  }

  @Test("substitutes multiple tokens")
  func substitutesMultiple() throws {
    let rendered = try TemplateRenderer.render(
      template: "<title>{{title}}</title><body>{{body}}</body>",
      tokens: ["title": "Welcome", "body": "<p>Hi</p>"]
    )
    #expect(rendered == "<title>Welcome</title><body><p>Hi</p></body>")
  }

  @Test("substitutes the same token multiple times")
  func substitutesRepeated() throws {
    let rendered = try TemplateRenderer.render(
      template: "{{x}}-{{x}}-{{x}}",
      tokens: ["x": "a"]
    )
    #expect(rendered == "a-a-a")
  }

  @Test("throws on unknown token in template")
  func throwsOnUnknownToken() {
    #expect(throws: TemplateRenderer.RenderError.self) {
      try TemplateRenderer.render(
        template: "Hello, {{name}}!",
        tokens: [:]
      )
    }
  }

  @Test("preserves text with no tokens")
  func preservesPlainText() throws {
    let rendered = try TemplateRenderer.render(
      template: "no tokens here",
      tokens: [:]
    )
    #expect(rendered == "no tokens here")
  }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
swift test --package-path tools/HelpGen
```
Expected: build failure — `Cannot find 'TemplateRenderer' in scope`.

- [ ] **Step 3: Implement `tools/HelpGen/Sources/HelpGen/TemplateRenderer.swift`**

```swift
import Foundation

enum TemplateRenderer {
  enum RenderError: Error, CustomStringConvertible {
    case unknownToken(String)

    var description: String {
      switch self {
      case .unknownToken(let name):
        return "Unknown template token: {{\(name)}}"
      }
    }
  }

  /// Replaces every `{{name}}` occurrence in `template` with `tokens[name]`.
  /// Throws `unknownToken` if the template references a key that is not in `tokens`.
  static func render(template: String, tokens: [String: String]) throws -> String {
    var output = ""
    output.reserveCapacity(template.count)
    var cursor = template.startIndex
    while let openRange = template.range(of: "{{", range: cursor..<template.endIndex) {
      output.append(contentsOf: template[cursor..<openRange.lowerBound])
      guard let closeRange = template.range(
        of: "}}", range: openRange.upperBound..<template.endIndex
      ) else {
        output.append(contentsOf: template[openRange.lowerBound..<template.endIndex])
        cursor = template.endIndex
        break
      }
      let name = String(template[openRange.upperBound..<closeRange.lowerBound])
        .trimmingCharacters(in: .whitespaces)
      guard let value = tokens[name] else {
        throw RenderError.unknownToken(name)
      }
      output.append(value)
      cursor = closeRange.upperBound
    }
    output.append(contentsOf: template[cursor..<template.endIndex])
    return output
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
swift test --package-path tools/HelpGen
```
Expected: 8 tests pass (3 from Task 3, 5 from Task 4).

- [ ] **Step 5: Commit**

```bash
git add tools/HelpGen/Sources/HelpGen/TemplateRenderer.swift tools/HelpGen/Tests/HelpGenTests/TemplateRendererTests.swift
git commit -m "feat(help-gen): TemplateRenderer with {{token}} substitution"
```

---

### Task 5: Inputs loader

**Files:**
- Create: `tools/HelpGen/Sources/HelpGen/Inputs.swift`

(No dedicated unit tests — Task 9's integration step exercises this.)

- [ ] **Step 1: Implement `tools/HelpGen/Sources/HelpGen/Inputs.swift`**

```swift
import Foundation

struct Inputs {
  let toc: TOC
  let topics: [String: String]            // slug -> body fragment HTML
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
      case .missingFile(let path):     return "Required file is missing: \(path)"
      case .missingTopic(let slug):    return "TOC references unknown topic: \(slug).html"
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
      topics[entry.slug] = try String(contentsOf: url, encoding: .utf8)
    }

    return Inputs(
      toc: toc,
      topics: topics,
      helpBookShell: try readString("Shells/help-book.html.tmpl"),
      webShell:      try readString("Shells/web.html.tmpl"),
      helpBookCSS:   try readString("Styles/help-book.css"),
      webCSS:        try readString("Styles/web.css"),
      metadataPlistData: try read("Metadata.plist"),
      iconData:          try read("Assets/icon-32.png")
    )
  }
}
```

- [ ] **Step 2: Verify it builds**

```bash
swift build --package-path tools/HelpGen
```
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add tools/HelpGen/Sources/HelpGen/Inputs.swift
git commit -m "feat(help-gen): Inputs loader for Help/ source tree"
```

---

### Task 6: HelpBookWriter

**Files:**
- Create: `tools/HelpGen/Sources/HelpGen/HelpBookWriter.swift`

- [ ] **Step 1: Implement `tools/HelpGen/Sources/HelpGen/HelpBookWriter.swift`**

```swift
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

    // Per-topic HTML pages wrapped in the help-book shell.
    for entry in inputs.toc.entries {
      let body = inputs.topics[entry.slug] ?? ""
      let rendered = try TemplateRenderer.render(
        template: inputs.helpBookShell,
        tokens: [
          "title": entry.title,
          "body":  body,
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
```

- [ ] **Step 2: Verify it builds**

```bash
swift build --package-path tools/HelpGen
```
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add tools/HelpGen/Sources/HelpGen/HelpBookWriter.swift
git commit -m "feat(help-gen): HelpBookWriter for .help bundle tree"
```

---

### Task 7: WebWriter

**Files:**
- Create: `tools/HelpGen/Sources/HelpGen/WebWriter.swift`

- [ ] **Step 1: Implement `tools/HelpGen/Sources/HelpGen/WebWriter.swift`**

```swift
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

    // Per-topic HTML pages wrapped in the web shell.
    for entry in inputs.toc.entries {
      let body = inputs.topics[entry.slug] ?? ""
      let rendered = try TemplateRenderer.render(
        template: inputs.webShell,
        tokens: [
          "title": entry.title,
          "body":  body,
        ]
      )
      let fileName = entry.slug == "welcome" ? "index.html" : "\(entry.slug).html"
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
```

*Note:* The welcome page is written as `index.html` so `moolah.rocks/help/` resolves to it without a trailing-slash redirect.

- [ ] **Step 2: Verify it builds**

```bash
swift build --package-path tools/HelpGen
```
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add tools/HelpGen/Sources/HelpGen/WebWriter.swift
git commit -m "feat(help-gen): WebWriter for site/help/ tree"
```

---

### Task 8: Wire `main.swift`

**Files:**
- Modify: `tools/HelpGen/Sources/HelpGen/main.swift`

- [ ] **Step 1: Replace `tools/HelpGen/Sources/HelpGen/main.swift` with**

```swift
import Foundation

@main
struct HelpGenMain {
  static func main() {
    do {
      let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      let helpDir   = cwd.appendingPathComponent("Help")
      let bundleURL = cwd.appendingPathComponent("Help/Build/Moolah.help")
      let webDir    = cwd.appendingPathComponent("site/help")

      let inputs = try Inputs.load(helpDir: helpDir)
      try HelpBookWriter.write(inputs: inputs, bundleURL: bundleURL)
      try WebWriter.write(inputs: inputs, webDir: webDir)

      print(
        "help-gen: wrote \(inputs.toc.entries.count) page(s) to "
        + "\(bundleURL.path) and \(webDir.path)"
      )
    } catch {
      FileHandle.standardError.write(
        Data("help-gen: \(error)\n".utf8))
      exit(1)
    }
  }
}
```

- [ ] **Step 2: Verify it builds**

```bash
swift build --package-path tools/HelpGen
```
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add tools/HelpGen/Sources/HelpGen/main.swift
git commit -m "feat(help-gen): wire main.swift entry point"
```

---

### Task 9: Smoke test the generator end-to-end

- [ ] **Step 1: Run the generator from the worktree root**

```bash
swift run --package-path tools/HelpGen help-gen
```
Expected output (one line):
`help-gen: wrote 1 page(s) to <abs>/Help/Build/Moolah.help and <abs>/site/help`

- [ ] **Step 2: Verify the `.help` bundle contents**

```bash
find Help/Build/Moolah.help -type f | sort
```
Expected output:
```
Help/Build/Moolah.help/Contents/Info.plist
Help/Build/Moolah.help/Contents/Resources/en.lproj/styles.css
Help/Build/Moolah.help/Contents/Resources/en.lproj/welcome.html
Help/Build/Moolah.help/Contents/Resources/shared/icon-32.png
```

- [ ] **Step 3: Verify the welcome page is valid wrapped HTML**

```bash
head -3 Help/Build/Moolah.help/Contents/Resources/en.lproj/welcome.html
```
Expected first line: `<!DOCTYPE html>`. Confirm later lines contain `<meta name="AppleTitle" content="Welcome to Moolah">`.

- [ ] **Step 4: Verify the web copy was written**

```bash
find site/help -type f | sort
```
Expected output:
```
site/help/index.html
site/help/styles.css
```

- [ ] **Step 5: Verify the web copy uses the site shell**

```bash
grep -l "moolah.rocks home" site/help/index.html
```
Expected: `site/help/index.html`.

- [ ] **Step 6: Run the help indexer manually to ensure `hiutil` produces an index**

```bash
/usr/bin/hiutil -Cf \
  Help/Build/Moolah.help/Contents/Resources/en.lproj/Moolah.helpindex \
  Help/Build/Moolah.help/Contents/Resources/en.lproj
```
Expected: silent success. Verify:
```bash
ls -la Help/Build/Moolah.help/Contents/Resources/en.lproj/Moolah.helpindex
```
Expected: a file present, non-zero size.

- [ ] **Step 7: Clean up generated outputs before committing build wiring**

```bash
rm -rf Help/Build site/help
```

(Step 7 is a hygiene step — we don't want the smoke test's outputs in the next commit. The justfile recipe added in Task 11 will regenerate them.)

- [ ] **Step 8: Commit**

There is nothing to commit at this step — Task 9 was verification only. Skip the commit.

---

## Section B — Build wiring (`.gitignore`, `justfile`, `project.yml`)

### Task 10: Update `.gitignore`

**Files:**
- Modify: `.gitignore`

- [ ] **Step 1: Append a `Help/Build/` block to `.gitignore`**

Add at the end of `.gitignore`:
```
# Help Book bundle generated by tools/HelpGen from Help/ source tree.
# Regenerated by `just generate` / `just build-help`. Never edit by hand.
Help/Build/
```

- [ ] **Step 2: Verify**

```bash
git check-ignore -v Help/Build/Moolah.help
```
Expected output names `.gitignore` and the new pattern.

- [ ] **Step 3: Commit**

```bash
git add .gitignore
git commit -m "chore(gitignore): ignore generated Help/Build/ tree"
```

---

### Task 11: Add `just build-help` recipe

**Files:**
- Modify: `justfile`

- [ ] **Step 1: Insert the `build-help` recipe immediately above the existing `generate:` recipe (line ~151)**

```bash
# Regenerate the macOS Help Book bundle and the site/help/ web copy from
# the shared HTML fragments under Help/. Runs only when source files or
# the generator have changed since the last successful run.
build-help:
    #!/usr/bin/env bash
    set -euo pipefail

    STAMP_DIR=".build/stamps"
    HELP_STAMP="$STAMP_DIR/help-gen.stamp"
    mkdir -p "$STAMP_DIR"

    needs=0
    if [ ! -f "$HELP_STAMP" ]; then
        needs=1
    elif [ ! -d "Help/Build/Moolah.help" ] \
        || [ -z "$(ls -A Help/Build/Moolah.help 2>/dev/null)" ]; then
        needs=1
    elif [ ! -d "site/help" ]; then
        needs=1
    elif find Help -type f \
        \( -name '*.html' -o -name '*.tmpl' -o -name '*.json' \
           -o -name '*.plist' -o -name '*.css' -o -name '*.png' \) \
        -newer "$HELP_STAMP" 2>/dev/null | grep -q .; then
        needs=1
    elif find tools/HelpGen/Sources -type f -name '*.swift' \
        -newer "$HELP_STAMP" 2>/dev/null | grep -q .; then
        needs=1
    fi

    if [ "$needs" -eq 1 ]; then
        swift run --package-path tools/HelpGen help-gen
        /usr/bin/hiutil -Cf \
            "Help/Build/Moolah.help/Contents/Resources/en.lproj/Moolah.helpindex" \
            "Help/Build/Moolah.help/Contents/Resources/en.lproj"
        touch "$HELP_STAMP"
    fi
```

- [ ] **Step 2: Verify the recipe runs**

```bash
just build-help
```
Expected: Swift build messages from `swift run`, then a silent `hiutil` call.

- [ ] **Step 3: Run again to confirm the no-op fast path**

```bash
just build-help
```
Expected: no Swift build / no `hiutil` output — the recipe exits silently within a few hundred milliseconds.

- [ ] **Step 4: Verify the generated `site/help/` is present and contains the expected files**

```bash
ls site/help/
```
Expected: `index.html` and `styles.css`.

- [ ] **Step 5: Commit the recipe and the initial `site/help/` snapshot**

`site/help/` is the canonical web copy served by GitHub Pages. It is checked in (same pattern as the rest of `site/`); follow-up content PRs will regenerate it whenever a topic page changes.

```bash
git add justfile site/help
git commit -m "feat(just): add build-help recipe and check in initial site/help/"
```

---

### Task 12: Wire `build-help` into `just generate`

**Files:**
- Modify: `justfile`

- [ ] **Step 1: Open the existing `generate:` recipe (line ~151) and insert this two-line block immediately after the `mkdir -p "$STAMP_DIR"` line, before the `# ---- ckdb-schema-gen ----` comment**

```bash
    # ---- help-gen ----
    just build-help
```

The recipe now starts:
```bash
generate:
    #!/usr/bin/env bash
    set -euo pipefail

    STAMP_DIR=".build/stamps"
    SCHEMA_STAMP="$STAMP_DIR/ckdb-schema-gen.stamp"
    mkdir -p "$STAMP_DIR"

    # ---- help-gen ----
    just build-help

    # ---- ckdb-schema-gen ----
    …
```

- [ ] **Step 2: Verify**

```bash
just generate
```
Expected: `build-help` runs silently (already up to date), then the existing CKDB + xcodegen output appears.

- [ ] **Step 3: Commit**

```bash
git add justfile
git commit -m "feat(just): chain build-help into generate"
```

---

### Task 13: Add `just verify-help` recipe

**Files:**
- Modify: `justfile`

- [ ] **Step 1: Append a `verify-help` recipe at the end of `justfile`**

```bash
# Assert that `just build-help` is idempotent — running twice in a row must
# leave the stamp's modification time unchanged on the second invocation.
# Catches regressions where the change-detection logic in `build-help` is
# broken (e.g. always regenerates). Used by CI on the macOS lane.
verify-help:
    #!/usr/bin/env bash
    set -euo pipefail
    just build-help
    STAMP=".build/stamps/help-gen.stamp"
    if [ ! -f "$STAMP" ]; then
        echo "verify-help: stamp missing after first build-help; aborting"
        exit 1
    fi
    before=$(stat -f %m "$STAMP")
    just build-help
    after=$(stat -f %m "$STAMP")
    if [ "$before" != "$after" ]; then
        echo "verify-help: stamp mtime changed on second run ($before -> $after);"
        echo "             change detection is broken."
        exit 1
    fi
    echo "verify-help: idempotent, stamp unchanged."
```

- [ ] **Step 2: Run the recipe**

```bash
just verify-help
```
Expected last line: `verify-help: idempotent, stamp unchanged.`

- [ ] **Step 3: Commit**

```bash
git add justfile
git commit -m "feat(just): add verify-help recipe asserting idempotent build"
```

---

### Task 14: Reference the generated `.help` bundle from `project.yml`

**Files:**
- Modify: `project.yml`

- [ ] **Step 1: Locate the `Moolah_macOS:` target's `sources:` block (line ~141). It currently reads**

```yaml
  Moolah_macOS:
    type: application
    platform: macOS
    sources:
      - path: App
        excludes:
          - Info-iOS.plist
      - path: Domain
      - path: Backends
      - path: Features
      - path: Shared
      - path: Automation
      - path: UITestSupport
```

- [ ] **Step 2: Append a single new entry after `- path: UITestSupport` so the block becomes**

```yaml
  Moolah_macOS:
    type: application
    platform: macOS
    sources:
      - path: App
        excludes:
          - Info-iOS.plist
      - path: Domain
      - path: Backends
      - path: Features
      - path: Shared
      - path: Automation
      - path: UITestSupport
      - path: Help/Build/Moolah.help
        buildPhase: resources
```

- [ ] **Step 3: Regenerate the Xcode project**

```bash
just generate
```
Expected: `build-help` is up to date (silent), CKDB step silent, xcodegen reports success.

- [ ] **Step 4: Build the macOS app**

```bash
just build-mac 2>&1 | tee .agent-tmp/build-mac.txt | tail -5
```
Expected last line: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Verify the help bundle is actually inside the built app**

```bash
find .build/Build/Products/Debug/Moolah.app -name 'Moolah.help' -type d
```
Expected: one match at `.../Moolah.app/Contents/Resources/Moolah.help`.

```bash
ls .build/Build/Products/Debug/Moolah.app/Contents/Resources/Moolah.help/Contents/Resources/en.lproj/
```
Expected output includes `welcome.html`, `styles.css`, `Moolah.helpindex`.

- [ ] **Step 6: Clean up the temp build log**

```bash
rm -f .agent-tmp/build-mac.txt
```

- [ ] **Step 7: Commit**

```bash
git add project.yml
git commit -m "feat(project): bundle the generated Moolah.help into the macOS app"
```

---

## Section C — App wiring

### Task 15: Register the help book in `Info-macOS.plist` and fix the privacy URL

**Files:**
- Modify: `App/Info-macOS.plist`

- [ ] **Step 1: Open `App/Info-macOS.plist`. Find the line**

```xml
    <string>https://moolah.app/privacy</string>
```

Replace with:
```xml
    <string>https://moolah.rocks/privacy</string>
```

- [ ] **Step 2: In the same file, immediately before the closing `</dict>`, add two new keys (alphabetical order is conventional but not required for Info.plist correctness)**

Locate the existing block that ends:
```xml
    <key>MoolahCloudKitContainer</key>
    <string>$(CLOUDKIT_CONTAINER_ID)</string>
</dict>
</plist>
```

Insert before `</dict>`:
```xml
    <key>CFBundleHelpBookFolder</key>
    <string>Moolah.help</string>
    <key>CFBundleHelpBookName</key>
    <string>Moolah Help</string>
```

The end of the file now reads:
```xml
    <key>MoolahCloudKitContainer</key>
    <string>$(CLOUDKIT_CONTAINER_ID)</string>
    <key>CFBundleHelpBookFolder</key>
    <string>Moolah.help</string>
    <key>CFBundleHelpBookName</key>
    <string>Moolah Help</string>
</dict>
</plist>
```

- [ ] **Step 3: Verify the plist parses**

```bash
plutil -lint App/Info-macOS.plist
```
Expected: `App/Info-macOS.plist: OK`.

- [ ] **Step 4: Commit**

```bash
git add App/Info-macOS.plist
git commit -m "feat(macos): register Moolah.help with the system Help menu; fix privacy URL"
```

---

### Task 16: Fix the privacy URL in `Info-iOS.plist`

**Files:**
- Modify: `App/Info-iOS.plist`

- [ ] **Step 1: Open `App/Info-iOS.plist`. Replace**

```xml
    <string>https://moolah.app/privacy</string>
```
with:
```xml
    <string>https://moolah.rocks/privacy</string>
```

- [ ] **Step 2: Verify**

```bash
plutil -lint App/Info-iOS.plist
```
Expected: `App/Info-iOS.plist: OK`.

```bash
grep -c "moolah.app" App/Info-iOS.plist
```
Expected: `0` matches for `moolah.app` (any remaining `rocks.moolah.app.v2` is the CloudKit container ID — bundle-ID style, not a URL — and is correct).

- [ ] **Step 3: Commit**

```bash
git add App/Info-iOS.plist
git commit -m "fix(ios): correct NSPrivacyPolicyURL domain to moolah.rocks"
```

---

### Task 17: Drop the custom Moolah Help button and fix URLs in `MoolahDomainCommands.swift`

**Files:**
- Modify: `App/MoolahDomainCommands.swift`

- [ ] **Step 1: Open `App/MoolahDomainCommands.swift`. Locate the block at line ~239 that currently reads**

```swift
    CommandGroup(after: .help) {
      Button("Moolah Help") {
        if let url = URL(string: "https://moolah.app/help") { openURL(url) }
      }

      Button("Keyboard Shortcuts\u{2026}") {
        openWindow(id: "keyboard-shortcuts")
      }
      .keyboardShortcut("/", modifiers: [.command, .shift])

      Divider()

      Button("Release Notes") {
        if let url = URL(string: "https://moolah.app/release-notes") { openURL(url) }
      }

      Button("Report a Bug") {
        if let url = URL(string: "https://github.com/ajsutton/moolah-native/issues/new") {
          openURL(url)
        }
      }

      Divider()

      Button("Privacy Policy") {
        if let url = URL(string: "https://moolah.app/privacy") { openURL(url) }
      }

      Button("Terms of Service") {
        if let url = URL(string: "https://moolah.app/terms") { openURL(url) }
      }
    }
```

Replace the entire block with:
```swift
    CommandGroup(after: .help) {
      Button("Keyboard Shortcuts\u{2026}") {
        openWindow(id: "keyboard-shortcuts")
      }
      .keyboardShortcut("/", modifiers: [.command, .shift])

      Divider()

      Button("Release Notes") {
        if let url = URL(string: "https://moolah.rocks/release-notes") { openURL(url) }
      }

      Button("Report a Bug") {
        if let url = URL(string: "https://github.com/ajsutton/moolah-native/issues/new") {
          openURL(url)
        }
      }

      Divider()

      Button("Privacy Policy") {
        if let url = URL(string: "https://moolah.rocks/privacy") { openURL(url) }
      }

      Button("Terms of Service") {
        if let url = URL(string: "https://moolah.rocks/terms") { openURL(url) }
      }
    }
```

(The `Button("Moolah Help")` is removed — the system now auto-generates a working "Moolah Help" item because `CFBundleHelpBookName` is registered.)

- [ ] **Step 2: Verify no other `moolah.app/...` URL references remain in this file**

```bash
grep -n "moolah.app" App/MoolahDomainCommands.swift
```
Expected: zero output.

- [ ] **Step 3: Format**

```bash
just format
```

- [ ] **Step 4: Build**

```bash
just build-mac 2>&1 | tail -3
```
Expected last line: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add App/MoolahDomainCommands.swift
git commit -m "fix(help-menu): remove custom Moolah Help button; route URLs to moolah.rocks"
```

---

### Task 18: Add a Help row to the iOS Settings screen

**Files:**
- Modify: `Features/Settings/SettingsView+iOS.swift`

- [ ] **Step 1: Open `Features/Settings/SettingsView+iOS.swift`. Locate the `iOSLayout` computed property (line ~11) and update the `List`**

The existing `List` reads:
```swift
      List {
        profilesSection
        addImportProfileSection
        cryptoSection
        importSettingsSection
      }
```

Change it to:
```swift
      List {
        profilesSection
        addImportProfileSection
        cryptoSection
        importSettingsSection
        helpSection
      }
```

- [ ] **Step 2: Add a new `helpSection` view at the end of the extension, immediately before the closing `}` of `extension SettingsView`**

Find the end of `importSettingsSection` (line ~155):
```swift
    var importSettingsSection: some View {
      Section("Import") {
        NavigationLink {
          ImportSettingsView()
        } label: {
          Label("CSV Import", systemImage: "tray.and.arrow.down")
        }
        NavigationLink {
          ImportRulesSettingsView()
        } label: {
          Label("Import Rules", systemImage: "list.bullet.rectangle")
        }
      }
    }
  }
```

Insert immediately before the outer `}` (the one that closes `extension SettingsView`):
```swift
    var helpSection: some View {
      Section("Help") {
        Link(destination: URL(string: "https://moolah.rocks/help")!) {
          Label("Moolah Help", systemImage: "questionmark.circle")
        }
      }
    }
```

The resulting end of file structure becomes:
```swift
    var importSettingsSection: some View {
      Section("Import") { /* … unchanged … */ }
    }

    var helpSection: some View {
      Section("Help") {
        Link(destination: URL(string: "https://moolah.rocks/help")!) {
          Label("Moolah Help", systemImage: "questionmark.circle")
        }
      }
    }
  }

  /// Wraps UIActivityViewController for presenting a share sheet with a file URL.
  struct ShareSheetView: UIViewControllerRepresentable { /* … unchanged … */ }
#endif
```

- [ ] **Step 3: Format**

```bash
just format
```

- [ ] **Step 4: Build for iOS**

```bash
just build-ios 2>&1 | tail -3
```
Expected last line: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Features/Settings/SettingsView+iOS.swift
git commit -m "feat(ios): add Help row in Settings linking to moolah.rocks/help"
```

---

## Section D — XCUITest regression for the original bug

### Task 19: Add `HelpMenuDriver` and a duplicate-entry test

**Files:**
- Create: `MoolahUITests_macOS/Helpers/Screens/HelpMenuDriver.swift`
- Create: `MoolahUITests_macOS/Tests/HelpMenuTests.swift`

Per `guides/UI_TEST_GUIDE.md`, tests must not touch raw `XCUIElement` queries — they go through a screen driver.

- [ ] **Step 1: Create `MoolahUITests_macOS/Helpers/Screens/HelpMenuDriver.swift`**

```swift
import XCTest

/// Drives the macOS application's Help menu. Tests use this rather than
/// raw `XCUIApplication.menuBars.menuItems[...]` queries (per the screen-driver
/// rule in `guides/UI_TEST_GUIDE.md`).
@MainActor
struct HelpMenuDriver {
  let app: XCUIApplication

  /// Opens the Help menu and returns the count of items whose title is
  /// exactly `Moolah Help`. The system-default Help item contributes one;
  /// a custom button with the same label (the original bug) would contribute
  /// a second.
  func moolahHelpItemCount() -> Int {
    let helpMenu = app.menuBars.menuBarItems["Help"]
    XCTAssert(
      helpMenu.waitForExistence(timeout: 5),
      "Help menu bar item never appeared")
    helpMenu.click()

    // Resolve once; do not cache the element across waits per UI_TEST_GUIDE.md.
    let menu = app.menus.firstMatch
    XCTAssert(
      menu.waitForExistence(timeout: 5),
      "Help menu never opened")
    let matches = menu.menuItems.matching(NSPredicate(format: "title == %@", "Moolah Help"))
    let count = matches.count

    // Dismiss the menu so subsequent tests / steps see a clean state.
    app.typeKey(.escape, modifierFlags: [])
    return count
  }
}
```

- [ ] **Step 2: Create `MoolahUITests_macOS/Tests/HelpMenuTests.swift`**

```swift
import XCTest

/// Regression test for the duplicate "Moolah Help" menu entry. Before the
/// Help Book was registered, the macOS Help menu showed two items titled
/// "Moolah Help": one auto-generated by the system (with no book to open)
/// and a custom button pointing at https://moolah.app/help. This test
/// locks in the fix by asserting there is exactly one such item.
@MainActor
final class HelpMenuTests: MoolahUITestCase {
  func testHelpMenuShowsExactlyOneMoolahHelpItem() {
    let app = launch(seed: .tradeBaseline)
    let driver = HelpMenuDriver(app: app)
    XCTAssertEqual(
      driver.moolahHelpItemCount(), 1,
      "Help menu must show exactly one 'Moolah Help' item")
  }
}
```

- [ ] **Step 3: Regenerate the Xcode project so the new test files are picked up**

```bash
just generate
```

- [ ] **Step 4: Run the new test**

```bash
mkdir -p .agent-tmp
just test-mac HelpMenuTests 2>&1 | tee .agent-tmp/help-menu-test.txt | tail -10
```
Expected last lines include `Test Suite 'HelpMenuTests' passed`. If a stale Moolah test-host process is wedged (see `reference_macos_test_runner_hang`), kill it first:
```bash
pkill -9 -f 'Moolah.app/Contents/MacOS/Moolah' || true
pkill -9 -f xctest                              || true
```
then re-run.

- [ ] **Step 5: Clean up the temp log**

```bash
rm -f .agent-tmp/help-menu-test.txt
```

- [ ] **Step 6: Commit**

```bash
git add MoolahUITests_macOS/Helpers/Screens/HelpMenuDriver.swift \
        MoolahUITests_macOS/Tests/HelpMenuTests.swift
git commit -m "test(ui): assert Help menu shows exactly one Moolah Help item"
```

---

## Section E — Final verification

### Task 20: Run the full pre-commit checklist

- [ ] **Step 1: Format the entire tree**

```bash
just format
```

- [ ] **Step 2: Run format-check**

```bash
just format-check
```
Expected last line: `All Swift files are correctly formatted.` SwiftLint must report no violations.

- [ ] **Step 3: Run the no-SwiftData guard (unchanged invariant)**

```bash
just no-swiftdata
```
Expected: no output, exit 0.

- [ ] **Step 4: Run all HelpGen unit tests**

```bash
swift test --package-path tools/HelpGen
```
Expected: 8 tests pass.

- [ ] **Step 5: Run the macOS test suite**

```bash
mkdir -p .agent-tmp
just test-mac 2>&1 | tee .agent-tmp/test-mac.txt | tail -10
```
Expected last line: `Test Suite 'All tests' passed` (or similar). Grep for failures:
```bash
grep -i 'failed\|error:' .agent-tmp/test-mac.txt || echo "no failures"
```
Expected: `no failures`.

- [ ] **Step 6: Run the iOS test suite**

```bash
just test-ios 2>&1 | tee .agent-tmp/test-ios.txt | tail -10
grep -i 'failed\|error:' .agent-tmp/test-ios.txt || echo "no failures"
```
Expected: `no failures`.

- [ ] **Step 7: Run `just verify-help`**

```bash
just verify-help
```
Expected last line: `verify-help: idempotent, stamp unchanged.`

- [ ] **Step 8: Clean up temp logs**

```bash
rm -f .agent-tmp/test-mac.txt .agent-tmp/test-ios.txt
```

(No commit at this step — verification only.)

---

### Task 21: Manual smoke test of the running app

- [ ] **Step 1: Launch the macOS app**

```bash
just run-mac
```

- [ ] **Step 2: In the running app, open the Help menu**

Verify visually:
- Exactly **one** "Moolah Help" entry, near the top.
- Clicking it opens HelpViewer.app at the placeholder welcome page.
- HelpViewer's search field, when given the query `welcome`, returns the welcome page.
- "Privacy Policy" opens `https://moolah.rocks/privacy` in Safari (page will 404 — verify the URL bar, not the page).
- "Release Notes" opens `https://moolah.rocks/release-notes` (likewise expected to 404).
- "Terms of Service" opens `https://moolah.rocks/terms` (likewise).
- "Report a Bug" opens the GitHub issues page (works).

- [ ] **Step 3: Confirm the iOS build succeeded earlier in Task 18 Step 4**

Re-run if uncertain:
```bash
just build-ios 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`.

The iOS Settings → Help → tap-and-open-Safari check requires a live simulator session and is hard to script reliably. It is listed in the PR test plan (Task 22) as a manual reviewer item rather than a step you must complete here. The URL string is asserted by reading the code; the build success confirms compile + view-graph integrity.

- [ ] **Step 4: Stop here if the macOS checks passed**

No commit at this step.

---

### Task 22: Push and open a PR

- [ ] **Step 1: Confirm the worktree is clean**

```bash
git status --short
```
Expected: empty.

- [ ] **Step 2: Confirm the branch is `worktree-fix-duplicate-help-menu` and review the commits**

```bash
git -C . log --oneline origin/main..HEAD
```
Expected: roughly 15-18 commits from this plan, plus the two earlier design-doc commits.

- [ ] **Step 3: Push using the explicit refspec (per `feedback_stacked_pr_worktrees`)**

```bash
git -C . push origin worktree-fix-duplicate-help-menu:worktree-fix-duplicate-help-menu
```

- [ ] **Step 4: Open a PR**

```bash
gh pr create --title "Help Book infrastructure (placeholder content)" --body "$(cat <<'EOF'
## Summary

- Fixes the duplicate "Moolah Help" entry in the macOS Help menu by registering a real Apple Help Book and removing the custom `CommandGroup` button.
- Adds a `tools/HelpGen` Swift CLI that wraps hand-authored HTML fragments under `Help/Topics/` into both a `.help` bundle and a `site/help/` web copy.
- Wires the generator into `just generate` using the existing stamp pattern (matches `tools/CKDBSchemaGen`).
- Replaces broken `moolah.app` URLs with `moolah.rocks` in the Help menu and `NSPrivacyPolicyURL` (both Info.plist files).
- Adds a Settings → Help row on iOS that opens `moolah.rocks/help` in Safari.
- Ships **placeholder content only** (a single welcome page); comprehensive topics are deferred to follow-up PRs that touch only `Help/Topics/` and `Help/TOC.json`.

## Spec

`plans/2026-05-23-help-book-infrastructure-design.md`

## Test plan

- [x] `just format-check`, `just no-swiftdata`
- [x] `swift test --package-path tools/HelpGen` — 8 tests
- [x] `just test-mac` (incl. new `HelpMenuTests`)
- [x] `just test-ios`
- [x] `just verify-help` — second build is a stamp-unchanged no-op
- [x] Manual: macOS Help menu shows exactly one "Moolah Help" entry; it opens HelpViewer at the welcome page; HelpViewer search returns the welcome page
- [ ] Manual (reviewer): iOS Settings → Help opens `moolah.rocks/help` in Safari

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Return the PR URL. **Do not** add the PR to the merge queue from this plan — that step is owned by the reviewer who lands the PR (per `feedback_prs_to_merge_queue` the merge queue is invoked separately, after review).

---

## Open follow-ups (out of scope here — flagged for the next session)

- Design the comprehensive TOC and author every page. Touches only `Help/Topics/*.html` and `Help/TOC.json`; no infrastructure change.
- Add `NSHelpManager.openHelp(anchor:inBook:)` callsites in features (e.g., scheduled-transaction inspector) when their corresponding help pages are written.
- Populate `moolah.rocks/release-notes`, `/privacy`, `/terms` under `site/` (separate content effort — they 404 today even with this PR's URL fixes).
- Higher-resolution Help Book icon sourced from the brand pack (current icon is `sips`-downscaled from the existing mark).
