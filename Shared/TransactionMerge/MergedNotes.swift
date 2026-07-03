import Foundation

/// Merges transaction notes: splits each note into lines, drops
/// duplicate lines (keeping first occurrence), and rejoins with
/// newlines in the given order. Returns `nil` when no input note is
/// present. Shared by `TransactionMergeBuilder` (N inputs) and
/// `TransferMergeBuilder` (two inputs) so the dedup rule lives once.
func mergedNotes(_ notes: [String?]) -> String? {
  let present = notes.compactMap { $0 }
  guard !present.isEmpty else { return nil }
  var seen: Set<String> = []
  let lines = present.flatMap { $0.components(separatedBy: "\n") }
  let deduped = lines.filter { seen.insert($0).inserted }
  return deduped.joined(separator: "\n")
}
