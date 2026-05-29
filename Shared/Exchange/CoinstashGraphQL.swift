import Foundation

/// Coinstash GraphQL endpoint, query strings, and response models.
enum CoinstashGraphQL {
  /// Coinstash GraphQL endpoint.
  ///
  /// String-literal URL: a parse failure is a programming error, not runtime input.
  static let endpoint = URL(string: "https://graph.coinstash.com.au/graphql")!  // swiftlint:disable:this force_unwrapping

  /// Fetches the authenticated user's profile.
  ///
  /// Decodes into `CoinstashGraphQLResponse<CoinstashUserProfileData>`.
  static let userProfileQuery = """
    query { userProfile { userId } }
    """

  /// Fetches all exchange accounts for the given user.
  ///
  /// Required variable: `$userId` (ID) — the `userId` from `userProfileQuery`.
  /// Decodes into `CoinstashGraphQLResponse<CoinstashUserAccountsData>`.
  static let userAccountsQuery = """
    query Q($userId: ID!) {
      getUserAccounts(userId: $userId) { accounts { accountId accountType } }
    }
    """

  /// Fetches a page of transactions for the given account.
  ///
  /// Required variables:
  /// - `$a` (ID) — the account ID.
  /// - `$p` (SearchAccountTransactionsPayloadInput) — pagination / filter payload.
  /// Decodes into `CoinstashGraphQLResponse<CoinstashTransactionsData>`.
  /// `symbol` is the per-leg currency (always populated). `assetSymbol`
  /// (the order's traded asset) is `null` on `DEPOSIT`/`WITHDRAW`/`AWARD`
  /// rows, so it is deliberately not selected — resolution keys off
  /// `symbol`.
  static let transactionsQuery = """
    query Q($a: ID!, $p: SearchAccountTransactionsPayloadInput) {
      accountTransactions(accountId: $a, searchAccountTransactionsPayloadInput: $p) {
        isSuccessful errorMessage totalRecordsFound
        result { transactionId transactedOn category type symbol
                 amount amountType quoteBuyPrice quoteSellPrice
                 orderId orderType transactionStatus }
      }
    }
    """

  /// Token metadata for a Coinstash symbol. The per-transaction `chain`
  /// field is unreliable (observed null/empty live 2026-05-17), so the
  /// chain + contract come from here. `defiAddresses` is the per-chain
  /// contract list; `[]` for non-EVM-modelled assets (e.g. BTC).
  /// Decodes into `CoinstashGraphQLResponse<CoinstashCoinData>`.
  static let coinBySymbolQuery = """
    query Q($s: String!) {
      getCoinBySymbol(symbol: $s) {
        symbol name
        defiAddresses { chain address decimals }
      }
    }
    """
}

struct CoinstashGraphQLError: Decodable, Sendable { let message: String }

struct CoinstashGraphQLResponse<T: Decodable & Sendable>: Decodable, Sendable {
  let data: T?
  // GraphQL: the "errors" key is absent on success; absent = empty here.
  let errors: [CoinstashGraphQLError]

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    data = try container.decodeIfPresent(T.self, forKey: .data)
    errors = try container.decodeIfPresent([CoinstashGraphQLError].self, forKey: .errors) ?? []
  }

  private enum CodingKeys: CodingKey { case data, errors }
}

struct CoinstashUserProfileData: Decodable, Sendable {
  struct Profile: Decodable, Sendable { let userId: String }

  let userProfile: Profile
}

struct CoinstashUserAccountsData: Decodable, Sendable {
  struct AccountSummary: Decodable, Sendable {
    let accountId: String
    let accountType: String
  }

  struct UserAccountsPayload: Decodable, Sendable {
    let accounts: [AccountSummary]
  }

  let getUserAccounts: UserAccountsPayload
}

struct CoinstashTransaction: Decodable, Sendable, Hashable {
  let transactionId: String
  let transactedOn: String
  let category: String
  let type: String
  /// The leg's currency symbol (e.g. `AUD`, `OP`, `BTC`). Always present on
  /// real rows; optional only to tolerate an absent field defensively.
  let symbol: String?
  // Decimal (not Double): JSONDecoder decodes a bare JSON number into
  // Decimal losslessly. Double would corrupt amounts (3518.46 →
  // 3518.4599999999998) before they ever reach a TransactionLeg.
  let amount: Decimal
  let amountType: String
  let quoteBuyPrice: Decimal?
  let quoteSellPrice: Decimal?
  let orderId: String?
  let orderType: String?
  let transactionStatus: String
}

struct CoinstashTransactionsData: Decodable, Sendable {
  struct Page: Decodable, Sendable {
    let isSuccessful: Bool
    let errorMessage: String?
    let totalRecordsFound: Int
    let result: [CoinstashTransaction]
  }

  let accountTransactions: Page
}

struct CoinstashDefiAddress: Decodable, Sendable, Hashable {
  let chain: String
  /// Optional defensively: a malformed row must not fail the whole decode.
  let address: String?
  let decimals: Int?
}

struct CoinstashCoinMetadata: Decodable, Sendable, Hashable {
  let symbol: String
  let name: String
  let defiAddresses: [CoinstashDefiAddress]
}

struct CoinstashCoinData: Decodable, Sendable {
  /// `null` when Coinstash does not recognise the symbol.
  let getCoinBySymbol: CoinstashCoinMetadata?
}
