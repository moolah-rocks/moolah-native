import SwiftUI

struct CreateCategorySheet: View {
  /// Single-enum focus model so Tab/Cmd+Return advance through Name →
  /// Parent → Create in the order the form renders. UI_GUIDE §13
  /// requires one optional enum per form with one case per focusable
  /// field; multiple boolean `@FocusState`s don't compose.
  private enum Field: Hashable { case name, parent }

  let categories: Categories
  let initialParentId: UUID?
  let taxOwners: [TaxOwner]
  let defaultTaxOwnerId: UUID
  let taxOwnerErrorMessage: String?
  let createErrorMessage: String?
  let isSubmitting: Bool
  let onCreate: (Category) -> Void

  @State private var name: String = ""
  @State private var parent: ParentCategorySelection
  @State private var isTaxReportable = false
  @State private var taxOwnerIds: [UUID] = []
  @State private var pickerState = CategoryAutocompleteState()
  @FocusState private var focusedField: Field?
  @Environment(\.dismiss) private var dismiss

  init(
    categories: Categories,
    initialParentId: UUID? = nil,
    taxOwners: [TaxOwner] = [],
    defaultTaxOwnerId: UUID = UUID(),
    taxOwnerErrorMessage: String? = nil,
    createErrorMessage: String? = nil,
    isSubmitting: Bool = false,
    onCreate: @escaping (Category) -> Void
  ) {
    self.categories = categories
    self.initialParentId = initialParentId
    self.onCreate = onCreate
    self.taxOwners = taxOwners
    self.defaultTaxOwnerId = defaultTaxOwnerId
    self.taxOwnerErrorMessage = taxOwnerErrorMessage
    self.createErrorMessage = createErrorMessage
    self.isSubmitting = isSubmitting
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
      detailsSection
        .disabled(isSubmitting)
      parentCategorySection
        .disabled(isSubmitting)
      taxTreatmentSection
        .disabled(isSubmitting)
      taxOwnerOverrideSection
      submittingStatusSection
      createErrorSection
    }
    .formStyle(.grouped)
    #if os(macOS)
      .defaultFocus($focusedField, .name)
    #endif
    .onChange(of: focusedField) { _, newField in
      if newField != .parent { handleParentBlur() }
    }
    .overlayPreferenceValue(CategoryPickerAnchorKey.self) { anchor in
      if CreateCategoryParentAutocomplete.shouldShowSuggestions(
        isSubmitting: isSubmitting,
        pickerState: pickerState,
        visibleSuggestions: visibleSuggestions),
        let anchor
      {
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
          .disabled(isSubmitting)
      }
      ToolbarItem(placement: .confirmationAction) {
        Button("Create") {
          onCreate(
            Self.category(
              name: name,
              parentId: parent.id,
              isTaxReportable: isTaxReportable,
              taxOwnerIds: taxOwnerIds,
              validOwners: taxOwners))
        }
        .disabled(Self.isCreateDisabled(name: name, isSubmitting: isSubmitting))
        #if os(macOS)
          .keyboardShortcut(.return, modifiers: .command)
        #endif
      }
    }
    .interactiveDismissDisabled(isSubmitting)
    .onChange(of: isTaxReportable) { _, reportable in
      if !reportable {
        taxOwnerIds = []
      }
    }
    .onChange(of: taxOwners) { _, owners in
      taxOwnerIds = TaxOwnerAssignmentState.prunedSelectedOwnerIds(
        taxOwnerIds, validOwners: owners)
    }
  }

  private var detailsSection: some View {
    Section("Details") {
      TextField("Name", text: $name)
        .accessibilityLabel("Category name")
        .focused($focusedField, equals: .name)
        .onSubmit { focusedField = .parent }
    }
  }

  private var parentCategorySection: some View {
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

  private var taxTreatmentSection: some View {
    Section {
      Toggle("Tax reportable", isOn: $isTaxReportable)
        .accessibilityHint(
          isTaxReportable
            ? "This category can appear in tax reports."
            : "This category is excluded from tax reports.")
    } header: {
      Text("Tax Treatment")
    } footer: {
      Text("New categories are not tax reportable unless you enable this.")
    }
  }

  @ViewBuilder private var taxOwnerOverrideSection: some View {
    let presentation = CategoryTaxOwnerOverridePresentation(
      isTaxReportable: isTaxReportable,
      ownerCount: taxOwners.count,
      errorMessage: taxOwnerErrorMessage)
    if presentation.showsUnavailableMessage, let taxOwnerErrorMessage {
      taxOwnerUnavailableSection(message: taxOwnerErrorMessage)
    } else if presentation.showsControls {
      TaxOwnerAssignmentSection(
        title: "Tax Owner Override",
        owners: taxOwners,
        defaultOwnerId: defaultTaxOwnerId,
        footer: CategoryTaxOwnerOverridePresentation.footer,
        emptySelectionDescription:
          CategoryTaxOwnerOverridePresentation.emptySelectionDescription,
        emptySelectionSummary: CategoryTaxOwnerOverridePresentation.emptySelectionSummary,
        clearSelectionLabel: CategoryTaxOwnerOverridePresentation.clearSelectionLabel,
        selectedOwnerIds: $taxOwnerIds
      )
      .disabled(isSubmitting)
    }
  }

  private func taxOwnerUnavailableSection(message: String) -> some View {
    Section {
      Label(message, systemImage: "exclamationmark.triangle.fill")
        .foregroundStyle(.red)
    } header: {
      Text("Tax Owner Override")
    }
  }

  private func openDropdownIfFocused() {
    CreateCategoryParentAutocomplete.openDropdownIfFocused(
      isSubmitting: isSubmitting,
      isParentFocused: focusedField == .parent,
      pickerState: &pickerState)
  }

  private func acceptHighlightedParent() {
    CreateCategoryParentAutocomplete.acceptHighlightedParent(
      isSubmitting: isSubmitting,
      pickerState: &pickerState,
      parent: &parent,
      categories: categories)
  }

  private func selectParent(_ suggestion: CategorySuggestion) {
    CreateCategoryParentAutocomplete.selectParent(
      isSubmitting: isSubmitting,
      suggestion: suggestion,
      pickerState: &pickerState,
      parent: &parent)
  }

  private func handleParentBlur() {
    CreateCategoryParentAutocomplete.handleParentBlur(
      isSubmitting: isSubmitting,
      pickerState: &pickerState,
      parent: &parent,
      categories: categories)
  }
}

