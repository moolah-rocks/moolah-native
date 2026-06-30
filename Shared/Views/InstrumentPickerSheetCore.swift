import SwiftUI

/// Renders the picker against externally-owned bindings — the core
/// implementation that both `InstrumentPickerSheet` initialisers route
/// through. `InstrumentPickerSheet` itself is the file that owns the public
/// surface (the two inits and the mode dispatch); this file holds the
/// rendering logic and platform layouts.
struct InstrumentPickerSheetCore: View {
  @Bindable var store: InstrumentPickerStore
  let label: LocalizedStringResource
  @Binding var selection: Instrument
  @Binding var isPresented: Bool

  #if os(macOS)
    private enum FocusTarget: Hashable {
      case search
    }

    @FocusState private var focusedField: FocusTarget?
    @State private var highlightedID: String?
  #endif

  var body: some View {
    #if os(macOS)
      macOSContent
    #else
      navigationStack
        .accessibilityIdentifier(UITestIdentifiers.InstrumentPicker.sheet)
    #endif
  }

  // MARK: - Platform layouts

  #if os(macOS)
    /// macOS: custom VStack layout.
    ///
    /// A NavigationStack inside a popover does not render an accessible
    /// search field on macOS (`.searchable` is suppressed in that context),
    /// so we use an explicit `TextField` whose identifier surfaces in the
    /// XCUITest tree. The `instrumentPicker.sheet` driver sentinel sits on
    /// the title `Text` (`macOSHeader`) — a child element rather than the
    /// container, since SwiftUI propagates container-level identifiers to
    /// all descendants and would override child identifiers.
    private var macOSContent: some View {
      // No Cancel button on macOS — popovers auto-dismiss on outside click
      // and Esc (handled below). Removing Cancel makes the search field
      // the only focusable in the header area, so AppKit's first-responder
      // walk lands on it naturally without focus gymnastics.
      VStack(spacing: 0) {
        macOSHeader
        Divider()
        macOSSearchField
        Divider()
        listContent
      }
      // Use ObjectIdentifier as task id so the task re-runs whenever the store
      // instance is replaced (e.g. when the picker is reopened via openPicker()).
      .task(id: ObjectIdentifier(store)) { await store.start() }
      .defaultFocus($focusedField, .search, priority: .userInitiated)
      .onChange(of: store.results.count) { _, _ in
        // Drop the highlight if the result it pointed at is not in the results.
        if let current = highlightedID,
          !store.results.contains(where: { $0.instrument.id == current })
        {
          highlightedID = nil
        }
      }
    }

    private var macOSHeader: some View {
      Text("Choose \(String(localized: label))")
        .font(.headline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        // Drives present/dismissed detection in InstrumentPickerFieldDriver:
        // the title text exists iff the popover is open. Replaces the
        // previous Cancel-button-as-sentinel approach (Cancel removed in
        // line with macOS popover convention — popovers auto-dismiss).
        .accessibilityIdentifier(UITestIdentifiers.InstrumentPicker.sheet)
    }

    private var macOSSearchField: some View {
      HStack {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(.secondary)
        searchTextField
        if !store.query.isEmpty {
          Button {
            store.updateQuery("")
          } label: {
            Image(systemName: "xmark.circle.fill")
              .foregroundStyle(.secondary)
          }
          .buttonStyle(.plain)
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 8)
    }

    private var searchTextField: some View {
      TextField(
        "Search",
        text: Binding(
          get: { store.query },
          set: { store.updateQuery($0) }
        )
      )
      .textFieldStyle(.plain)
      .focused($focusedField, equals: .search)
      .accessibilityIdentifier(UITestIdentifiers.InstrumentPicker.searchField)
      .onSubmit { commitHighlightedOrFirst() }
      .onKeyPress(.downArrow) {
        moveHighlight(by: 1)
        return .handled
      }
      .onKeyPress(.upArrow) {
        moveHighlight(by: -1)
        return .handled
      }
      .onKeyPress(.escape) {
        isPresented = false
        return .handled
      }
    }

    private func moveHighlight(by delta: Int) {
      let ids = store.results.map { $0.instrument.id }
      guard !ids.isEmpty else { return }
      if let current = highlightedID, let index = ids.firstIndex(of: current) {
        let next = max(0, min(ids.count - 1, index + delta))
        highlightedID = ids[next]
      } else {
        highlightedID = delta > 0 ? ids.first : ids.last
      }
    }

    private func commitHighlightedOrFirst() {
      let target =
        highlightedID
        .flatMap { id in store.results.first { $0.instrument.id == id } }
        ?? store.results.first
      guard let target else { return }
      commit(target)
    }
  #endif

  // MARK: - Shared layouts

  private var navigationStack: some View {
    NavigationStack {
      listContent
        .searchable(
          text: Binding(
            get: { store.query },
            set: { store.updateQuery($0) }
          )
        )
        .navigationTitle("Choose \(String(localized: label))")
        #if os(iOS)
          .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { isPresented = false }
          }
        }
    }
    .task { await store.start() }
  }

