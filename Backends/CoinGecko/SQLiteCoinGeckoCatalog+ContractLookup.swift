// Backends/CoinGecko/SQLiteCoinGeckoCatalog+ContractLookup.swift
import Foundation
import SQLite3

/// Offline `(chainId, contractAddress) → CoinGecko id` resolution over the
/// cached catalog. Lets a known token (e.g. canonical USDC) be priced
/// immediately without a network round-trip. Hosted in its own file so the
/// actor's primary body stays focused (see `guides/CODE_GUIDE.md` §7).
extension SQLiteCoinGeckoCatalog: LocalContractResolver {
  /// Resolves the CoinGecko id, symbol, and name for a token identified by its
  /// on-chain `(chainId, contractAddress)`, or `nil` when the catalog has no
  /// such deployment. Matching is case-insensitive on the contract (addresses
  /// are stored lowercased). Infallible by design — any SQLite failure is
  /// logged and swallowed to `nil`, mirroring `search(query:limit:)`.
  func localContractMatch(
    chainId: Int, contractAddress: String
  ) async -> LocalContractMatch? {
    do {
      return try Self.fetchContractMatch(
        database: database,
        chainId: chainId,
        contractAddress: contractAddress.lowercased())
    } catch {
      Self.log.error(
        "localContractMatch failed: \(String(describing: error), privacy: .public)")
      return nil
    }
  }

  private static func fetchContractMatch(
    database: OpaquePointer?,
    chainId: Int,
    contractAddress: String
  ) throws -> LocalContractMatch? {
    var statement: OpaquePointer?
    try prepare(
      database: database,
      sql: """
        SELECT c.coingecko_id, c.symbol, c.name
        FROM coin_platform cp
        JOIN platform p ON p.slug = cp.platform_slug
        JOIN coin c ON c.coingecko_id = cp.coingecko_id
        WHERE p.chain_id = ? AND cp.contract_address = ?
        LIMIT 1;
        """,
      into: &statement
    )
    defer { sqlite3_finalize(statement) }
    try bind(statement, at: 1, to: chainId)
    try bind(statement, at: 2, to: contractAddress)
    guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
    let id = readText(statement, column: 0) ?? ""
    guard !id.isEmpty else { return nil }
    return LocalContractMatch(
      coingeckoId: id,
      symbol: readText(statement, column: 1) ?? "",
      name: readText(statement, column: 2) ?? "")
  }
}
