import Foundation

#if DEBUG
  /// A narrator that emits a caller-supplied sequence of snapshots then
  /// finishes cleanly. Used in unit tests and UI-test seeds so narration
  /// state transitions are deterministic without a real language model
  /// (issue #1042).
  struct ScriptedNarrator {
    /// Snapshots to emit in order. The last element is treated as the
    /// complete narration text (the stream finishes after emitting it).
    let snapshots: [String]
  }

  extension ScriptedNarrator: InsightNarrating {
    nonisolated func narrate(_ request: NarrationRequest) -> AsyncThrowingStream<String, any Error>
    {
      let snapshots = self.snapshots
      return AsyncThrowingStream { continuation in
        for snapshot in snapshots {
          continuation.yield(snapshot)
        }
        continuation.finish()
      }
    }
  }
#endif
