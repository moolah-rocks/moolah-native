// Backends/GRDB/Records/TaxOwnerIDListCoding.swift

import Foundation

enum TaxOwnerIDListCoding {
  static func encode(_ ids: [UUID]) -> String? {
    guard !ids.isEmpty else { return nil }
    return uniquedPreservingOrder(ids).map(\.uuidString).joined(separator: ",")
  }

  static func decode(_ encoded: String?) -> [UUID] {
    guard let encoded, !encoded.isEmpty else { return [] }
    let ids =
      encoded
      .split(separator: ",")
      .compactMap { UUID(uuidString: String($0)) }
    return uniquedPreservingOrder(ids)
  }

  private static func uniquedPreservingOrder(_ ids: [UUID]) -> [UUID] {
    var seen: Set<UUID> = []
    var result: [UUID] = []
    for id in ids where seen.insert(id).inserted {
      result.append(id)
    }
    return result
  }
}
