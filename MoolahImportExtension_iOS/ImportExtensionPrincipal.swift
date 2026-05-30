import ImportExtensionKit
import SwiftUI
import UIKit

/// Principal view controller registered as `NSExtensionPrincipalClass` in
/// `Info.plist`. Hosts the SwiftUI confirmation view and routes its three
/// actions through `PrincipalController` to the extension context.
final class ImportExtensionPrincipal: UIViewController {
  private lazy var controller = PrincipalController(context: self)

  override func viewDidLoad() {
    super.viewDidLoad()
    guard
      let item = extensionContext?.inputItems.first as? NSExtensionItem,
      let provider = item.attachments?.first
    else {
      showHost()
      return
    }
    provider.loadItem(forTypeIdentifier: "com.apple.property-list") { [weak self] payload, _ in
      // Decode off-main: `[String: Any]` is not `Sendable`, so we have
      // to collapse the JS payload to a `Sendable` `Result` here before
      // hopping back to the main actor.
      let result = PrincipalController.decode(payload: payload)
      Task { @MainActor in
        if let result { self?.controller.apply(result) }
        self?.showHost()
      }
    }
  }

  private func showHost() {
    let host = UIHostingController(
      rootView: ImportConfirmationView(
        viewModel: controller.viewModel,
        onCancel: controller.onCancel,
        onReviewLater: controller.onReviewLater,
        onOpenMoolah: controller.onOpenMoolah))
    addChild(host)
    view.addSubview(host.view)
    host.view.frame = view.bounds
    host.didMove(toParent: self)
  }
}

extension ImportExtensionPrincipal: ExtensionPrincipalContext {
  func cancelRequest() {
    extensionContext?.cancelRequest(withError: NSError(domain: "Moolah", code: 0))
  }
  func completeRequest() { extensionContext?.completeRequest(returningItems: nil) }
  func open(_ url: URL, completion: @escaping @Sendable (Bool) -> Void) {
    extensionContext?.open(url, completionHandler: completion)
  }
}
