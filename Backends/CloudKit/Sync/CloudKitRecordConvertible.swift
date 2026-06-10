import CloudKit
import Foundation

/// Protocol for bidirectional conversion between record types and CKRecords.
///
/// `Sendable` so `RecordTypeRegistry.allTypes` — a dictionary of conformer
/// metatypes held in an immutable global — is provably concurrency-safe
/// without a `nonisolated(unsafe)` escape hatch. Every conformer is a GRDB
/// row value type whose stored properties are all `Sendable`, so the bound
/// is satisfied by the compiler-synthesised conformance.
protocol CloudKitRecordConvertible: Sendable {
  static var recordType: String { get }

  /// Converts this record to a CKRecord in the given zone.
  func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord

  /// Extracts field values from a CKRecord. Returns a new instance with the extracted values,
  /// or `nil` if the `CKRecord` does not carry a valid identifier for this record type.
  /// For UUID-keyed conformers (everything except `InstrumentRow`) this means
  /// `recordID.uuid == nil`. `InstrumentRow` is keyed by `recordID.recordName`, which
  /// is always present on a valid `CKRecord.ID`, so it never returns `nil`.
  ///
  /// Callers are expected to log and skip when this returns `nil` so a malformed incoming
  /// record surfaces as an error rather than a phantom row with a fresh random id.
  static func fieldValues(from ckRecord: CKRecord) -> Self?
}

/// Protocol for records that have a UUID `id` property.
/// Used by `buildCKRecord` to look up cached system fields by record name.
protocol IdentifiableRecord {
  var id: UUID { get }
}

// `InstrumentRow` is string-keyed; no `IdentifiableRecord` conformance.
extension ProfileRow: IdentifiableRecord {}
extension AccountRow: IdentifiableRecord {}
extension AccountGroupRow: IdentifiableRecord {}
extension InsightDismissalRow: IdentifiableRecord {}
extension TransactionRow: IdentifiableRecord {}
extension TransactionLegRow: IdentifiableRecord {}
extension CategoryRow: IdentifiableRecord {}
extension TransferSuggestionRow: IdentifiableRecord {}
extension EarmarkRow: IdentifiableRecord {}
extension EarmarkBudgetItemRow: IdentifiableRecord {}
extension InvestmentValueRow: IdentifiableRecord {}
extension CSVImportProfileRow: IdentifiableRecord {}
extension ImportRuleRow: IdentifiableRecord {}

/// Protocol exposing the cached CKRecord change-tag blob from a GRDB
/// row struct. All record types (including `ProfileRow`) write system
/// fields back through the repository's
/// `setEncodedSystemFieldsSync(id:data:)` SQL UPDATE rather than mutating
/// the in-memory row, so this protocol is read-only. It lets the
/// upload-side `mapBuiltRows(_:)` path read the blob through a single
/// typed constraint instead of a dynamic-type cast chain.
protocol ValueTypeSystemFieldsReadable {
  var encodedSystemFields: Data? { get }
}

extension ProfileRow: ValueTypeSystemFieldsReadable {}
extension CSVImportProfileRow: ValueTypeSystemFieldsReadable {}
extension ImportRuleRow: ValueTypeSystemFieldsReadable {}
extension InstrumentRow: ValueTypeSystemFieldsReadable {}
extension AccountRow: ValueTypeSystemFieldsReadable {}
extension AccountGroupRow: ValueTypeSystemFieldsReadable {}
extension InsightDismissalRow: ValueTypeSystemFieldsReadable {}
extension CategoryRow: ValueTypeSystemFieldsReadable {}
extension TransferSuggestionRow: ValueTypeSystemFieldsReadable {}
extension EarmarkRow: ValueTypeSystemFieldsReadable {}
extension EarmarkBudgetItemRow: ValueTypeSystemFieldsReadable {}
extension TransactionRow: ValueTypeSystemFieldsReadable {}
extension TransactionLegRow: ValueTypeSystemFieldsReadable {}
extension InvestmentValueRow: ValueTypeSystemFieldsReadable {}

// MARK: - CKRecord System Fields

extension CKRecord {
  /// Encodes the record's system fields (including the change tag) for caching.
  /// Used to preserve change tags across uploads and avoid `.serverRecordChanged` conflicts.
  var encodedSystemFields: Data {
    let coder = NSKeyedArchiver(requiringSecureCoding: true)
    encodeSystemFields(with: coder)
    coder.finishEncoding()
    return coder.encodedData
  }

  /// Creates a CKRecord from cached system fields.
  /// Returns nil if the data is invalid.
  static func fromEncodedSystemFields(_ data: Data) -> CKRecord? {
    guard let coder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
    coder.requiresSecureCoding = true
    return CKRecord(coder: coder)
  }

  /// Decodes the server-assigned `modificationDate` carried in a cached
  /// `encoded_system_fields` blob, or `nil` when the blob is absent /
  /// undecodable / carries no date. The modification-date gate (issue
  /// #1085) uses this to learn the server version a clean row currently
  /// holds: an incoming echo is applied only when its own
  /// `modificationDate` is strictly newer. A `nil` here means fail-open
  /// (apply), so a genuine first sync or a dateless blob is never
  /// rejected.
  static func modificationDate(fromEncodedSystemFields data: Data?) -> Date? {
    guard let data, let record = fromEncodedSystemFields(data) else { return nil }
    return record.modificationDate
  }

  /// True when `self` and `other` carry identical user-field values
  /// (system fields / change tag ignored). Used by the upload-ack path to
  /// decide whether a row changed locally since the version that was
  /// uploaded: if the current row's `toCKRecord` still matches the saved
  /// record, the local edit has been confirmed and `needs_push` can be
  /// cleared; if a field differs, a newer edit is pending and the flag
  /// stays set (issue #1081). CKRecord user values are CloudKit-native
  /// types bridged to `NSObject` (`NSString`/`NSNumber`/`NSData`/`NSDate`),
  /// so `isEqual` compares them correctly.
  func hasSameUserFields(as other: CKRecord) -> Bool {
    let keys = Set(allKeys()).union(other.allKeys())
    for key in keys {
      let lhs = self[key] as? NSObject
      let rhs = other[key] as? NSObject
      if lhs != rhs { return false }
    }
    return true
  }
}

// MARK: - Lookup Helper

/// Maps CKRecord.recordType strings to the corresponding record types for dispatching.
enum RecordTypeRegistry: Sendable {
  static let allTypes: [String: any CloudKitRecordConvertible.Type] = [
    // Every record type dispatches to its GRDB row type. The CloudKit
    // wire `recordType` strings are frozen contracts that the schema
    // depends on; do not rename them when refactoring the local Swift
    // types bound to each key.
    ProfileRow.recordType: ProfileRow.self,
    InstrumentRow.recordType: InstrumentRow.self,
    AccountRow.recordType: AccountRow.self,
    AccountGroupRow.recordType: AccountGroupRow.self,
    InsightDismissalRow.recordType: InsightDismissalRow.self,
    TransactionRow.recordType: TransactionRow.self,
    TransactionLegRow.recordType: TransactionLegRow.self,
    CategoryRow.recordType: CategoryRow.self,
    TransferSuggestionRow.recordType: TransferSuggestionRow.self,
    EarmarkRow.recordType: EarmarkRow.self,
    EarmarkBudgetItemRow.recordType: EarmarkBudgetItemRow.self,
    InvestmentValueRow.recordType: InvestmentValueRow.self,
    CSVImportProfileRow.recordType: CSVImportProfileRow.self,
    ImportRuleRow.recordType: ImportRuleRow.self,
  ]
}
