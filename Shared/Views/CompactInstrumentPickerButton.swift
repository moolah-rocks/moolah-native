import SwiftUI

/// Compact pull-down that opens the standard `InstrumentPickerSheet` but
/// shows only the instrument's short code (e.g. `AUD`, `VGS.AX`) — used on
/// rows where the amount and instrument live side by side and a long
/// `Australian Dollar (AUD)` label would crowd out the amount.
struct CompactInstrumentPickerButton: View {
  @Binding var selection: Instrument

  @Environment(ProfileSession.self) private var session: ProfileSession?
  @State private var isPresented = false
  @State private var store = InstrumentPickerStore(
    kinds: Set(Instrument.Kind.allCases))

  var body: some View {
    Button {
      store = InstrumentPickerStore(
        searchService: session?.instrumentSearchService,
        registry: session?.instrumentRegistry,
        resolutionClient: session?.tokenResolutionClient,
        canonicalResolver: session?.canonicalResolver,
        kinds: Set(Instrument.Kind.allCases)
      )
      isPresented = true
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
    .accessibilityLabel(Text("Asset: \(selection.shortCode)"))
    .accessibilityHint(Text("Activate to choose a different asset"))
    #if os(macOS)
      .popover(
        isPresented: $isPresented,
        arrowEdge: .leading,
        content: {
          InstrumentPickerSheet(
            store: store,
            label: "Asset",
            selection: $selection,
            isPresented: $isPresented
          )
          .frame(minWidth: 460, minHeight: 480)
        }
      )
    #else
      .sheet(
        isPresented: $isPresented,
        content: {
          InstrumentPickerSheet(
            store: store,
            label: "Asset",
            selection: $selection,
            isPresented: $isPresented
          )
        }
      )
    #endif
  }
}
