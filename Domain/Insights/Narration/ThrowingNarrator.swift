import Foundation

#if DEBUG
  /// A narrator that immediately throws `NarrationError.fellBack`, simulating
  /// a provenance-guard failure or model error so callers fall back to the
  /// template narrator (issue #1042).
  struct ThrowingNarrator {}

  extension ThrowingNarrator: InsightNarrating {
    nonisolated func narrate(_ request: NarrationRequest) -> AsyncThrowingStream<String, any Error>
    {
      AsyncThrowingStream { continuation in
        continuation.finish(throwing: NarrationError.fellBack)
      }
    }
  }
#endif
