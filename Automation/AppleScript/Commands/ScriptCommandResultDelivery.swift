#if os(macOS)
  import Foundation

  /// Delivers an asynchronous script-command result from a fresh AppKit run-loop
  /// turn instead of re-entering Cocoa scripting from a Swift concurrency task.
  enum ScriptCommandResultDelivery {
    static func execute<T: Sendable>(
      _ operation: @escaping @MainActor @Sendable () async throws -> sending T,
      successValue: @escaping @MainActor @Sendable (T) -> Any?,
      resume: @escaping @MainActor @Sendable (Any?) -> Void,
      fail: @escaping @MainActor @Sendable (any Error) -> Void
    ) {
      Task { @MainActor in
        do {
          let result = try await operation()
          enqueue {
            resume(successValue(result))
          }
        } catch {
          enqueue {
            fail(error)
          }
        }
      }
    }

    @MainActor
    static func enqueue(_ operation: @escaping @MainActor @Sendable () -> Void) {
      RunLoop.main.perform {
        MainActor.assumeIsolated {
          operation()
        }
      }
    }
  }
#endif
