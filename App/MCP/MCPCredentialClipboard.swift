import AppKit

/// Secrets use the clipboard with an expiry; never overwrite a newer clipboard item.
@MainActor
final class MCPCredentialClipboard {
  private var ownedChangeCount: Int?
  private var clearTask: Task<Void, Never>?

  func clearIfOwned() {
    clearTask?.cancel()
    clearTask = nil
    let pasteboard = NSPasteboard.general
    if let ownedChangeCount, pasteboard.changeCount == ownedChangeCount {
      pasteboard.clearContents()
    }
    ownedChangeCount = nil
  }

  func copy(_ token: String) {
    clearTask?.cancel()
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    let item = NSPasteboardItem()
    item.setString(token, forType: .string)
    item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
    pasteboard.writeObjects([item])
    let changeCount = pasteboard.changeCount
    ownedChangeCount = changeCount
    clearTask = Task {
      do { try await Task.sleep(for: .seconds(60)) } catch { return }
      if pasteboard.changeCount == changeCount { pasteboard.clearContents() }
      ownedChangeCount = nil
      clearTask = nil
    }
  }
}
