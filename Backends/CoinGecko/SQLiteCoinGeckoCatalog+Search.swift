// Backends/CoinGecko/SQLiteCoinGeckoCatalog+Search.swift
import Foundation
import SQLite3

/// FTS5 search path for `SQLiteCoinGeckoCatalog`. Hosted in a separate file
/// so the actor's primary body stays focused on schema bootstrap and
/// replace-all writes (see CLAUDE.md and `guides/CODE_GUIDE.md` §7 on
/// extension grouping).
extension SQLiteCoinGeckoCatalog {
  /// FTS5 prefix search over coin id/symbol/name, ranked by BM25, with
  /// platform bindings attached per hit. Platforms are ordered by
  /// `CoinGeckoCatalogSchema.platformPriority`, then alphabetical by slug.
  ///
  /// Infallible by design (see design §4.1): an unavailable database, an
  /// FTS query parse error, or any underlying SQLite failure is logged via
  /// `os_log` and swallowed — the picker degrades to "no results" rather
  /// than crashing on a corrupted snapshot. An empty/whitespace-only
  /// `query` or `limit <= 0` short-circuits to `[]` without touching SQLite.
  func search(query: String, limit: Int) async -> [CatalogEntry] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, limit > 0 else { return [] }

    do {
      let ranked = try fetchRankedCoins(query: trimmed, limit: limit)
      guard !ranked.isEmpty else { return [] }
      let bindings = try fetchPlatformBindings(coingeckoIds: ranked.map(\.id))
      return ranked.map { row in
        CatalogEntry(
          coingeckoId: row.id,
          symbol: row.symbol,
          name: row.name,
          platforms: Self.orderedPlatforms(for: row.id, bindings: bindings)
        )
      }
    } catch {
      Self.log.error("search failed: \(String(describing: error), privacy: .public)")
      return []
    }
  }
}

// MARK: - Private helpers

extension SQLiteCoinGeckoCatalog {
  private struct RankedCoin: Sendable {
    let id: String
    let symbol: String
    let name: String
  }

  private func fetchRankedCoins(query: String, limit: Int) throws -> [RankedCoin] {
    let ftsQuery = Self.ftsQueryString(for: query)
    var statement: OpaquePointer?
    try database.prepare(
      """
      SELECT c.coingecko_id, c.symbol, c.name
      FROM coin_fts JOIN coin c ON c.rowid = coin_fts.rowid
      WHERE coin_fts MATCH ?
      ORDER BY rank
      LIMIT ?;
      """,
      into: &statement
    )
    defer { sqlite3_finalize(statement) }
    try database.bind(statement, at: 1, to: ftsQuery)
    try database.bind(statement, at: 2, to: limit)
    var rows: [RankedCoin] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      let id = database.readText(statement, column: 0) ?? ""
      let symbol = database.readText(statement, column: 1) ?? ""
      let name = database.readText(statement, column: 2) ?? ""
      rows.append(RankedCoin(id: id, symbol: symbol, name: name))
    }
    return rows
  }

  private func fetchPlatformBindings(
    coingeckoIds: [String]
  ) throws -> [String: [PlatformBinding]] {
    guard !coingeckoIds.isEmpty else { return [:] }
    let placeholders = Array(repeating: "?", count: coingeckoIds.count)
      .joined(separator: ", ")
    var statement: OpaquePointer?
    try database.prepare(
      """
      SELECT cp.coingecko_id, cp.platform_slug, cp.contract_address, p.chain_id
      FROM coin_platform cp
      LEFT JOIN platform p ON p.slug = cp.platform_slug
      WHERE cp.coingecko_id IN (\(placeholders));
      """,
      into: &statement
    )
    defer { sqlite3_finalize(statement) }
    for (offset, id) in coingeckoIds.enumerated() {
      try database.bind(statement, at: Int32(offset + 1), to: id)
    }
    var bindingsById: [String: [PlatformBinding]] = [:]
    while sqlite3_step(statement) == SQLITE_ROW {
      let coingeckoId = database.readText(statement, column: 0) ?? ""
      let slug = database.readText(statement, column: 1) ?? ""
      let contract = database.readText(statement, column: 2) ?? ""
      let chainId: Int? =
        sqlite3_column_type(statement, 3) == SQLITE_NULL
        ? nil : Int(sqlite3_column_int64(statement, 3))
      bindingsById[coingeckoId, default: []].append(
        PlatformBinding(slug: slug, chainId: chainId, contractAddress: contract)
      )
    }
    return bindingsById
  }

  private static func orderedPlatforms(
    for coingeckoId: String,
    bindings: [String: [PlatformBinding]]
  ) -> [PlatformBinding] {
    let raw = bindings[coingeckoId] ?? []
    let priority = CoinGeckoCatalogSchema.platformPriority
    return raw.sorted { lhs, rhs in
      let lhsRank = priority.firstIndex(of: lhs.slug) ?? Int.max
      let rhsRank = priority.firstIndex(of: rhs.slug) ?? Int.max
      if lhsRank != rhsRank { return lhsRank < rhsRank }
      return lhs.slug < rhs.slug
    }
  }

  private static func ftsQueryString(for query: String) -> String {
    let tokens =
      query
      .components(separatedBy: .whitespaces)
      .filter { !$0.isEmpty }
      .map { $0.replacingOccurrences(of: "\"", with: "\"\"") }
    return tokens.map { "\"\($0)\"*" }.joined(separator: " ")
  }
}
