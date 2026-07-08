import SwiftUI

enum CategoryDetailSaveDecision: Equatable, Sendable {
  case discardPendingUpdate
  case update(Category)
}

struct CategoryDetailView: View {
  /// Single-case focus enum per UI_GUIDE §13 (one enum per form, one
  /// case per focusable field) — mirrors `CreateCategorySheet.Field`.
  private enum Field: Hashable { case name }

  let category: Category
  let categories: Categories
  let taxOwners: [TaxOwner]
  let defaultTaxOwnerId: UUID
  let taxOwnerErrorMessage: String?
  let onUpdate: (Category) -> Void
  let onDiscardPendingUpdate: () -> Void
  let onDelete: (UUID, UUID?) -> Void

  @State private var editedName: String
  @State private var isTaxReportable: Bool
  @State private var taxOwnerIds: [UUID]
  @State private var showDeleteSheet = false
  @FocusState private var focusedField: Field?

  init(
    category: Category,
    categories: Categories,
    taxOwners: [TaxOwner] = [],
    defaultTaxOwnerId: UUID = UUID(),
    taxOwnerErrorMessage: String? = nil,
    onUpdate: @escaping (Category) -> Void,
    onDiscardPendingUpdate: @escaping () -> Void = {},
    onDelete: @escaping (UUID, UUID?) -> Void
  ) {
    self.category = category
    self.categories = categories
    self.taxOwners = taxOwners
    self.defaultTaxOwnerId = defaultTaxOwnerId
    self.taxOwnerErrorMessage = taxOwnerErrorMessage
    self.onUpdate = onUpdate
    self.onDiscardPendingUpdate = onDiscardPendingUpdate
    self.onDelete = onDelete
    _editedName = State(initialValue: category.name)
    _isTaxReportable = State(initialValue: category.isTaxReportable)
    _taxOwnerIds = State(initialValue: category.taxOwnerIds)
  }

  var body: some View {
    Form {
      detailsSection
      taxTreatmentSection
      taxOwnerOverrideSection
      deleteSection
    }
    .formStyle(.grouped)
    .navigationTitle("Edit Category")
    #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
    #endif
    #if os(macOS)
      // Auto-save makes this panel purely a rename field, so claim
      // first-responder on open. `defaultFocus` alone doesn't pull focus
      // into the inspector when focus sits outside it, and it doesn't
      // re-fire when `.id(selected.id)` swaps content in place; the
      // `.task(id:)` assigns once then re-asserts after a runloop turn so
      // the claim survives AppKit resigning the previous content's
      // responder (mirrors TransactionDetailView).
      .defaultFocus($focusedField, .name)
      .task(id: category.id) {
        focusedField = .name
        await Task.yield()
        guard !Task.isCancelled else { return }
        focusedField = .name
      }
    #endif
    .sheet(isPresented: $showDeleteSheet) {
      DeleteCategorySheet(
        category: category,
        replacements: replacementCandidates,
        onCancel: { showDeleteSheet = false },
        onConfirm: { replacementId in
          showDeleteSheet = false
          Self.confirmDelete(
            categoryId: category.id,
            replacementId: replacementId,
            onDiscardPendingUpdate: onDiscardPendingUpdate,
            onDelete: onDelete)
        }
      )
    }
    .onChange(of: taxOwners) { _, owners in
      taxOwnerIds = TaxOwnerAssignmentState.prunedSelectedOwnerIds(
        taxOwnerIds, validOwners: owners)
      saveChanges()
    }
  }

