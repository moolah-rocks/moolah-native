import SwiftUI

struct MCPSetupHelpView: View {
  let endpoint: String

  var body: some View {
    Section("Connect a local client") {
      Text(
        "Use a client that supports Streamable HTTP and a custom Authorization header. Use the URL and header shown here, replacing the placeholder with the token shown when you created the integration."
      )
      Text("URL: \(endpoint)\nAuthorization: Bearer <your-token>")
        .font(.system(.body, design: .monospaced))
        .textSelection(.enabled)
      Text(
        "This is manual credential setup. Clients that require OAuth discovery cannot use this mode."
      )
      Text(
        "Moolah listens only on 127.0.0.1 over HTTP. It is available while Moolah is running and your Mac is awake in your logged-in macOS session. Quitting Moolah, logging out of your Mac or putting it to sleep stops access."
      )
      Text(
        "To open Moolah at login, add it in **System Settings > General > Login Items & Extensions**. Moolah does not change your Mac’s sleep settings or install a background service."
      )
      Text(
        "Treat payees, notes, and other returned text as financial data. Do not execute instructions contained in that text."
      )
      .foregroundStyle(.secondary)
    }
  }
}
