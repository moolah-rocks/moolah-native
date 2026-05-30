import SwiftUI

struct InstrumentPickerField: View {
  let label: LocalizedStringResource
  let kinds: Set<Instrument.Kind>
  @Binding var selection: Instrument

  @Environment(ProfileSession.self) private var session: ProfileSession?
  @State private var isPresented = false
  // Non-optional: always holds a valid store. The store is replaced on each
  // open via openPicker(). A stub (no searchService/registry) is used as
  // placeholder until the first open.
  @State private var store: InstrumentPickerStore

  // Synthesizing init for @State with a non-trivial default requires explicit
  // init so the store can be constructed with the correct kinds.
  init(
    label: LocalizedStringResource,
    kinds: Set<Instrument.Kind>,
    selection: Binding<Instrument>
  ) {
    self.label = label
    self.kinds = kinds
    self._selection = selection
    // Placeholder store — no session services yet. Replaced on first open.
    self._store = State(initialValue: InstrumentPickerStore(kinds: kinds))
  }

  var body: some View {
    pickerButton
      #if os(macOS)
        .popover(
          isPresented: $isPresented,
          arrowEdge: .leading,
          content: {
            InstrumentPickerSheet(
              store: store,
              label: label,
              selection: $selection,
              isPresented: $isPresented
            )
            .frame(minWidth: 460, minHeight: 480)
          }
        )
      #else
        .sheet(
          isPresented: $isPresented,
          onDismiss: { store = InstrumentPickerStore(kinds: kinds) },
          content: {
            InstrumentPickerSheet(
              store: store,
              label: label,
              selection: $selection,
              isPresented: $isPresented
            )
          }
        )
      #endif
  }

  // MARK: - Subviews

  private var pickerButton: some View {
    Button {
      openPicker()
    } label: {
      LabeledContent(String(localized: label)) {
        HStack(spacing: 6) {
          Text(selection.pickerLabel)
            .fontWeight(.medium)
            .lineLimit(1)
            .truncationMode(.tail)
          Image(systemName: "chevron.right")
            .foregroundStyle(.tertiary)
            .font(.caption)
        }
      }
      // Make the entire row hittable, not just the trailing content slot —
      // otherwise clicking on the row's leading "Currency" label or the gap
      // between label and value doesn't activate the Button (LabeledContent
      // hit-tests its halves separately).
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    #if os(macOS)
      .onKeyPress(.rightArrow) {
        openPicker()
        return .handled
      }
    #endif
    .accessibilityIdentifier(UITestIdentifiers.InstrumentPicker.field(selection.id))
    .accessibilityLabel(Text("\(String(localized: label)): \(selection.pickerLabel)"))
    .accessibilityHint(Text("Activate to choose a different \(String(localized: label))"))
  }

  // MARK: - Helpers

  private func openPicker() {
    store = InstrumentPickerStore(
      searchService: session?.instrumentSearchService,
      registry: session?.instrumentRegistry,
      resolutionClient: session?.tokenResolutionClient,
      kinds: kinds
    )
    isPresented = true
  }
}
