import Foundation
import ImportExtensionKit

/// Abstracts the platform's `NSExtensionContext` capabilities used by
/// `PrincipalController`. The iOS principal forwards to `extensionContext`;
/// the macOS principal forwards `open(_:)` to `NSWorkspace` because the
/// macOS action extension context does not vend an `open` API.
@MainActor
protocol ExtensionPrincipalContext: AnyObject {
  func cancelRequest()
  func completeRequest()
  // `@Sendable` matches `UIExtensionContext.open(_:completionHandler:)`'s
  // signature on iOS, so the iOS adapter can forward directly without a
  // wrapper closure. The macOS adapter ignores `completion`'s isolation.
  func open(_ url: URL, completion: @escaping @Sendable (Bool) -> Void)
}

/// Platform-agnostic controller for the import action extension. Owns the
/// view model the SwiftUI confirmation view binds to, decodes the JS
/// preprocessing payload, writes it to the App Group inbox, and dispatches
/// the three confirmation actions to the surrounding view controller via
/// `ExtensionPrincipalContext`.
@MainActor
final class PrincipalController {
  private let context: ExtensionPrincipalContext
  private(set) var viewModel: ImportConfirmationViewModel

  private var payload: ImportPayload?
  private var inboxId: UUID?

  init(context: ExtensionPrincipalContext) {
    self.context = context
    self.viewModel = ImportConfirmationViewModel(state: .schemaMismatch)
  }

  /// Decodes the `NSItemProvider.loadItem` payload to a `Sendable` result.
  /// Called from the loader closure (off-main) on both platforms — the
  /// `[String: Any]` JS dictionary is not `Sendable`, so the decode has
  /// to happen before crossing back to the main actor.
  ///
  /// The `sourceURL` is normalised to scheme+host+path before the payload
  /// crosses the App Group boundary. Some banks encode short-lived
  /// session tokens in the query string; stripping them here avoids
  /// retaining sensitive bearer-style data on disk in the inbox JSON.
  nonisolated static func decode(payload: Any?)
    -> Result<ImportPayload, ExtensionItemReaderError>?
  {
    guard
      let dict = (payload as? NSDictionary)?[
        "NSExtensionJavaScriptPreprocessingResultsKey"] as? [String: Any]
    else { return nil }
    do {
      let decoded = try ExtensionItemReader.decode(jsResult: dict)
      return .success(decoded.strippingSourceURLQueryAndFragment())
    } catch let error as ExtensionItemReaderError {
      return .failure(error)
    } catch {
      return .failure(.malformed)
    }
  }

  /// Applies a pre-decoded result on the main actor.
  func apply(_ result: Result<ImportPayload, ExtensionItemReaderError>) {
    switch result {
    case .success(let decoded):
      payload = decoded
      viewModel = ImportConfirmationViewModel(payload: decoded, registry: PluginRegistry.shared)
    case .failure:
      // Every reader error collapses to the same user-facing
      // "couldn't read this page" state — the user can't act on the
      // distinction and we don't want to leak parser internals.
      viewModel = ImportConfirmationViewModel(state: .schemaMismatch)
    }
  }

  func onCancel() { context.cancelRequest() }

  func onReviewLater() {
    guard write() else { return }
    context.completeRequest()
  }

  func onOpenMoolah() {
    guard write(), let id = inboxId, let url = Self.deepLink(inbox: id) else { return }
    context.open(url) { [weak self] _ in
      // The completion handler is `@Sendable` (see protocol) and may
      // arrive off-main on iOS; hop back to MainActor before touching
      // `self`.
      Task { @MainActor in self?.context.completeRequest() }
    }
  }

  private static func deepLink(inbox id: UUID) -> URL? {
    var components = URLComponents()
    components.scheme = "moolah"
    components.host = "import"
    components.queryItems = [URLQueryItem(name: "inbox", value: id.uuidString)]
    return components.url
  }

  private func write() -> Bool {
    guard let payload, let writer = InboxWriter.shared() else {
      viewModel = ImportConfirmationViewModel(state: .writeFailed)
      return false
    }
    let id = UUID()
    do {
      try writer.write(payload, id: id)
      inboxId = id
      return true
    } catch {
      viewModel = ImportConfirmationViewModel(state: .writeFailed)
      return false
    }
  }
}
