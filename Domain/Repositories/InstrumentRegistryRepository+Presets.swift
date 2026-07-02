// Domain/Repositories/InstrumentRegistryRepository+Presets.swift
import Foundation
import OSLog

extension InstrumentRegistryRepository {
  /// Seed every `CryptoRegistration.builtInPresets` entry that is not
  /// already represented by a canonical registration with the same asset
  /// key. Idempotent: a preset whose `mapping.assetKey` matches an
  /// existing registration's assetKey is skipped — the existing mapping
  /// wins regardless of instrument id. This prevents a non-canonical
  /// preset from re-minting a retired id even if the preset list drifts.
  ///
  /// Provides the offline-first, no-network path that lets transaction
  /// detail / running-balance / aggregation render correctly the very
  /// first time a profile session reads a crypto leg, without waiting
  /// for wallet sync to fire (issue #791). The not-already-present set is
  /// seeded in one `registerCryptoBatch` call so startup touches the WAL
  /// once rather than once per preset (issue #1197); a backing-store
  /// failure rolls the whole seed back and is logged, then retried on the
  /// next launch.
  ///
  /// Cancellation propagates immediately. Best-effort otherwise.
  func registerBuiltInPresetsIfMissing() async {
    await registerBuiltInPresetsIfMissing(presets: CryptoRegistration.builtInPresets)
  }

  /// Testable seam: seed `presets` into the registry, skipping any whose
  /// `mapping.assetKey` already matches a registered canonical registration.
  /// The no-arg overload calls this with `CryptoRegistration.builtInPresets`.
  func registerBuiltInPresetsIfMissing(presets: [CryptoRegistration]) async {
    let logger = Logger(subsystem: "com.moolah.app", category: "InstrumentRegistryPresets")
    let existingAssetKeys: Set<String>
    do {
      existingAssetKeys = Set(try await allCryptoRegistrations().map { $0.mapping.assetKey })
    } catch is CancellationError {
      return
    } catch {
      logger.warning(
        """
        registerBuiltInPresetsIfMissing: allCryptoRegistrations failed: \
        \(error.localizedDescription, privacy: .public)
        """
      )
      existingAssetKeys = []
    }
    let missing = presets.filter { !existingAssetKeys.contains($0.mapping.assetKey) }
    guard !missing.isEmpty else { return }
    do {
      try Task.checkCancellation()
      try await registerCryptoBatch(
        missing.map { (instrument: $0.instrument, mapping: $0.mapping) })
    } catch is CancellationError {
      return
    } catch {
      logger.warning(
        """
        registerBuiltInPresetsIfMissing: seeding \(missing.count, privacy: .public) \
        preset(s) failed: \(error.localizedDescription, privacy: .public)
        """
      )
    }
  }
}
