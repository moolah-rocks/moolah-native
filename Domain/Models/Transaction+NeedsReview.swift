import Foundation

extension Transaction {
  /// `true` when the transaction has category-bearing income/expense legs
  /// and none is categorised. Transfers, trades without fees, and opening
  /// balances have no applicable category action, so they are already clear.
  var needsReview: Bool {
    needsReview(excluding: [])
  }

  /// Spam-only transactions are intentionally hidden from the review
  /// backlog. Mixed transactions remain reviewable because a non-spam fee
  /// or cash leg can still require a category.
  func needsReview(excluding spamInstruments: Set<Instrument>) -> Bool {
    guard !isAllSpam(in: spamInstruments) else { return false }
    let categorizableLegs = legs.filter { $0.type == .income || $0.type == .expense }
    return !categorizableLegs.isEmpty
      && categorizableLegs.allSatisfy { $0.categoryId == nil }
  }
}
