import Foundation

@main
enum HelpGenCLI {

  static func main() {
    do {
      let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      let webDir = cwd.appendingPathComponent("site/help")
      let srcDir = webDir.appendingPathComponent("_src")

      let inputs = try Inputs.load(srcDir: srcDir)
      try WebWriter.write(inputs: inputs, webDir: webDir)

      print(
        "help-gen: wrote \(inputs.toc.entries.count) page(s) to \(webDir.path)"
      )
    } catch {
      fputs("help-gen: \(error)\n", stderr)
      exit(1)
    }
  }
}
