import SwiftUI

struct TransactionTypeMultiSelectPicker: View {
  @Binding var selectedTypes: Set<TransactionType>

  var body: some View {
    LabeledContent("Types") {
      Menu {
        Button("All Types") {
          selectedTypes = []
        }
        .disabled(selectedTypes.isEmpty)

        Divider()

        ForEach(TransactionType.allCases, id: \.self) { type in
          Toggle(type.displayName, isOn: selectionBinding(for: type))
        }
      } label: {
        Text(selectionSummary)
          .foregroundStyle(.primary)
          .lineLimit(1)
      }
      .buttonStyle(.borderless)
      .accessibilityLabel("Transaction types")
      .accessibilityValue(selectionSummary)
      .accessibilityHint("Opens the transaction type picker")
    }
  }

  private var selectionSummary: String {
    switch selectedTypes.count {
    case 0:
      return "All Types"
    case 1:
      return selectedTypes.first?.displayName ?? "All Types"
    default:
      return "\(selectedTypes.count) Types"
    }
  }

  private func selectionBinding(for type: TransactionType) -> Binding<Bool> {
    Binding(
      get: { selectedTypes.contains(type) },
      set: { isSelected in
        var updated = selectedTypes
        if isSelected {
          updated.insert(type)
        } else {
          updated.remove(type)
        }
        selectedTypes = updated
      }
    )
  }
}

#Preview("Transaction type multi-select") {
  @Previewable @State var selectedTypes: Set<TransactionType> = [.income, .transfer]

  Form {
    TransactionTypeMultiSelectPicker(selectedTypes: $selectedTypes)
  }
  .formStyle(.grouped)
}
