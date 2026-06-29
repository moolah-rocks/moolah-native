import SwiftUI

/// Shared monetary amount entry field, consolidating the amount `TextField`
/// that was previously duplicated across the transaction-detail sections.
///
/// It carries the common modifier stack (hidden label, trailing alignment,
/// monospaced digits, focus binding) and adds two iOS-only affordances the
/// bare `.decimalPad` field lacked:
///
/// - a `±` keyboard-toolbar button, since the decimal pad has no minus key,
///   letting the user enter a negative display amount (e.g. a refund). It
///   flips the sign of the field's display text via
///   ``AmountText/toggledSign(_:)``; the existing parse/un-negation pipeline
///   handles the stored sign, so no sign is ever discarded.
/// - select-all when focus *first* enters the field, so the first keystroke
///   replaces the existing value (commonly `0`). Re-selection fires only on
///   the unfocused→focused transition, so tapping again while already focused
///   still positions the caret.
///
/// On macOS no custom selection logic runs: the platform default already
/// selects the contents when the field is tabbed into and positions the caret
/// when it is clicked, which is the desired behaviour.
///
/// Generic over the focus value so the component can live in the Shared layer
/// without depending on a feature-level focus enum.
struct AmountField<Focus: Hashable>: View {
  @Binding var text: String
  let focus: FocusState<Focus?>.Binding
  let equals: Focus
  var titleKey: LocalizedStringKey = "Amount"
  var accessibilityLabel: String?
  var accessibilityIdentifier: String?
  var onSubmit: (() -> Void)?

  #if os(iOS)
    @State private var selection: TextSelection?
  #endif

  var body: some View {
    field
      .labelsHidden()
      .multilineTextAlignment(.trailing)
      .monospacedDigit()
      .focused(focus, equals: equals)
      .optionalAccessibilityLabel(accessibilityLabel)
      .optionalAccessibilityIdentifier(accessibilityIdentifier)
      .onSubmitIfPresent(onSubmit)
  }

  #if os(iOS)
    private var field: some View {
      TextField(titleKey, text: $text, selection: $selection)
        .keyboardType(.decimalPad)
        .toolbar {
          ToolbarItemGroup(placement: .keyboard) {
            Button {
              text = AmountText.toggledSign(text)
            } label: {
              Image(systemName: "plus.forwardslash.minus")
            }
            .accessibilityLabel("Change sign")
            Spacer()
            Button("Done") { focus.wrappedValue = nil }
          }
        }
        .onChange(of: focus.wrappedValue) { previous, current in
          // Select the whole value only on the focus-in transition, so a
          // later tap can still position the caret while editing.
          guard current == equals, previous != equals else { return }
          selection = TextSelection(range: text.startIndex..<text.endIndex)
        }
    }
  #else
    private var field: some View {
      TextField(titleKey, text: $text)
    }
  #endif
}

extension View {
  /// Applies an accessibility label only when one is supplied, leaving the
  /// SwiftUI default in place otherwise.
  @ViewBuilder
  func optionalAccessibilityLabel(_ label: String?) -> some View {
    if let label {
      accessibilityLabel(label)
    } else {
      self
    }
  }

  /// Applies an accessibility identifier only when one is supplied.
  @ViewBuilder
  func optionalAccessibilityIdentifier(_ identifier: String?) -> some View {
    if let identifier {
      accessibilityIdentifier(identifier)
    } else {
      self
    }
  }

  /// Registers a submit action only when one is supplied, so fields without a
  /// custom submit handler keep the responder chain's default behaviour.
  @ViewBuilder
  func onSubmitIfPresent(_ action: (() -> Void)?) -> some View {
    if let action {
      onSubmit(action)
    } else {
      self
    }
  }
}

#if DEBUG
  /// Hosts `AmountField` in a `Form` with live focus so the iOS keyboard
  /// toolbar (`±` / Done) and the decimal pad can be exercised in the canvas.
  private struct AmountFieldPreviewHost: View {
    private enum Field: Hashable { case amount }

    @State private var amount = "0"
    @FocusState private var focused: Field?

    var body: some View {
      Form {
        LabeledContent {
          AmountField(text: $amount, focus: $focused, equals: .amount)
        } label: {
          Text("Amount")
        }
      }
    }
  }

  #Preview {
    AmountFieldPreviewHost()
  }
#endif
