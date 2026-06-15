#if os(macOS)
  import AppKit
  import Foundation
  import OSLog

  private let logger = Logger(subsystem: "com.moolah.app", category: "ScriptCommand")

  /// One-way hand-off carrier for a non-`Sendable` `NSScriptCommand` (see
  /// `guides/CONCURRENCY_GUIDE.md` Carve-out 5).
  ///
  /// `runBlockingWithError` suspends the command on the main thread and resumes
  /// it from a `@MainActor` `Task` once the async work finishes. Cocoa retains
  /// the command across that suspension but, by the scripting contract, does not
  /// touch it again until `resumeExecution(withResult:)` is called — so the
  /// command is only ever read on the `MainActor`. Swift's region-isolation pass
  /// can't see that contract: capturing `self` directly trips
  /// `sending 'self' risks causing data races`, because for an instance method
  /// `self` is task-isolated and could, in principle, be used by the caller
  /// after the method returns. This box is the documented escape: it carries the
  /// command into the `Task` with the invariant that the value is touched only on
  /// the `MainActor`. The alternative — `DispatchSemaphore` to block until the
  /// async work finishes — is forbidden (it parks a cooperative-pool thread).
  private final class ScriptCommandBox: @unchecked Sendable {
    let command: NSScriptCommand

    init(_ command: NSScriptCommand) { self.command = command }
  }

  /// Base class for app-level `NSScriptCommand`s whose direct parameter is an
  /// object specifier.
  ///
  /// Cocoa's default `execute()` resolves the specifier and then dispatches the
  /// command to the target object's class. When the command is defined at the
  /// application level (as all Moolah scripting commands are) the target class
  /// does not implement the command selector, so dispatch fails with -1708
  /// ("doesn't understand the message"). Overriding `execute()` to call
  /// `performDefaultImplementation()` directly keeps the handler class in
  /// charge of resolving the direct parameter itself.
  ///
  /// Intentionally non-`final`: subclassed by every app-level AppleScript
  /// command (`CreateAccountCommand`, `RefreshCommand`, …).
  class AppLevelScriptCommand: NSScriptCommand {
    override func execute() -> Any? {
      performDefaultImplementation()
    }
  }

  extension NSScriptCommand {

    /// Resolves the profile name from the direct parameter (an object specifier).
    /// AppleScript commands typically pass a specifier like `profile "MyProfile"`.
    func resolveProfileName() -> String? {
      if let specifier = directParameter as? NSScriptObjectSpecifier {
        // NSNameSpecifier: `profile "MyProfile"`
        if let nameSpec = specifier as? NSNameSpecifier {
          return nameSpec.name
        }
      }
      // Direct parameter might be a string
      if let name = directParameter as? String {
        return name
      }
      return nil
    }

    /// Runs an async `@MainActor` block from an
    /// `NSScriptCommand.performDefaultImplementation`.
    ///
    /// Cocoa's scripting infrastructure on macOS 26 dispatches commands on the
    /// main thread, so this helper suspends the command and resumes it
    /// asynchronously once `operation` completes — Cocoa's documented pattern
    /// for async script commands. `performDefaultImplementation` returns `nil`
    /// immediately; the real result is delivered later via
    /// `resumeExecution(withResult:)`.
    ///
    /// There is no off-main / blocking branch: a `DispatchSemaphore` would park
    /// a cooperative-pool thread (forbidden — see `guides/CONCURRENCY_GUIDE.md`),
    /// and Cocoa dispatches these commands only on the main thread. The command
    /// crosses into the `@MainActor` `Task` via `ScriptCommandBox` (Carve-out 5)
    /// — it is touched only on the main thread for the rest of its life.
    func runBlockingWithError<T: Sendable>(
      _ operation: @escaping @MainActor @Sendable () async throws -> sending T
    ) -> T? {
      suspendExecution()
      let box = ScriptCommandBox(self)
      Task { @MainActor in
        do {
          box.command.resumeExecution(withResult: try await operation())
        } catch {
          logger.error("Script command failed: \(error.localizedDescription, privacy: .public)")
          box.command.scriptErrorNumber = errOSAGeneralError
          box.command.scriptErrorString = error.localizedDescription
          box.command.resumeExecution(withResult: nil)
        }
      }
      return nil
    }
  }

  /// Error codes for AppleScript
  private let errOSAGeneralError: Int = -10000
#endif
