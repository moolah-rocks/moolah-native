import SwiftUI

/// Compact pull-down that opens the standard `InstrumentPickerSheet` but
/// shows only the instrument's short code (e.g. `AUD`, `VGS.AX`) — used on
/// rows where the amount and instrument live side by side and a long
/// `Australian Dollar (AUD)` label would crowd out the amount.
struct CompactInstrumentPickerButton: View {
  @Binding var selection: Instrument

  @Environment(ProfileSession.self) private var session: ProfileSession?
  @State private var presentation: InstrumentPickerPresentation?

  var body: some View {
    Button {
      openPicker()
    } label: {
      HStack(spacing: 4) {
        Text(selection.shortCode)
          .foregroundStyle(.secondary)
          .monospacedDigit()
          .lineLimit(1)
          .fixedSize(horizontal: true, vertical: false)
        Image(systemName: "chevron.up.chevron.down")
          .foregroundStyle(.tertiary)
          .font(.caption2)
      }
      .contentShape(Rectangle())
    }
    .layoutPriority(1)
    .buttonStyle(.plain)
    #if os(macOS)
      .onKeyPress(.space) {
        openPicker()
        return .handled
      }
    #endif
    .accessibilityLabel(Text("Asset: \(selection.shortCode)"))
    .accessibilityHint(Text("Activate to choose a different asset"))
    .sheet(
      item: $presentation,
      content: { presentation in
        #if os(macOS)
          NavigationStack {
            InstrumentPickerSheet(
              store: presentation.store,
              label: "Asset",
              selection: $selection,
              isPresented: isPresented
            )
            .padding(24)
            .toolbar {
              ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { isPresented.wrappedValue = false }
              }
            }
          }
          .frame(minWidth: 460, minHeight: 480)
        #else
          InstrumentPickerSheet(
            store: presentation.store,
            label: "Asset",
            selection: $selection,
            isPresented: isPresented
          )
        #endif
      }
    )
  }

}

extension CompactInstrumentPickerButton {
  private func openPicker() {
    guard presentation == nil else { return }
    presentation = InstrumentPickerPresentation(
      session: session,
      kinds: Set(Instrument.Kind.allCases)
    )
  }

  private var isPresented: Binding<Bool> {
    Binding(
      get: { presentation != nil },
      set: { presented in
        if !presented {
          presentation = nil
        }
      }
    )
  }

}

#Preview("Compact instrument picker") {
  CompactInstrumentPickerButton(selection: .constant(.AUD))
    .padding()
}
