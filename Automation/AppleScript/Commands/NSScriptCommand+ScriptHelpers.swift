#if os(macOS)
  import AppKit
  import Foundation
  import OSLog

  private let logger = Logger(subsystem: "com.moolah.app", category: "ScriptCommand")

  /// One-way hand-off carrier for a non-`Sendable` `NSScriptCommand` (see
  /// `guides/CONCURRENCY_GUIDE.md` Carve-out 5).
  ///
  /// `runBlockingWithError` suspends the command on the main thread and resumes
  /// it after the async work finishes. Cocoa retains the command across that
  /// suspension but, by the scripting contract, does not touch it again until
  /// `resumeExecution(withResult:)` is called — so the command is only ever read
  /// on the main thread. Swift's region-isolation pass
  /// can't see that contract: capturing `self` directly trips
  /// `sending 'self' risks causing data races`, because for an instance method
  /// `self` is task-isolated and could, in principle, be used by the caller
  /// after the method returns. This box is the documented escape: it carries the
  /// command into the `Task` and then the main run loop with the invariant that
  /// the value is touched only on the main thread. The alternative — a
  /// `DispatchSemaphore` to block until the
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

    /// Resolves the profile identifier from the direct parameter. AppleScript
    /// commands pass either `profile "MyProfile"` (`NSNameSpecifier`) or
    /// `profile id "UUID"` (`NSUniqueIDSpecifier`).
    func resolveProfileIdentifier() -> String? {
      if let specifier = directParameter as? NSScriptObjectSpecifier {
        if let idSpec = specifier as? NSUniqueIDSpecifier,
          let uniqueID = idSpec.uniqueID as? String
        {
          return uniqueID
        }
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

    func resolveProfileName() -> String? {
      resolveProfileIdentifier()
    }

    /// Runs an async `@MainActor` block from an
    /// `NSScriptCommand.performDefaultImplementation`.
    ///
    /// Cocoa's scripting infrastructure on macOS 26 dispatches commands on the
    /// main thread, so this helper suspends the command and resumes it
    /// asynchronously once `operation` completes — Cocoa's documented pattern
    /// for async script commands. Result delivery is queued onto a fresh main
    /// run-loop turn so AppKit cannot synchronously re-enter its KVC scripting
    /// bridge from inside the Swift concurrency task. `performDefaultImplementation`
    /// returns `nil` immediately; the real result is delivered later via
    /// `resumeExecution(withResult:)`.
    ///
    /// There is no off-main / blocking branch: a `DispatchSemaphore` would park
    /// a cooperative-pool thread (forbidden — see `guides/CONCURRENCY_GUIDE.md`),
    /// and Cocoa dispatches these commands only on the main thread. The command
    /// crosses into the `@MainActor` `Task` via `ScriptCommandBox` (Carve-out 5)
    /// — it is touched only on the main thread for the rest of its life.
    func runBlockingWithError<T: NSObject & Sendable>(
      _ operation: @escaping @MainActor @Sendable () async throws -> sending T
    ) -> T? {
      startScriptCommand(operation, successValue: { $0 })
      return nil
    }

    func runBlockingWithError<T: NSObject & Sendable>(
      _ operation: @escaping @MainActor @Sendable () async throws -> sending [T]
    ) -> Any? {
      startScriptCommand(operation, successValue: { $0 as NSArray })
      return nil
    }

    func runBlockingWithError(
      _ operation: @escaping @MainActor @Sendable () async throws -> sending String
    ) -> String? {
      startScriptCommand(operation, successValue: { $0 as NSString })
      return nil
    }

    func runBlockingWithError(
      _ operation: @escaping @MainActor @Sendable () async throws -> sending Void
    ) -> Void? {
      startScriptCommand(operation, successValue: { _ in nil })
      return nil
    }

    private func startScriptCommand<T: Sendable>(
      _ operation: @escaping @MainActor @Sendable () async throws -> sending T,
      successValue: @escaping @MainActor @Sendable (T) -> Any?
    ) {
      suspendExecution()
      let box = ScriptCommandBox(self)
      ScriptCommandResultDelivery.execute(
        operation,
        successValue: successValue,
        resume: { value in
          box.command.resumeExecution(withResult: value)
        },
        fail: { error in
          logger.error("Script command failed: \(error.localizedDescription, privacy: .public)")
          box.command.scriptErrorNumber = errOSAGeneralError
          box.command.scriptErrorString = error.localizedDescription
          box.command.resumeExecution(withResult: nil)
        }
      )
    }
  }

  /// Error codes for AppleScript
  private let errOSAGeneralError: Int = -10000
#endif
