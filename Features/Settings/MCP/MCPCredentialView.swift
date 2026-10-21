import AppKit
import MoolahMCP
import SwiftUI

struct MCPCredentialView: View {
  @Environment(MCPServerController.self) private var controller
  @Environment(\.dismiss) private var dismiss
  let credential: MCPCreatedCredential
  @State private var copied = false

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Save your credential").font(.title2)
      Text(
        "This token is shown once. Save it in your client’s secure credential settings. Anyone with it can read the profiles and data you allowed."
      )
      Text(credential.token)
        .font(.system(.body, design: .monospaced))
        .textSelection(.enabled)
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
      Text(
        "Copying puts the token on the clipboard for up to one minute. Clipboard tools may keep their own copies."
      )
      .font(.callout).foregroundStyle(.secondary)
      HStack {
        Button(copied ? "Copied" : "Copy Token") {
          controller.clipboard.copy(credential.token)
          copied = true
        }
        Spacer()
        Button("Done") {
          controller.dismissCredential()
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(24)
    .frame(minWidth: 500, minHeight: 280)
    .interactiveDismissDisabled()
  }
}
