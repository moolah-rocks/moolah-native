import Foundation

/// Destinations parsed from a `moolah://` URL. Each case maps one-to-one onto
/// a host segment of the URL; payload values are validated by the parser so
/// downstream code can assume the data is well-formed.
public enum DeepLinkDestination: Equatable, Sendable {
  /// `moolah://import?inbox=<uuid>` — the Safari import extension has
  /// written a payload to the App Group inbox and is asking the main app
  /// to consume it.
  case importInbox(UUID)
}

/// Pure parser for `moolah://` URLs. Has no side effects: it validates the
/// scheme, host, and query payload and returns a `DeepLinkDestination`, or
/// `nil` if the URL is not one we know how to route. Side effects live in
/// `DeepLinkCoordinator` so the routing logic stays unit-testable.
///
/// Add a new route by adding a case to `DeepLinkDestination` and a `case`
/// arm to `parse(_:)`.
public enum DeepLinkRouter {
  public static let scheme = "moolah"

  public static func parse(_ url: URL) -> DeepLinkDestination? {
    guard url.scheme == scheme else { return nil }
    switch url.host {
    case "import":
      guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
        let raw = comps.queryItems?.first(where: { $0.name == "inbox" })?.value,
        let id = UUID(uuidString: raw)
      else { return nil }
      return .importInbox(id)
    default:
      return nil
    }
  }
}
