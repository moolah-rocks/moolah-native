import Foundation
import MoolahMCP

/// One strict input decoder for every tool. Unknown arguments never silently change query meaning.
struct MCPToolArguments: Sendable {
  let values: [String: MCPToolValue]

  func validateKeys(_ allowed: Set<String>) throws {
    guard Set(values.keys).isSubset(of: allowed) else { throw MCPAccessFailure.invalidFilter }
  }

  func string(_ key: String, required: Bool = false, maximumBytes: Int = 256) throws -> String? {
    guard let value = values[key] else {
      if required { throw MCPAccessFailure.invalidFilter }
      return nil
    }
    guard case .string(let result) = value, !result.isEmpty, result.utf8.count <= maximumBytes
    else {
      throw MCPAccessFailure.invalidFilter
    }
    return result
  }

  func uuid(_ key: String) throws -> UUID {
    guard let text = try string(key, required: true, maximumBytes: 36),
      let id = UUID(uuidString: text)
    else {
      throw MCPAccessFailure.invalidFilter
    }
    return id
  }

  func ids(_ key: String) throws -> Set<UUID> {
    guard let value = values[key] else { return [] }
    guard case .array(let array) = value, array.count <= 500 else {
      throw MCPAccessFailure.invalidFilter
    }
    return try Set(
      array.map { value in
        guard case .string(let text) = value, text.utf8.count == 36, let id = UUID(uuidString: text)
        else {
          throw MCPAccessFailure.invalidFilter
        }
        return id
      }
    )
  }

  func bool(_ key: String, default fallback: Bool = false) throws -> Bool {
    guard let value = values[key] else { return fallback }
    guard case .bool(let result) = value else { throw MCPAccessFailure.invalidFilter }
    return result
  }

  func limit() throws -> Int {
    guard let value = values["limit"] else { return 100 }
    guard case .int(let result) = value, (1...500).contains(result) else {
      throw MCPAccessFailure.invalidFilter
    }
    return result
  }

  func timeZone(default fallback: TimeZone) throws -> TimeZone {
    guard let text = try string("time_zone", maximumBytes: 100) else { return fallback }
    guard let zone = TimeZone(identifier: text) else { throw MCPAccessFailure.invalidFilter }
    return zone
  }

  func dateRange(timeZone: TimeZone) throws -> ReadDateRange {
    guard let from = try string("from_date", required: true, maximumBytes: 10),
      let to = try string("to_date", required: true, maximumBytes: 10)
    else { throw MCPAccessFailure.invalidFilter }
    return try ReadDateRange(from: from, through: to, timeZone: timeZone)
  }
}
