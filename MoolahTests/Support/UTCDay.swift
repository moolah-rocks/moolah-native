import Foundation

@testable import Moolah

/// Parses a `YYYY-MM-DD` string to a midnight-UTC `Date`. Shared across the
/// price/rate contiguity test suites to keep date construction readable.
///
/// Intended for compile-time string literals; a failure means the test
/// source itself contains a malformed date — a programmer error the run
/// cannot proceed past.
func utcDay(
  _ string: String,
  file: StaticString = #file,
  line: UInt = #line
) -> Date {
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withFullDate]
  formatter.timeZone = .utc
  guard let date = formatter.date(from: string) else {
    preconditionFailure("Could not parse ISO date: \(string)", file: file, line: line)
  }
  return date
}
