import Foundation

// SyncBoundary — adding a case requires bumping DataFormatVersion.current.
enum AccountType: String, Codable, Sendable, CaseIterable {
  case bank
  case creditCard = "cc"
  case asset
  case investment
  case crypto
  case exchange

  var isCurrent: Bool {
    self == .bank || self == .asset || self == .creditCard
  }

  /// Whether this type should be treated as an investment account for sidebar
  /// grouping and any query that filters investments. `true` for `.investment`,
  /// `.crypto`, and `.exchange`.
  var isInvestmentLike: Bool {
    self == .investment || self == .crypto || self == .exchange
  }

  /// Whether this account type is populated by an external sync source
  /// (crypto wallets via `WalletSyncSource`, exchange accounts via a
  /// provider source such as `CoinstashSyncSource`) rather than manual
  /// entry. A coarse type-level pre-filter — the sync store still asks each
  /// source `handles(_:)` for the precise check (wallet address / chain id,
  /// exchange provider). Exhaustive switch so a new `AccountType` case (a
  /// SyncBoundary change) is forced to make a sync decision here.
  var isSynced: Bool {
    switch self {
    case .crypto, .exchange: return true
    case .bank, .creditCard, .asset, .investment: return false
    }
  }

  /// Sidebar bucket this type belongs to. Exhaustive switch so a new
  /// `AccountType` case (a SyncBoundary change) is forced to make a
  /// bucket decision here.
  var bucket: AccountBucket {
    switch self {
    case .bank, .creditCard, .asset: return .current
    case .investment, .crypto, .exchange: return .investments
    }
  }

  var displayName: String {
    switch self {
    case .bank: return "Bank Account"
    case .creditCard: return "Credit Card"
    case .asset: return "Asset"
    case .investment: return "Investment"
    case .crypto: return "Crypto Wallet"
    case .exchange: return "Exchange"
    }
  }
}

struct Account {
  let id: UUID
  var name: String
  var type: AccountType
  var instrument: Instrument
  var positions: [Position]
  var position: Int
  var isHidden: Bool
  /// `0x…` lowercased wallet address. Required when `type == .crypto`.
  var walletAddress: String?
  /// EVM chain ID (1 = Ethereum, 10 = OP, 8453 = Base, 137 = Polygon).
  /// Required when `type == .crypto`.
  var chainId: Int?
  /// Provider for a centralised-exchange account. Required when
  /// `type == .exchange`; nil otherwise.
  var exchangeProvider: ExchangeProvider?
  var valuationMode: ValuationMode

  init(
    id: UUID = UUID(),
    name: String,
    type: AccountType,
    instrument: Instrument,
    positions: [Position] = [],
    position: Int = 0,
    isHidden: Bool = false,
    valuationMode: ValuationMode = .recordedValue,
    walletAddress: String? = nil,
    chainId: Int? = nil,
    exchangeProvider: ExchangeProvider? = nil
  ) {
    self.id = id
    self.name = name
    self.type = type
    self.instrument = instrument
    self.positions = positions
    self.position = position
    self.isHidden = isHidden
    self.valuationMode = valuationMode
    self.walletAddress = walletAddress
    self.chainId = chainId
    self.exchangeProvider = exchangeProvider
  }
}

extension Account: Sendable {}

extension Account: Identifiable {}

extension Account: Codable {
  private enum CodingKeys: String, CodingKey {
    case id
    case name
    case type
    case instrument
    case position
    case isHidden = "hidden"
    case valuationMode
    case walletAddress
    case chainId
    case exchangeProvider
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    name = try container.decode(String.self, forKey: .name)
    // Strict decode for `type`: throws on unknown raw values. The
    // forward-compat path for an older build encountering a future
    // `AccountType` is the `Profile.dataFormatVersion` gate
    // (`Domain/Models/DataFormatVersion.swift`) — a newer client must
    // bump that field before writing records that use the new type, so
    // an older build refuses to open the profile rather than silently
    // misclassifying records. The wire-layer apply path
    // (`AccountRow.safeAccountTypeRaw`) keeps a `"asset"` fallback to
    // unblock GRDB persistence between record-arrival ordering, but
    // the in-memory domain decode (used by tests, exports, archives)
    // is strict.
    type = try container.decode(AccountType.self, forKey: .type)
    instrument = try container.decodeIfPresent(Instrument.self, forKey: .instrument) ?? .AUD
    // positions are not persisted via Codable — they are computed by the
    // repository layer from transaction legs and injected at fetch time.
    positions = []
    position = try container.decode(Int.self, forKey: .position)
    isHidden = try container.decode(Bool.self, forKey: .isHidden)
    valuationMode =
      try container.decodeIfPresent(ValuationMode.self, forKey: .valuationMode) ?? .recordedValue
    walletAddress = try container.decodeIfPresent(String.self, forKey: .walletAddress)
    chainId = try container.decodeIfPresent(Int.self, forKey: .chainId)
    exchangeProvider = try container.decodeIfPresent(
      ExchangeProvider.self, forKey: .exchangeProvider)
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(name, forKey: .name)
    try container.encode(type, forKey: .type)
    try container.encode(instrument, forKey: .instrument)
    try container.encode(position, forKey: .position)
    try container.encode(isHidden, forKey: .isHidden)
    try container.encode(valuationMode, forKey: .valuationMode)
    try container.encodeIfPresent(walletAddress, forKey: .walletAddress)
    try container.encodeIfPresent(chainId, forKey: .chainId)
    try container.encodeIfPresent(exchangeProvider, forKey: .exchangeProvider)
  }
}

extension Account: Hashable {
  static func == (lhs: Account, rhs: Account) -> Bool {
    lhs.id == rhs.id && lhs.name == rhs.name && lhs.type == rhs.type
      && lhs.instrument == rhs.instrument
      && lhs.position == rhs.position && lhs.isHidden == rhs.isHidden
      && lhs.valuationMode == rhs.valuationMode
      && lhs.walletAddress == rhs.walletAddress && lhs.chainId == rhs.chainId
      && lhs.exchangeProvider == rhs.exchangeProvider
      && lhs.positions == rhs.positions
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(id)
    hasher.combine(name)
    hasher.combine(type)
    hasher.combine(instrument)
    hasher.combine(position)
    hasher.combine(isHidden)
    hasher.combine(valuationMode)
    hasher.combine(walletAddress)
    hasher.combine(chainId)
    hasher.combine(exchangeProvider)
    hasher.combine(positions)
  }
}

extension Account: Comparable {
  static func < (lhs: Account, rhs: Account) -> Bool {
    lhs.position < rhs.position
  }
}

struct Accounts: RandomAccessCollection, Sendable {
  let startIndex: Int = 0

  let ordered: [Account]
  let byId: [UUID: Account]

  init(from: [Account]) {
    byId = from.reduce(into: [:]) { $0[$1.id] = $1 }
    ordered = from.sorted()
  }

  func by(id: UUID) -> Account? {
    byId[id]
  }

  /// Returns a new Accounts collection with positions adjusted by instrument deltas.
  func adjustingPositions(of accountId: UUID, by deltas: [Instrument: Decimal]) -> Accounts {
    guard byId[accountId] != nil else { return self }
    let adjusted = ordered.map { account in
      guard account.id == accountId else { return account }
      var copy = account
      copy.positions = copy.positions.applying(deltas: deltas)
      return copy
    }
    return Accounts(from: adjusted)
  }

  var endIndex: Int {
    ordered.count
  }

  subscript(idex: Int) -> Account {
    ordered[idex]
  }
}
