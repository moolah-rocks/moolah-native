import SwiftUI

/// Search-and-select sheet for fiat / stock / crypto instruments.
///
/// Two initialisers:
/// - `init(store:label:selection:isPresented:)` — callers own a selection
///   binding (e.g. `InstrumentPickerField`) and dismiss via the sheet's own
///   `isPresented`. This is the canonical embedding inside a popover/sheet
///   driven by an `InstrumentPickerField`.
/// - `init(kinds:onCompletion:)` — self-contained variant: builds its own
///   `InstrumentPickerStore` from the ambient `ProfileSession`, manages its
///   own state, and reports the registered instrument (or `nil` for cancel)
///   through a completion handler. Used by Settings flows like
///   `AddTokenSheet` where there's no pre-existing selection to bind.
///
/// The actual rendering lives in `InstrumentPickerSheetCore`; this file
/// dispatches between the two modes.
struct InstrumentPickerSheet: View {
  private let mode: Mode

  init(
    store: InstrumentPickerStore,
    label: LocalizedStringResource,
    selection: Binding<Instrument>,
    isPresented: Binding<Bool>
  ) {
    self.mode = .bound(
      store: store,
      label: label,
      selection: selection,
      isPresented: isPresented
    )
  }

  /// Self-contained convenience initialiser used by callers that don't have
  /// an existing `selection` binding. Builds an `InstrumentPickerStore` from
  /// the ambient `ProfileSession`. `onCompletion` fires with the registered
  /// instrument on a successful pick, or `nil` when the user cancels.
  init(
    kinds: Set<Instrument.Kind>,
    onCompletion: @escaping (Instrument?) -> Void
  ) {
    self.mode = .callback(kinds: kinds, onCompletion: onCompletion)
  }

  var body: some View {
    switch mode {
    case let .bound(store, label, selection, isPresented):
      InstrumentPickerSheetCore(
        store: store,
        label: label,
        selection: selection,
        isPresented: isPresented
      )
    case let .callback(kinds, onCompletion):
      CallbackSheet(kinds: kinds, onCompletion: onCompletion)
    }
  }

  // MARK: - Mode

  private enum Mode {
    case bound(
      store: InstrumentPickerStore,
      label: LocalizedStringResource,
      selection: Binding<Instrument>,
      isPresented: Binding<Bool>
    )
    case callback(
      kinds: Set<Instrument.Kind>,
      onCompletion: (Instrument?) -> Void
    )
  }
}

// MARK: - Callback sheet

/// Self-contained variant. Owns its own `store`, `selection` placeholder,
/// and `isPresented` flag; reports the picked instrument (or `nil` on
/// cancel/dismiss) through `onCompletion`. The store is built from the
/// ambient `ProfileSession` on first appearance — matches the construction
/// pattern used by `InstrumentPickerField.openPicker()`.
private struct CallbackSheet: View {
  let kinds: Set<Instrument.Kind>
  let onCompletion: (Instrument?) -> Void

  @Environment(ProfileSession.self) private var session: ProfileSession?

  // The bound sheet uses `selection` to render a checkmark on the
  // currently-selected row. In callback mode there is no pre-existing
  // selection; we hold a sentinel that no live instrument matches
  // (id is "" — every real instrument has a non-empty id).
  @State private var sentinelSelection: Instrument = Self.sentinel
  @State private var isPresented: Bool = true
  @State private var lastPickedInstrument: Instrument?
  @State private var store: InstrumentPickerStore

  init(kinds: Set<Instrument.Kind>, onCompletion: @escaping (Instrument?) -> Void) {
    self.kinds = kinds
    self.onCompletion = onCompletion
    // Placeholder store — replaced on appear once `session` is in scope.
    self._store = State(initialValue: InstrumentPickerStore(kinds: kinds))
  }

  var body: some View {
    InstrumentPickerSheetCore(
      store: store,
      label: Self.label(for: kinds),
      selection: Binding(
        get: { sentinelSelection },
        set: { newValue in
          sentinelSelection = newValue
          // The bound sheet writes `selection` only on a successful pick,
          // so a non-sentinel value here is the registered instrument.
          if newValue != Self.sentinel {
            lastPickedInstrument = newValue
          }
        }
      ),
      isPresented: $isPresented
    )
    .onAppear {
      // Rebuild the store with the live session's services. Mirrors
      // `InstrumentPickerField.openPicker()` so search and registration
      // both have the right wiring.
      store = InstrumentPickerStore(
        searchService: session?.instrumentSearchService,
        registry: session?.instrumentRegistry,
        resolutionClient: session?.tokenResolutionClient,
        canonicalResolver: session?.canonicalResolver,
        kinds: kinds
      )
    }
    .onChange(of: isPresented) { _, presented in
      guard !presented else { return }
      onCompletion(lastPickedInstrument)
    }
  }

  // Empty-id sentinel that can never collide with a real instrument since
  // every `Instrument.id` is non-empty (e.g. BTC = "0:native", USD = "USD").
  private static let sentinel = Instrument.fiat(code: "")

  private static func label(for kinds: Set<Instrument.Kind>) -> LocalizedStringResource {
    if kinds == [.cryptoToken] { return "Token" }
    if kinds == [.stock] { return "Stock" }
    if kinds == [.fiatCurrency] { return "Currency" }
    return "Instrument"
  }
}

#Preview("Default (single result)") {
  // Multi-row static rendering of this view crashes the previewer with
  // SIGTRAP (corpse incomplete, no usable backtrace; ruled out
  // preferredCurrencySymbol, .listRowBackground, and store stability).
  // Use a single-result query for snapshot review; for multi-row review,
  // interact with the canvas (clear the search to see all 17 fiat codes).
  let store = InstrumentPickerStore(kinds: [.fiatCurrency])
  store.updateQuery("AUD")
  return InstrumentPickerSheet(
    store: store,
    label: "Currency",
    selection: .constant(.AUD),
    isPresented: .constant(true)
  )
  .frame(width: 460, height: 480)
}

#Preview("No matches") {
  let store = InstrumentPickerStore(kinds: [.fiatCurrency])
  // Seed a query that doesn't match any common fiat code so the empty-state
  // view is what renders. The 250ms debounce settles inside the preview.
  store.updateQuery("zxqy")
  return InstrumentPickerSheet(
    store: store,
    label: "Currency",
    selection: .constant(.AUD),
    isPresented: .constant(true)
  )
  .frame(width: 460, height: 480)
}
