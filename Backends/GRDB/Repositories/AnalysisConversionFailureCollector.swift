import Foundation
import os

/// Coalesces repeated conversion failures emitted by one repository fetch.
/// Analysis can touch hundreds of days for the same unmapped instrument; the
/// caller logs one summary instead of one OSLog entry per affected row.
struct AnalysisConversionFailureCollector: Sendable {
  struct Summary: Sendable {
    let instrumentId: String?
    let message: String
    let sampleContext: String
    let count: Int
    let isTransient: Bool
  }

  private struct Key: Hashable {
    let instrumentId: String?
    let message: String
  }

  private struct Entry {
    let sampleContext: String
    let isTransient: Bool
    var count: Int
  }

  private let state = OSAllocatedUnfairLock<[Key: Entry]>(initialState: [:])

  func record(
    _ error: any Error,
    instrumentId: String? = nil,
    context: String
  ) {
    let message = error.localizedDescription
    let key = Key(instrumentId: instrumentId, message: message)
    let isTransient = ConversionFailureClassifier.isTransient(error)
    state.withLock { entries in
      if var entry = entries[key] {
        entry.count += 1
        entries[key] = entry
      } else {
        entries[key] = Entry(
          sampleContext: context, isTransient: isTransient, count: 1)
      }
    }
  }

  func summaries() -> [Summary] {
    state.withLock { entries in
      entries.map { key, entry in
        Summary(
          instrumentId: key.instrumentId,
          message: key.message,
          sampleContext: entry.sampleContext,
          count: entry.count,
          isTransient: entry.isTransient)
      }
      .sorted {
        ($0.instrumentId ?? "", $0.message) < ($1.instrumentId ?? "", $1.message)
      }
    }
  }
}
