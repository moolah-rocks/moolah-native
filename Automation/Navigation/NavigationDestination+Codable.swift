import Foundation

extension NavigationDestination: Codable {

  private enum CodingKeys: String, CodingKey {
    case type, id, history, forecast, from, to
  }

  private enum Kind: String, Codable {
    case accounts, account, transaction, earmarks, earmark
    case analysis, reports, categories, upcoming
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let kind = try container.decode(Kind.self, forKey: .type)
    switch kind {
    case .accounts:
      self = .accounts
    case .account:
      self = .account(try container.decode(UUID.self, forKey: .id))
    case .transaction:
      self = .transaction(try container.decode(UUID.self, forKey: .id))
    case .earmarks:
      self = .earmarks
    case .earmark:
      self = .earmark(try container.decode(UUID.self, forKey: .id))
    case .analysis:
      self = .analysis(
        history: try container.decodeIfPresent(Int.self, forKey: .history),
        forecast: try container.decodeIfPresent(Int.self, forKey: .forecast))
    case .reports:
      self = .reports(
        from: try container.decodeIfPresent(Date.self, forKey: .from),
        to: try container.decodeIfPresent(Date.self, forKey: .to))
    case .categories:
      self = .categories
    case .upcoming:
      self = .upcoming
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .accounts:
      try container.encode(Kind.accounts, forKey: .type)
    case .account(let id):
      try container.encode(Kind.account, forKey: .type)
      try container.encode(id, forKey: .id)
    case .transaction(let id):
      try container.encode(Kind.transaction, forKey: .type)
      try container.encode(id, forKey: .id)
    case .earmarks:
      try container.encode(Kind.earmarks, forKey: .type)
    case .earmark(let id):
      try container.encode(Kind.earmark, forKey: .type)
      try container.encode(id, forKey: .id)
    case let .analysis(history, forecast):
      try container.encode(Kind.analysis, forKey: .type)
      try container.encodeIfPresent(history, forKey: .history)
      try container.encodeIfPresent(forecast, forKey: .forecast)
    case let .reports(from, to):
      try container.encode(Kind.reports, forKey: .type)
      try container.encodeIfPresent(from, forKey: .from)
      try container.encodeIfPresent(to, forKey: .to)
    case .categories:
      try container.encode(Kind.categories, forKey: .type)
    case .upcoming:
      try container.encode(Kind.upcoming, forKey: .type)
    }
  }
}
