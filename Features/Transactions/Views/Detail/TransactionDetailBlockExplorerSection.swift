import SwiftUI

/// "Block explorer" section in the transaction detail. Shown when at
/// least one of the transaction's legs has an `externalId` (the on-chain
/// tx hash recorded by the wallet importer) and a resolvable chain id.
/// One link per **unique on-chain hash**: a wallet-imported transaction
/// typically has multiple legs (e.g. transfer + gas) that all share the
/// same hash, so a single explorer link covers the whole transaction.
/// On the rare path where legs span multiple hashes, each unique URL
/// renders once.
///
/// We deliberately render this as plain `Link` rows rather than a
/// stylised "Open in Etherscan" pill: explorers across chains use
/// different domains, and the brand-neutral "View on block explorer"
/// label avoids privileging any one service in our UI.
struct TransactionDetailBlockExplorerSection: View {
  let transaction: Transaction
  /// The account collection from the enclosing transaction-detail view,
  /// used to resolve each leg's owning-account chain. A plain value
  /// collection (not a store), so threading it here keeps the view thin.
  let accounts: Accounts

  /// Whether the section should render at all. Hidden when no leg has
  /// a usable explorer link so the section header doesn't appear empty.
  var isApplicable: Bool { !explorerURLs.isEmpty }

  var body: some View {
    let urls = explorerURLs
    if !urls.isEmpty {
      Section("Block Explorer") {
        ForEach(urls, id: \.self) { url in
          Link(destination: url) {
            Label("View on block explorer", systemImage: "arrow.up.right.square")
          }
          .accessibilityIdentifier(UITestIdentifiers.Detail.blockExplorerLink)
        }
      }
    }
  }
}

extension TransactionDetailBlockExplorerSection {
  /// Distinct explorer URLs for this transaction's legs, resolving each
  /// leg's chain from its owning account first — see
  /// `BlockExplorerLink.explorerURLs(for:accountChainId:)` for the
  /// three-tier chain selection and per-hash dedup.
  private var explorerURLs: [URL] {
    BlockExplorerLink.explorerURLs(for: transaction.legs) { accounts.by(id: $0)?.chainId }
  }
}
