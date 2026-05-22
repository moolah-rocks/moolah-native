import Foundation

@main
enum HelpGenCLI {

  static func main() {
    do {
      let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      let helpDir = cwd.appendingPathComponent("Help")
      let bundleURL = cwd.appendingPathComponent("Help/Build/Moolah.help")
      let webDir = cwd.appendingPathComponent("site/help")

      let inputs = try Inputs.load(helpDir: helpDir)
      try HelpBookWriter.write(inputs: inputs, bundleURL: bundleURL)
      try WebWriter.write(inputs: inputs, webDir: webDir)

      print(
        "help-gen: wrote \(inputs.toc.entries.count) page(s) to "
          + "\(bundleURL.path) and \(webDir.path)"
      )
    } catch {
      fputs("help-gen: \(error)\n", stderr)
      exit(1)
    }
  }
}
