import SwiftUI

struct InstrumentPickerField: View {
  let label: LocalizedStringResource
  let kinds: Set<Instrument.Kind>
  @Binding var selection: Instrument

  @Environment(ProfileSession.self) private var session: ProfileSession?
  @State private var presentation: InstrumentPickerPresentation?

  var body: some View {
    pickerButton
      #if os(macOS)
        .popover(item: $presentation, arrowEdge: .leading) { presentation in
          InstrumentPickerSheet(
            store: presentation.store,
            label: label,
            selection: $selection,
            isPresented: isPresented
          )
          .frame(minWidth: 460, minHeight: 480)
        }
      #else
        .sheet(item: $presentation) { presentation in
          InstrumentPickerSheet(
            store: presentation.store,
            label: label,
            selection: $selection,
            isPresented: isPresented
          )
        }
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
      .onKeyPress(.space) {
        openPicker()
        return .handled
      }
      .onKeyPress(.rightArrow) {
        openPicker()
        return .handled
      }
    #endif
    .accessibilityIdentifier(UITestIdentifiers.InstrumentPicker.field(selection.id))
    .accessibilityLabel(Text("\(String(localized: label)): \(selection.pickerLabel)"))
    .accessibilityHint(Text("Activate to choose a different \(String(localized: label))"))
  }

}

extension InstrumentPickerField {
  // MARK: - Helpers

  private func openPicker() {
    guard presentation == nil else { return }
    presentation = InstrumentPickerPresentation(
      session: session,
      kinds: kinds
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
