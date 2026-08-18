#if os(macOS)
  import Foundation
  import Testing

  @testable import Moolah

  @Suite("Script command result delivery")
  @MainActor
  struct ScriptCommandResultDeliveryTests {
    @Test("bridges an array when resuming outside the current Swift concurrency task")
    func deliversAppleScriptArrayOutsideCurrentTask() async {
      #expect(withUnsafeCurrentTask { $0 != nil })

      await confirmation { delivered in
        await withCheckedContinuation { continuation in
          ScriptCommandResultDelivery.execute(
            {
              @MainActor () async throws -> [NSNumber] in
              [NSNumber(value: 1), NSNumber(value: 2)]
            },
            successValue: { $0 as NSArray },
            resume: { value in
              #expect(withUnsafeCurrentTask { $0 == nil })
              let array = value as? NSArray
              #expect(array?.count == 2)
              delivered()
              continuation.resume()
            },
            fail: { error in
              Issue.record("Unexpected failure: \(error)")
              delivered()
              continuation.resume()
            }
          )
        }
      }
    }
  }
#endif
