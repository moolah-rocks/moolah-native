import SwiftUI

private struct TaxOwnerManagementPreviewHost: View {
  @State private var store: TaxOwnerStore

  init(profile: Profile, owners: [TaxOwner]) {
    _store = State(
      initialValue: TaxOwnerStore(
        profile: profile,
        repository: PreviewTaxOwnerRepository(owners: owners)
      ) { _ in })
  }

  var body: some View {
    Form {
      TaxOwnerManagementSection(store: store)
    }
    .formStyle(.grouped)
    .task {
      try? await store.loadOwners()
    }
  }
}

#Preview("Tax owner management — multiple owners") {
  let defaultOwnerId = taxOwnerManagementPreviewUUID("11111111-1111-1111-1111-111111111111")
  let trustOwnerId = taxOwnerManagementPreviewUUID("22222222-2222-2222-2222-222222222222")
  TaxOwnerManagementPreviewHost(
    profile: Profile(label: "Family", defaultTaxOwnerId: defaultOwnerId),
    owners: [
      TaxOwner(id: defaultOwnerId, name: "Alex", kind: .individual),
      TaxOwner(id: trustOwnerId, name: "Family Trust", kind: .trust),
    ])
}

private func taxOwnerManagementPreviewUUID(_ literal: String) -> UUID {
  guard let uuid = UUID(uuidString: literal) else {
    fatalError("Invalid tax owner management preview UUID")
  }
  return uuid
}
