// Shared/CryptoImport/BuilderServices.swift
import Foundation

/// Shared per-sync-cycle services the builder needs — the chain,
/// the token-discovery actor, and the Alchemy client used for both
/// transfer fetches and per-hash receipt lookups. Bundled into a
/// single value so the public `build(...)` entry point takes one
/// argument instead of three.
struct BuilderServices: Sendable {
  let chain: ChainConfig
  let discovery: CryptoTokenDiscoveryService
  let alchemy: any ChainDataClient
}