  private var detailsSection: some View {
    Section("Details") {
      TextField("Name", text: $editedName)
        .focused($focusedField, equals: .name)
        .onChange(of: editedName) { _, _ in saveChanges() }
        // VoiceOver announces the requirement as part of the field
        // itself; the visible caption below is hidden from VoiceOver so
        // it isn't read twice.
        .accessibilityHint(CategoryNameValidation.isBlank(editedName) ? "Name is required" : "")

      if CategoryNameValidation.isBlank(editedName) {
        Text("Name is required")
          .font(.caption)
          .foregroundStyle(.red)
          .accessibilityHidden(true)
      }

      if let parentId = category.parentId, let parent = categories.by(id: parentId) {
        LabeledContent("Parent Category") {
          Text(parent.name)
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  private var taxTreatmentSection: some View {
    Section {
      Toggle("Tax reportable", isOn: $isTaxReportable)
        .onChange(of: isTaxReportable) { _, reportable in
          if !reportable {
            taxOwnerIds = []
          }
          saveChanges()
        }
        .accessibilityHint(
          isTaxReportable
            ? "This category can appear in tax reports."
            : "This category is excluded from tax reports.")
    } header: {
      Text("Tax Treatment")
    } footer: {
      Text("Categories are excluded from tax reports unless this is enabled.")
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
        selectedOwnerIds: Binding(
          get: { taxOwnerIds },
          set: { newValue in
            taxOwnerIds = newValue
            saveChanges()
          }))
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

  private var deleteSection: some View {
    Section {
      Button("Delete Category", role: .destructive) {
        showDeleteSheet = true
      }
    }
  }

  private var replacementCandidates: [Category] {
    categories.roots.filter { $0.id != category.id }
  }

  /// Fires on every keystroke via `.onChange`. The parent debounces the
  /// resulting `onUpdate` into a single write. Empty names and no-op edits
  /// also cancel any prior pending debounce so quickly reverted edits do
  /// not persist a stale snapshot.
  private func saveChanges() {
    switch Self.saveDecision(
      from: category,
      name: editedName,
      isTaxReportable: isTaxReportable,
      taxOwnerIds: taxOwnerIds,
      validOwners: taxOwners)
    {
    case .discardPendingUpdate:
      onDiscardPendingUpdate()
    case .update(let updated):
      onUpdate(updated)
    }
  }

  static func confirmDelete(
    categoryId: UUID,
    replacementId: UUID?,
    onDiscardPendingUpdate: () -> Void,
    onDelete: (UUID, UUID?) -> Void
  ) {
    onDiscardPendingUpdate()
    onDelete(categoryId, replacementId)
  }

  static func saveDecision(
    from category: Category,
    name: String,
    isTaxReportable: Bool,
    taxOwnerIds: [UUID],
    validOwners: [TaxOwner] = []
  ) -> CategoryDetailSaveDecision {
    let normalizedName = CategoryNameValidation.normalized(name)
    guard !normalizedName.isEmpty else { return .discardPendingUpdate }
    let updated = updatedCategory(
      from: category,
      name: normalizedName,
      isTaxReportable: isTaxReportable,
      taxOwnerIds: taxOwnerIds,
      validOwners: validOwners)
    guard updated != category else { return .discardPendingUpdate }
    return .update(updated)
  }

  static func updatedCategory(
    from category: Category,
    name: String,
    isTaxReportable: Bool,
    taxOwnerIds: [UUID],
    validOwners: [TaxOwner] = []
  ) -> Category {
    var updated = category
    updated.name = CategoryNameValidation.normalized(name)
    updated.isTaxReportable = isTaxReportable
    updated.taxOwnerIds =
      isTaxReportable
      ? TaxOwnerAssignmentState.prunedSelectedOwnerIds(taxOwnerIds, validOwners: validOwners)
      : []
    return updated
  }
}

private struct DeleteCategorySheet: View {
  let category: Category
  let replacements: [Category]
  let onCancel: () -> Void
  let onConfirm: (UUID?) -> Void

  @State private var selectedReplacementId: UUID?

  var body: some View {
    NavigationStack {
      form
        .navigationTitle("Delete \(category.name)")
        #if os(iOS)
          .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Cancel", action: onCancel)
          }
        }
    }
    #if os(macOS)
      .frame(minWidth: 400, minHeight: 300)
    #endif
  }

  private var form: some View {
    Form {
      Section {
        Text(message)
          .font(.body)
      }

      if !replacements.isEmpty {
        Section("Reassign Transactions") {
          Picker("Replacement Category", selection: $selectedReplacementId) {
            Text("None (unassign)").tag(UUID?.none)
            ForEach(replacements) { candidate in
              Text(candidate.name).tag(Optional(candidate.id))
            }
          }
        }
      }

      Section {
        Button("Delete Category", role: .destructive) {
          onConfirm(selectedReplacementId)
        }
      }
    }
    .formStyle(.grouped)
  }

  private var message: String {
    if replacements.isEmpty {
      return "This will permanently delete this category."
    }
    return
      "Choose a replacement category for transactions and subcategories, or leave unset to unassign them."
  }
}

#Preview {
  let groceriesId = UUID()
  let fruitId = UUID()
  let categories = Categories(from: [
    Category(id: groceriesId, name: "Groceries"),
    Category(id: fruitId, name: "Fruit", parentId: groceriesId),
    Category(name: "Transport"),
  ])
  let fruit =
    categories.by(id: fruitId)
    ?? Category(id: fruitId, name: "Fruit", parentId: groceriesId)

  NavigationStack {
    CategoryDetailView(
      category: fruit,
      categories: categories,
      onUpdate: { _ in },
      onDelete: { _, _ in }
    )
  }
}
