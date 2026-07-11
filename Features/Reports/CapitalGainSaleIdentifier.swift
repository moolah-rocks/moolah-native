import Foundation

enum CapitalGainSaleIdentifier: Hashable {
  case transaction(UUID, instrumentId: String, taxOwnerId: UUID?)
  case fallback(String)
}
