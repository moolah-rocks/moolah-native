#if os(macOS)
  import Foundation

  /// Immutable domain values shared by one generation of AppleScript wrappers.
  /// The snapshot contains no wrappers, so lazy account-to-transaction traversal
  /// cannot form a reference cycle through transaction legs.
  struct ScriptableProfileSnapshot: Sendable {
    let profileName: String

    private let accounts: [Account]
    private let transactions: [Transaction]
    private let categories: [Category]
    private let earmarks: [Earmark]

    @MainActor
    init(session: ProfileSession) {
      profileName = session.profile.label
      accounts = session.accountStore.accounts.ordered
      transactions = session.transactionStore.transactions.map(\.transaction)
      categories = session.categoryStore.categories.flattenedByPath().map(\.category)
      earmarks = session.earmarkStore.earmarks.ordered
    }

    private init(
      profileName: String,
      accounts: [Account],
      transactions: [Transaction],
      categories: [Category],
      earmarks: [Earmark]
    ) {
      self.profileName = profileName
      self.accounts = accounts
      self.transactions = transactions
      self.categories = categories
      self.earmarks = earmarks
    }

    func account(id: UUID) -> Account? {
      accounts.first { $0.id == id }
    }

    func category(id: UUID) -> Category? {
      categories.first { $0.id == id }
    }

    func earmark(id: UUID) -> Earmark? {
      earmarks.first { $0.id == id }
    }

    func parentName(for category: Category) -> String {
      guard let parentID = category.parentId else { return "" }
      return categories.first { $0.id == parentID }?.name ?? ""
    }

    func transactions(for accountID: UUID) -> [Transaction] {
      transactions.filter { transaction in
        transaction.legs.contains { $0.accountId == accountID }
      }
    }

    func including(account: Account) -> Self {
      var updatedAccounts = accounts
      if let index = updatedAccounts.firstIndex(where: { $0.id == account.id }) {
        updatedAccounts[index] = account
      } else {
        updatedAccounts.append(account)
      }
      return Self(
        profileName: profileName,
        accounts: updatedAccounts,
        transactions: transactions,
        categories: categories,
        earmarks: earmarks)
    }

    func including(transaction: Transaction) -> Self {
      including(transactions: [transaction])
    }

    func including(transactions newTransactions: [Transaction]) -> Self {
      var updatedTransactions = transactions
      for transaction in newTransactions {
        if let index = updatedTransactions.firstIndex(where: { $0.id == transaction.id }) {
          updatedTransactions[index] = transaction
        } else {
          updatedTransactions.append(transaction)
        }
      }
      return Self(
        profileName: profileName,
        accounts: accounts,
        transactions: updatedTransactions,
        categories: categories,
        earmarks: earmarks)
    }
  }
#endif
