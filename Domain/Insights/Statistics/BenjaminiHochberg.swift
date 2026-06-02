import Foundation

/// One hypothesis fed into the Benjamini-Hochberg procedure, tagged so the
/// caller can recover which item each p-value belonged to.
struct PValue<Tag: Hashable & Sendable>: Sendable, Hashable {
  let tag: Tag
  let pValue: Double
}

/// Benjamini-Hochberg false-discovery-rate control. The design (§C-10)
/// requires it before surfacing per-category trend tests: testing 30
/// categories at α=0.05 yields ~1.5 false positives per refresh with no
/// correction, which reads as alert spam.
enum BenjaminiHochberg {
  /// Return the subset of `hypotheses` whose discoveries survive FDR control
  /// at level `fdr`. Standard step-up procedure: sort ascending by p-value,
  /// find the largest rank `k` with `p₍ₖ₎ ≤ (k/m)·fdr`, reject all
  /// hypotheses with that p-value or smaller.
  static func significant<Tag>(
    _ hypotheses: [PValue<Tag>], fdr: Double = 0.05
  ) -> [PValue<Tag>] {
    guard !hypotheses.isEmpty else { return [] }
    let sorted = hypotheses.sorted { $0.pValue < $1.pValue }
    let total = Double(sorted.count)

    var threshold = -1
    for (index, hypothesis) in sorted.enumerated() {
      let rank = Double(index + 1)
      if hypothesis.pValue <= (rank / total) * fdr {
        threshold = index
      }
    }
    guard threshold >= 0 else { return [] }
    return Array(sorted.prefix(threshold + 1))
  }
}
