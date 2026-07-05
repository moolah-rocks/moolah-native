import SwiftUI

struct CategoryDetailView: View {
  /// Single-case focus enum per UI_GUIDE §13 (one enum per form, one
  /// case per focusable field) — mirrors `CreateCategorySheet.Field`.
  private enum Field: Hashable { case name }

  let category: Category
  let categories: Categories
  let onUpdate: (Category) -> Void
  let onDelete: (UUID, UUID?) -> Void

  @State private var editedName: String
  @State private var showDeleteSheet = false
  @FocusState private var focusedField: Field?

  init(
    category: Category,
    categories: Categories,
    onUpdate: @escaping (Category) -> Void,
    onDelete: @escaping (UUID, UUID?) -> Void
  ) {
    self.category = category
    self.categories = categories
    self.onUpdate = onUpdate
    self.onDelete = onDelete
    _editedName = State(initialValue: category.name)
  }

  var body: some View {
    Form {
      Section("Details") {
        TextField("Name", text: $editedName)
          .focused($focusedField, equals: .name)
          .onChange(of: editedName) { _, _ in saveChanges() }
          // VoiceOver announces the requirement as part of the field
          // itself; the visible caption below is hidden from VoiceOver so
          // it isn't read twice.
          .accessibilityHint(editedName.isEmpty ? "Name is required" : "")

        if editedName.isEmpty {
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

      Section {
        Button("Delete Category", role: .destructive) {
          showDeleteSheet = true
        }
      }
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
          onDelete(category.id, replacementId)
        }
      )
    }
  }

  private var replacementCandidates: [Category] {
    categories.roots.filter { $0.id != category.id }
  }

  /// Fires on every keystroke via `.onChange`. The parent debounces the
  /// resulting `onUpdate` into a single write. Skips empty names and
  /// no-op edits so we never persist a blank name or a redundant write.
  private func saveChanges() {
    guard !editedName.isEmpty, editedName != category.name else { return }
    var updated = category
    updated.name = editedName
    onUpdate(updated)
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
