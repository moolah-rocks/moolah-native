// MoolahTests/Sync/GRDBRepositoryHookRecordTypeTests.swift

import Foundation
import GRDB
import Testing

@testable import Moolah

/// Regression tests for the `(recordType, id)` contract on the GRDB-backed
/// repositories. Mirrors the SwiftData-side
/// `RepositoryHookRecordTypeTests`: the hook closure must always tag each
/// emit with the correct `recordType` so the upload pipeline does not
/// mis-prefix the recordName (issue #416 / #483 regression class).
@Suite("GRDB repository hooks emit (recordType, id) pairs")
struct GRDBRepositoryHookRecordTypeTests {

  /// Confined to the test type's stored capture; the closures run on the
  /// GRDB queue executor, not the main actor, so we use a small lock-free
  /// helper sealed by `@unchecked Sendable`.
  final class HookCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var _changed: [(recordType: String, id: UUID)] = []
    private var _deleted: [(recordType: String, id: UUID)] = []

    var changed: [(recordType: String, id: UUID)] {
      lock.withLock { _changed }
    }

    var deleted: [(recordType: String, id: UUID)] {
      lock.withLock { _deleted }
    }

    func appendChanged(_ recordType: String, _ id: UUID) {
      lock.withLock { _changed.append((recordType, id)) }
    }

