import Foundation

/// Shared transport for app-managed APIs. Provider authentication uses explicit
/// API keys or bearer tokens, so requests must not retain or replay cookies.
/// Keep the default cache and credential behavior; CloudKit and browser-based
/// imports manage their own networking independently.
enum APIHTTPSession {
  static let shared: URLSession = {
    let configuration = URLSessionConfiguration.default
    configuration.httpCookieStorage = nil
    configuration.httpCookieAcceptPolicy = .never
    configuration.httpShouldSetCookies = false
    return URLSession(configuration: configuration)
  }()
}
