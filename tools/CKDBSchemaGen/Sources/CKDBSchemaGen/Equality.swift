import Foundation

/// Checks whether two `Schema`s are semantically equal: same set of record
/// types, each with the same fields, types, and indexes.
///
/// Deprecation flags are **not** part of the comparison. A `// DEPRECATED`
/// marker is a repo-local annotation on `schema.ckdb` that drives wire-struct
/// codegen; CloudKit has no server-side equivalent, so a live
/// `cktool export-schema` never reports it. Including it would make the
/// `verify-prod-deployed` gate permanently fail after any deprecation.
///
/// Order of record types and order of fields within a record type are
/// **not** significant — cktool's `export-schema` returns record types in a
/// stable but non-deterministic order (chronological by creation time, in
/// practice), and column-alignment whitespace is normalised differently
/// between human-edited `.ckdb` files and cktool's exported form. Both
/// sources need to agree semantically; comparing them byte-equal would
/// reject correct deploys.
enum Equality {

  struct Result: Equatable {
    var differences: [String]

    var isEqual: Bool { differences.isEmpty }
  }

  /// Compare two schemas. Returns differences sorted for stable output —
  /// missing record types first, then missing fields, then field-level
  /// differences within each shared record type.
  static func check(_ a: Schema, _ b: Schema, aLabel: String = "a", bLabel: String = "b") -> Result
  {
    var differences: [String] = []

    let aTypes = Dictionary(uniqueKeysWithValues: a.recordTypes.map { ($0.name, $0) })
    let bTypes = Dictionary(uniqueKeysWithValues: b.recordTypes.map { ($0.name, $0) })

    let onlyInA = Set(aTypes.keys).subtracting(bTypes.keys).sorted()
    let onlyInB = Set(bTypes.keys).subtracting(aTypes.keys).sorted()
    for name in onlyInA {
      differences.append("record type '\(name)' is in \(aLabel) but not in \(bLabel)")
    }
    for name in onlyInB {
      differences.append("record type '\(name)' is in \(bLabel) but not in \(aLabel)")
    }

    let common = Set(aTypes.keys).intersection(bTypes.keys).sorted()
    for name in common {
      // Force-unwrap is safe — name comes from the intersection.
      let aType = aTypes[name]!
      let bType = bTypes[name]!
      differences.append(
        contentsOf: differencesForRecordType(
          aType, bType, aLabel: aLabel, bLabel: bLabel))
    }

    return Result(differences: differences)
  }

  private static func differencesForRecordType(
    _ a: RecordType, _ b: RecordType, aLabel: String, bLabel: String
  ) -> [String] {
    var differences: [String] = []
    let typeName = a.name

    // Deprecation is intentionally NOT compared. A `// DEPRECATED` marker is a
    // repo-local annotation on `schema.ckdb` (it drives wire-struct codegen);
    // CloudKit has no server-side notion of it, so a live `cktool export-schema`
    // never carries it. Comparing the flag would make `verify-prod-deployed`
    // permanently fail after any field/record deprecation, even though the
    // deployed shape is correct (the field stays in Production either way).

    let aFields = Dictionary(uniqueKeysWithValues: a.fields.map { ($0.name, $0) })
    let bFields = Dictionary(uniqueKeysWithValues: b.fields.map { ($0.name, $0) })

    let onlyInA = Set(aFields.keys).subtracting(bFields.keys).sorted()
    let onlyInB = Set(bFields.keys).subtracting(aFields.keys).sorted()
    for fieldName in onlyInA {
      differences.append(
        "field '\(typeName).\(fieldName)' is in \(aLabel) but not in \(bLabel)")
    }
    for fieldName in onlyInB {
      differences.append(
        "field '\(typeName).\(fieldName)' is in \(bLabel) but not in \(aLabel)")
    }

    let commonFields = Set(aFields.keys).intersection(bFields.keys).sorted()
    for fieldName in commonFields {
      // Force-unwrap is safe — fieldName comes from the intersection.
      let aField = aFields[fieldName]!
      let bField = bFields[fieldName]!

      if aField.type != bField.type {
        differences.append(
          "field '\(typeName).\(fieldName)': type differs "
            + "(\(aLabel)=\(aField.type.rawValue), \(bLabel)=\(bField.type.rawValue))")
      }

      if aField.indexes != bField.indexes {
        let aOnly = aField.indexes.subtracting(bField.indexes)
        let bOnly = bField.indexes.subtracting(aField.indexes)
        var parts: [String] = []
        if !aOnly.isEmpty {
          let names = aOnly.map(\.rawValue).sorted().joined(separator: ",")
          parts.append("\(aLabel)-only=\(names)")
        }
        if !bOnly.isEmpty {
          let names = bOnly.map(\.rawValue).sorted().joined(separator: ",")
          parts.append("\(bLabel)-only=\(names)")
        }
        differences.append(
          "field '\(typeName).\(fieldName)': indexes differ (\(parts.joined(separator: "; ")))")
      }

      // Field deprecation is deliberately not compared — see the note above.
    }

    return differences
  }
}
