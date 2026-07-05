import SwiftUI

struct CreateCategorySheet: View {
  /// Single-enum focus model so Tab/Cmd+Return advance through Name →
  /// Parent → Create in the order the form renders. UI_GUIDE §13
  /// requires one optional enum per form with one case per focusable
  /// field; multiple boolean `@FocusState`s don't compose.
  private enum Field: Hashable { case name, parent }

  let categories: Categories
  let initialParentId: UUID?
  let onCreate: (Category) -> Void

  @State private var name: String = ""
  @State private var parent: ParentCategorySelection
  @State private var pickerState = CategoryAutocompleteState()
  @FocusState private var focusedField: Field?
  @Environment(\.dismiss) private var dismiss

  init(
    categories: Categories,
    initialParentId: UUID? = nil,
    onCreate: @escaping (Category) -> Void
  ) {
    self.categories = categories
    self.initialParentId = initialParentId
    self.onCreate = onCreate
    _parent = State(
      initialValue: ParentCategorySelection(
        initialId: initialParentId, in: categories))
  }

  var body: some View {
    NavigationStack {
      form
    }
    #if os(macOS)
      .frame(minWidth: 500, minHeight: 400)
    #endif
  }

  private var visibleSuggestions: [CategorySuggestion] {
    pickerState.visibleSuggestions(for: parent.text, in: categories)
  }

  private var form: some View {
    Form {
      Section("Details") {
        TextField("Name", text: $name)
          .accessibilityLabel("Category name")
          .focused($focusedField, equals: .name)
          .onSubmit { focusedField = .parent }
      }

      Section("Parent Category") {
        CategoryAutocompleteField(
          placeholder: "Parent",
          text: $parent.text,
          highlightedIndex: $pickerState.highlightedIndex,
          suggestionCount: visibleSuggestions.count,
          onTextChange: { _ in openDropdownIfFocused() },
          onAcceptHighlighted: acceptHighlightedParent,
          onCancel: { pickerState.cancel() }
        )
        .focused($focusedField, equals: .parent)
        .accessibilityLabel("Parent category")
        .accessibilityIdentifier(UITestIdentifiers.CreateCategory.parentCategoryField)
      }
    }
    .formStyle(.grouped)
    #if os(macOS)
      .defaultFocus($focusedField, .name)
    #endif
    .onChange(of: focusedField) { _, newField in
      if newField != .parent { handleParentBlur() }
    }
    .overlayPreferenceValue(CategoryPickerAnchorKey.self) { anchor in
      if pickerState.showSuggestions, !visibleSuggestions.isEmpty, let anchor {
        GeometryReader { proxy in
          let rect = proxy[anchor]
          CategorySuggestionDropdown(
            suggestions: visibleSuggestions,
            searchText: parent.text,
            highlightedIndex: $pickerState.highlightedIndex,
            onSelect: selectParent(_:)
          )
          .frame(width: rect.width)
          .offset(x: rect.minX, y: rect.maxY + 4)
        }
      }
    }
    .navigationTitle("New Category")
    #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
    #endif
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button("Cancel") { dismiss() }
      }
      ToolbarItem(placement: .confirmationAction) {
        Button("Create") {
          onCreate(Category(name: name, parentId: parent.id))
        }
        .disabled(name.isEmpty)
        #if os(macOS)
          .keyboardShortcut(.return, modifiers: .command)
        #endif
      }
    }
  }

  private func openDropdownIfFocused() {
    guard focusedField == .parent else { return }
    if pickerState.justSelected {
      pickerState.justSelected = false
    } else {
      pickerState.showSuggestions = true
    }
  }

  private func acceptHighlightedParent() {
    guard
      let index = pickerState.highlightedIndex,
      index < visibleSuggestions.count
    else { return }
    selectParent(visibleSuggestions[index])
  }

  private func selectParent(_ suggestion: CategorySuggestion) {
    pickerState.dismiss()
    parent.commit(suggestion)
  }

  private func handleParentBlur() {
    let highlighted = pickerState.highlightedSuggestion(
      for: parent.text, in: categories)
    pickerState.dismiss()
    parent.commitHighlightedOrNormalise(
      highlighted: highlighted, in: categories)
  }
}

#Preview("Create Category Sheet") {
  let groceriesId = UUID()
  let categories = Categories(from: [
    Category(id: groceriesId, name: "Groceries"),
    Category(name: "Fruit", parentId: groceriesId),
    Category(name: "Vegetables", parentId: groceriesId),
    Category(name: "Transport"),
    Category(name: "Entertainment"),
  ])

  CreateCategorySheet(
    categories: categories,
    initialParentId: groceriesId,
    onCreate: { _ in }
  )
}