  @ViewBuilder private var listContent: some View {
    if store.results.isEmpty && !store.query.isEmpty {
      ContentUnavailableView(
        "No matches",
        systemImage: "magnifyingglass",
        description: Text(store.noMatchesDescription)
      )
      // The populated branch returns a `List`, which fills available space.
      // ContentUnavailableView is intrinsically sized — without this, the
      // parent VStack would shrink and the popover would centre the whole
      // header + search + empty-state column vertically.
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      ScrollViewReader { proxy in
        List {
          if let error = store.error {
            Section {
              Label(error, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            }
          }
          ForEach(store.results) { result in
            highlightedRow(for: result)
          }
          if store.kinds.contains(.cryptoToken) {
            Section {
              Text("Add a crypto token in Settings → Crypto Tokens.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
          }
        }
        // While `store.isResolving` is true, the user has tapped an
        // unregistered crypto token and we're awaiting the network
        // round-trip in `TokenResolutionClient.resolve()`. Disable the
        // list (no duplicate `select(_:)` calls from a second tap) and
        // surface a progress overlay so the wait isn't silent. The
        // search field sits outside this list (macOS sibling /
        // iOS navigation-level `.searchable`) and stays interactive.
        .disabled(store.isResolving)
        .overlay { resolvingOverlay }
        #if os(macOS)
          .onChange(of: highlightedID) { _, newID in
            guard let id = newID else { return }
            withAnimation(.easeInOut(duration: 0.1)) {
              proxy.scrollTo(id, anchor: .center)
            }
          }
        #endif
      }
    }
  }

  @ViewBuilder
  private func highlightedRow(for result: InstrumentSearchResult) -> some View {
    #if os(macOS)
      row(for: result)
        .listRowBackground(
          highlightedID == result.instrument.id
            ? Color.accentColor.opacity(0.18)
            : Color.clear
        )
    #else
      row(for: result)
    #endif
  }

}

// MARK: - Row rendering

extension InstrumentPickerSheetCore {
  @ViewBuilder
  private func row(for result: InstrumentSearchResult) -> some View {
    Button {
      commit(result)
    } label: {
      HStack(spacing: 10) {
        glyph(for: result.instrument)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 1) {
          Text(result.instrument.longDisplayName ?? result.instrument.shortCode)
            .fontWeight(.medium)
          if result.instrument.longDisplayName != nil {
            Text(result.instrument.shortCode)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        Spacer()
        trailingAccessories(for: result)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier(UITestIdentifiers.InstrumentPicker.row(result.instrument.id))
    .accessibilityLabel(Text(accessibilityLabel(for: result)))
    .accessibilityAddTraits(result.instrument == selection ? .isSelected : [])
  }

  /// Trailing edge of a row: the chain name (crypto disambiguator), the
  /// "Add" affordance for unregistered tokens, and the selection checkmark.
  /// All are accessibility-hidden — the row's combined label speaks them.
  @ViewBuilder
  private func trailingAccessories(for result: InstrumentSearchResult) -> some View {
    if let chain = result.instrument.chainDisplayName {
      Text(chain)
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }
    if !result.isRegistered {
      Text("Add")
        .font(.caption)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(.tint.opacity(0.15), in: Capsule())
        .accessibilityHidden(true)
    }
    if result.instrument == selection {
      Image(systemName: "checkmark").foregroundStyle(.tint)
        .accessibilityHidden(true)
    }
  }

  /// Spoken row label: "Long Name (CODE)", with the chain appended for
  /// crypto tokens so VoiceOver users can tell same-ticker variants apart
  /// (e.g. "Ethereum (ETH), Optimism"). Unregistered tokens get ", add" to
  /// match the visible "Add" affordance rather than the vaguer "new".
  private func accessibilityLabel(for result: InstrumentSearchResult) -> String {
    var label = result.instrument.pickerLabel
    if let chain = result.instrument.chainDisplayName {
      label += ", \(chain)"
    }
    if !result.isRegistered {
      label += ", add"
    }
    return label
  }

  private func glyph(for instrument: Instrument) -> some View {
    let label: String =
      instrument.kind == .fiatCurrency
      ? (Instrument.preferredCurrencySymbol(for: instrument.id) ?? instrument.id)
      : (instrument.ticker ?? instrument.id)
    return Text(label)
      .font(.system(size: 12, weight: .semibold))
      .frame(width: 28, height: 28)
      .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
  }
}

// MARK: - Selection + resolution helpers

extension InstrumentPickerSheetCore {
  /// Commits the user's pick. Registered hits return immediately; an
  /// unregistered crypto token is resolved via the store (network call),
  /// which surfaces the progress overlay below until it returns.
  func commit(_ result: InstrumentSearchResult) {
    if result.isRegistered {
      selection = result.instrument
      isPresented = false
    } else {
      Task {
        if let chosen = await store.select(result) {
          selection = chosen
          isPresented = false
        }
      }
    }
  }

  /// Progress overlay shown while `store.isResolving == true`.
  /// Sits on top of the disabled list so a crypto resolve round-trip is
  /// visible feedback (and a duplicate tap can't queue a second `select`).
  @ViewBuilder var resolvingOverlay: some View {
    if store.isResolving {
      ProgressView()
        .progressViewStyle(.circular)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .accessibilityLabel("Resolving token…")
    }
  }
}
