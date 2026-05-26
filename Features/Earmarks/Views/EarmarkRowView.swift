import SwiftUI

struct EarmarkRowView: View {
  let earmark: Earmark
  var isSelected: Bool = false
  var isEditing: Binding<Bool>?
  var onRename: ((String) -> Void)?
  @Environment(EarmarkStore.self) private var earmarkStore

  var body: some View {
    SidebarRowView(
      icon: "bookmark.fill",
      name: earmark.name,
      amount: earmarkStore.convertedBalance(for: earmark.id)
        ?? .zero(instrument: earmark.instrument),
      isSelected: isSelected,
      isEditing: isEditing,
      onRename: onRename
    )
  }
}

#Preview {
  let backend = PreviewBackend.create()
  let earmarkStore = EarmarkStore(
    repository: backend.earmarks,
    conversionService: backend.conversionService,
    targetInstrument: .AUD)

  List {
    EarmarkRowView(
      earmark: Earmark(
        name: "Holiday Fund",
        instrument: .AUD,
        savingsGoal: InstrumentAmount(quantity: 5000, instrument: .AUD)
      ))
    EarmarkRowView(
      earmark: Earmark(
        name: "Emergency Fund",
        instrument: .AUD
      ))
  }
  .environment(earmarkStore)
}
