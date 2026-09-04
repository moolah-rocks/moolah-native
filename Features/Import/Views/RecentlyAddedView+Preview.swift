import SwiftUI

// Preview support for `RecentlyAddedView` lives below.
extension RecentlyAddedView {}

@MainActor
private struct RecentlyAddedPopulatedPreview: View {
  @Environment(ProfileSession.self) private var session

  var body: some View {
    RecentlyAddedView(backend: session.backend)
  }
}

@MainActor
private struct RecentlyAddedPreviewModifier: PreviewModifier {
  static func makeSharedContext() async throws -> ProfileSession {
    let session = try ProfileSession.preview()
    try await seedRecentlyAddedPreview(session: session)
    _ = await session.importStore.ingest(
      data: Data(),
      source: .droppedFile(
        url: URL(fileURLWithPath: "/tmp/Unsupported statement.csv"),
        forcedAccountId: nil))
    await session.transactionStore.load(
      filter: TransactionFilter(
        importedAtRange: Date().addingTimeInterval(-86_400)...Date.distantFuture))
    return session
  }

  func body(content: Content, context: ProfileSession) -> some View {
    content
      .environment(context.accountStore)
      .environment(context.transactionStore)
      .environment(context.categoryStore)
      .environment(context.earmarkStore)
      .previewProfileEnvironment(session: context)
  }
}

@MainActor
private func seedRecentlyAddedPreview(session: ProfileSession) async throws {
  let account = try await session.backend.accounts.create(
    Account(
      name: "Crypto Wallet",
      type: .crypto,
      instrument: .AUD,
      walletAddress: "0x1234567890abcdef",
      chainId: 1))
  _ = try await session.backend.transactions.create(
    Transaction(
      date: Date().addingTimeInterval(-86_400),
      legs: [
        TransactionLeg(
          accountId: account.id,
          instrument: .AUD,
          quantity: 42,
          externalId: "preview-wallet-transaction",
          type: .income)
      ],
      importOrigin: .single(
        ImportOrigin(
          rawDescription: "wallet:0x1234567890abcdef",
          rawAmount: 42,
          importedAt: Date(),
          importSessionId: UUID(),
          parserIdentifier: BackgroundSyncSource.wallet.parserIdentifier))))
}

#Preview(
  "Recently Added — populated standard row",
  traits: .modifier(RecentlyAddedPreviewModifier())
) {
  NavigationStack {
    RecentlyAddedPopulatedPreview()
  }
  .frame(width: 1_000, height: 650)
}
