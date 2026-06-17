// MoolahTests/Backends/CoinGeckoCatalogSchemaTests.swift
import Foundation
import Testing

@testable import Moolah

@Suite("CoinGeckoCatalogSchema")
struct CoinGeckoCatalogSchemaTests {
  @Test
  func schemaVersionIsTwo() {
    #expect(CoinGeckoCatalogSchema.version == 2)
  }

  @Test
  func schemaContainsCoreTables() {
    let ddl = CoinGeckoCatalogSchema.schemaStatements(
      schemaVersion: CoinGeckoCatalogSchema.version
    ).joined(separator: "\n")
    // `meta` / `etag` are contributed by the engine base, the rest by the
    // CoinGecko statements; `schemaStatements` composes both.
    #expect(ddl.contains("CREATE TABLE meta"))
    #expect(ddl.contains("CREATE TABLE etag"))
    #expect(ddl.contains("CREATE TABLE coin"))
    #expect(ddl.contains("CREATE TABLE coin_platform"))
    #expect(ddl.contains("CREATE TABLE platform"))
    #expect(ddl.contains("CREATE VIRTUAL TABLE coin_fts USING fts5"))
  }

  @Test
  func schemaBaseComesFirst() {
    // The engine-owned `meta` table MUST be created before the CoinGecko
    // tables so the bookkeeping rows exist for the rest of the bootstrap.
    let statements = CoinGeckoCatalogSchema.schemaStatements(
      schemaVersion: CoinGeckoCatalogSchema.version)
    let metaIndex = statements.firstIndex { $0.contains("CREATE TABLE meta") } ?? Int.max
    let coinIndex = statements.firstIndex { $0.contains("CREATE TABLE coin ") } ?? Int.min
    #expect(metaIndex < coinIndex)
  }

  @Test
  func schemaInstallsFtsTriggers() {
    let ddl = CoinGeckoCatalogSchema.coinGeckoStatements.joined(separator: "\n")
    #expect(ddl.contains("CREATE TRIGGER coin_ai"))
    #expect(ddl.contains("CREATE TRIGGER coin_ad"))
    #expect(ddl.contains("CREATE TRIGGER coin_au"))
  }
}