    func appendDeleted(_ recordType: String, _ id: UUID) {
      lock.withLock { _deleted.append((recordType, id)) }
    }
  }

  // MARK: - GRDBCSVImportProfileRepository

  @Test
  func csvImportProfileCreateEmitsRecordType() async throws {
    let database = try ProfileDatabase.openInMemory()
    let capture = HookCapture()
    let repo = GRDBCSVImportProfileRepository(
      database: database,
      onRecordChanged: { recordType, id in capture.appendChanged(recordType, id) },
      onRecordDeleted: { recordType, id in capture.appendDeleted(recordType, id) })

    let profile = makeProfile()
    _ = try await repo.create(profile)

    #expect(capture.changed.count == 1)
    #expect(capture.changed.first?.recordType == CSVImportProfileRow.recordType)
    #expect(capture.changed.first?.id == profile.id)
    #expect(capture.deleted.isEmpty)
  }

  @Test
  func csvImportProfileUpdateEmitsRecordType() async throws {
    let database = try ProfileDatabase.openInMemory()
    let capture = HookCapture()
    let repo = GRDBCSVImportProfileRepository(
      database: database,
      onRecordChanged: { recordType, id in capture.appendChanged(recordType, id) },
      onRecordDeleted: { recordType, id in capture.appendDeleted(recordType, id) })

    let profile = makeProfile()
    let created = try await repo.create(profile)
    var updated = created
    updated.filenamePattern = "renamed-*.csv"
    _ = try await repo.update(updated)

    let updates = capture.changed.filter { $0.id == profile.id }
    #expect(updates.count == 2)
    #expect(updates.allSatisfy { $0.recordType == CSVImportProfileRow.recordType })
  }

  @Test
  func csvImportProfileDeleteEmitsRecordType() async throws {
    let database = try ProfileDatabase.openInMemory()
    let capture = HookCapture()
    let repo = GRDBCSVImportProfileRepository(
      database: database,
      onRecordChanged: { recordType, id in capture.appendChanged(recordType, id) },
      onRecordDeleted: { recordType, id in capture.appendDeleted(recordType, id) })

    let profile = makeProfile()
    _ = try await repo.create(profile)
    try await repo.delete(id: profile.id)

    #expect(capture.deleted.count == 1)
    #expect(capture.deleted.first?.recordType == CSVImportProfileRow.recordType)
    #expect(capture.deleted.first?.id == profile.id)
  }

  // MARK: - GRDBImportRuleRepository

  @Test
  func importRuleCreateEmitsRecordType() async throws {
    let database = try ProfileDatabase.openInMemory()
    let capture = HookCapture()
    let repo = GRDBImportRuleRepository(
      database: database,
      onRecordChanged: { recordType, id in capture.appendChanged(recordType, id) },
      onRecordDeleted: { recordType, id in capture.appendDeleted(recordType, id) })

    let rule = makeRule(position: 0)
    _ = try await repo.create(rule)

    #expect(capture.changed.count == 1)
    #expect(capture.changed.first?.recordType == ImportRuleRow.recordType)
    #expect(capture.changed.first?.id == rule.id)
    #expect(capture.deleted.isEmpty)
  }

  @Test
  func importRuleUpdateEmitsRecordType() async throws {
    let database = try ProfileDatabase.openInMemory()
    let capture = HookCapture()
    let repo = GRDBImportRuleRepository(
      database: database,
      onRecordChanged: { recordType, id in capture.appendChanged(recordType, id) },
      onRecordDeleted: { recordType, id in capture.appendDeleted(recordType, id) })

    let rule = makeRule(position: 0)
    let created = try await repo.create(rule)
    var updated = created
    updated.name = "renamed"
    _ = try await repo.update(updated)

    let updates = capture.changed.filter { $0.id == rule.id }
    #expect(updates.count == 2)
    #expect(updates.allSatisfy { $0.recordType == ImportRuleRow.recordType })
  }

  @Test
  func importRuleDeleteEmitsRecordType() async throws {
    let database = try ProfileDatabase.openInMemory()
    let capture = HookCapture()
    let repo = GRDBImportRuleRepository(
      database: database,
      onRecordChanged: { recordType, id in capture.appendChanged(recordType, id) },
      onRecordDeleted: { recordType, id in capture.appendDeleted(recordType, id) })

    let rule = makeRule(position: 0)
    _ = try await repo.create(rule)
    try await repo.delete(id: rule.id)

    #expect(capture.deleted.count == 1)
    #expect(capture.deleted.first?.recordType == ImportRuleRow.recordType)
    #expect(capture.deleted.first?.id == rule.id)
  }

  @Test
  func importRuleReorderEmitsRecordTypeForChangedIdsOnly() async throws {
    let database = try ProfileDatabase.openInMemory()
    let capture = HookCapture()
    let repo = GRDBImportRuleRepository(
      database: database,
      onRecordChanged: { recordType, id in capture.appendChanged(recordType, id) },
      onRecordDeleted: { recordType, id in capture.appendDeleted(recordType, id) })

    let firstRule = makeRule(position: 0)
    let secondRule = makeRule(position: 1)
    let thirdRule = makeRule(position: 2)
    _ = try await repo.create(firstRule)
    _ = try await repo.create(secondRule)
    _ = try await repo.create(thirdRule)

    // Snapshot so reorder's emits are isolated from the prior creates.
    let createsCount = capture.changed.count

    // Swap first and third; second stays put — so reorder MUST emit
    // exactly two `(ImportRuleRow.recordType, id)` pairs.
    try await repo.reorder([thirdRule.id, secondRule.id, firstRule.id])

    let reorderEmits = Array(capture.changed.suffix(from: createsCount))
    #expect(reorderEmits.count == 2)
    #expect(reorderEmits.allSatisfy { $0.recordType == ImportRuleRow.recordType })
    let reorderIds = Set(reorderEmits.map(\.id))
    #expect(reorderIds == [firstRule.id, thirdRule.id])
  }

  // MARK: - GRDBTransferSuggestionRepository

  @Test
  func transferSuggestionCreateEmitsRecordType() async throws {
    let database = try ProfileDatabase.openInMemory()
    let capture = HookCapture()
    let repo = GRDBTransferSuggestionRepository(
      database: database,
      onRecordChanged: { recordType, id in capture.appendChanged(recordType, id) },
      onRecordDeleted: { recordType, id in capture.appendDeleted(recordType, id) })

    let suggestion = makeSuggestion()
    _ = try await repo.create(suggestion)

    #expect(capture.changed.count == 1)
    #expect(capture.changed.first?.recordType == TransferSuggestionRow.recordType)
    #expect(capture.changed.first?.id == suggestion.id)
    #expect(capture.deleted.isEmpty)
  }

  @Test
  func transferSuggestionDeleteEmitsRecordType() async throws {
    let database = try ProfileDatabase.openInMemory()
    let capture = HookCapture()
    let repo = GRDBTransferSuggestionRepository(
      database: database,
      onRecordChanged: { recordType, id in capture.appendChanged(recordType, id) },
      onRecordDeleted: { recordType, id in capture.appendDeleted(recordType, id) })

    let suggestion = makeSuggestion()
    _ = try await repo.create(suggestion)
    try await repo.delete(id: suggestion.id)

    #expect(capture.deleted.count == 1)
    #expect(capture.deleted.first?.recordType == TransferSuggestionRow.recordType)
    #expect(capture.deleted.first?.id == suggestion.id)
  }

  // MARK: - Helpers

  private func makeSuggestion() -> TransferSuggestion {
    TransferSuggestion(
      transactionIds: [UUID(), UUID()],
      suggestedAt: Date(timeIntervalSince1970: 1_700_000_000))
  }

  private func makeProfile() -> CSVImportProfile {
    CSVImportProfile(
      accountId: UUID(),
      parserIdentifier: "generic-bank",
      headerSignature: ["date", "amount"])
  }

  private func makeRule(position: Int) -> ImportRule {
    ImportRule(
      name: "rule-\(position)",
      position: position,
      conditions: [],
      actions: [])
  }
}