extension CreateCategorySheet {
  @ViewBuilder private var submittingStatusSection: some View {
    if isSubmitting {
      Section {
        HStack {
          ProgressView()
          Text("Creating category…")
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Creating category")
      }
    }
  }

  @ViewBuilder private var createErrorSection: some View {
    if let createErrorMessage {
      Section {
        Label(createErrorMessage, systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.red)
      }
    }
  }

  static func category(
    name: String,
    parentId: UUID?,
    isTaxReportable: Bool = false,
    taxOwnerIds: [UUID] = [],
    validOwners: [TaxOwner] = []
  ) -> Category {
    let ownerIds = TaxOwnerAssignmentState.prunedSelectedOwnerIds(
      taxOwnerIds, validOwners: validOwners)
    return Category(
      name: CategoryNameValidation.normalized(name),
      parentId: parentId,
      isTaxReportable: isTaxReportable,
      taxOwnerIds: isTaxReportable ? ownerIds : [])
  }

  static func isCreateDisabled(name: String, isSubmitting: Bool) -> Bool {
    CategoryNameValidation.isBlank(name) || isSubmitting
  }
}

enum CreateCategoryParentAutocomplete {
  static func shouldShowSuggestions(
    isSubmitting: Bool,
    pickerState: CategoryAutocompleteState,
    visibleSuggestions: [CategorySuggestion]
  ) -> Bool {
    !isSubmitting && pickerState.showSuggestions && !visibleSuggestions.isEmpty
  }

  static func openDropdownIfFocused(
    isSubmitting: Bool,
    isParentFocused: Bool,
    pickerState: inout CategoryAutocompleteState
  ) {
    guard !isSubmitting, isParentFocused else { return }
    if pickerState.justSelected {
      pickerState.justSelected = false
    } else {
      pickerState.showSuggestions = true
    }
  }

  static func acceptHighlightedParent(
    isSubmitting: Bool,
    pickerState: inout CategoryAutocompleteState,
    parent: inout ParentCategorySelection,
    categories: Categories
  ) {
    guard !isSubmitting,
      let highlighted = pickerState.highlightedSuggestion(for: parent.text, in: categories)
    else { return }
    selectParent(
      isSubmitting: false,
      suggestion: highlighted,
      pickerState: &pickerState,
      parent: &parent)
  }

  static func selectParent(
    isSubmitting: Bool,
    suggestion: CategorySuggestion,
    pickerState: inout CategoryAutocompleteState,
    parent: inout ParentCategorySelection
  ) {
    guard !isSubmitting else { return }
    pickerState.dismiss()
    parent.commit(suggestion)
  }

  static func handleParentBlur(
    isSubmitting: Bool,
    pickerState: inout CategoryAutocompleteState,
    parent: inout ParentCategorySelection,
    categories: Categories
  ) {
    guard !isSubmitting else {
      pickerState.cancel()
      return
    }
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
