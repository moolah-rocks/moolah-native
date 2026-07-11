import SwiftUI

// MARK: - Categories View

struct CategoriesView: View {
  let categoryStore: CategoryStore

  @Environment(ProfileSession.self) private var session

  @State private var showCreateSheet = false
  @State private var taxOwnerAssignmentStore = CategoryTaxOwnerAssignmentStore()
  @State private var showDetailSheet = false
  @State private var searchText = ""
  @State private var createErrorMessage: String?
  @State private var isCreatingCategory = false
  @State private var createRequestId: UUID?

  private var showCategoryInspectorBinding: Binding<Bool> {
    Binding(
      get: { taxOwnerAssignmentStore.selectedCategory != nil },
      set: { if !$0 { taxOwnerAssignmentStore.select(nil) } }
    )
  }

  private var selectedCategoryBinding: Binding<Category?> {
    Binding(
      get: { taxOwnerAssignmentStore.selectedCategory },
      set: { taxOwnerAssignmentStore.select($0) }
    )
  }

  /// Debounced auto-save from the detail inspector — the detail view
  /// fires `onUpdate` on every keystroke; the 300ms debounce coalesces
  /// them into a single write. The optimistic selected-category re-seed
  /// and the persistence write live inside the store-owned debounce task
  /// so cancellation and tests observe the whole save.
  private func save(_ updated: Category) {
    categoryStore.debouncedSave {
      if taxOwnerAssignmentStore.selectedCategory?.id == updated.id {
        taxOwnerAssignmentStore.select(updated)
      }
      _ = await categoryStore.update(updated)
    }
  }

  var body: some View {
    listView
      #if os(macOS)
        .inspector(isPresented: showCategoryInspectorBinding) {
          if let selected = taxOwnerAssignmentStore.selectedCategory {
            CategoryDetailView(
              category: selected,
              categories: categoryStore.categories,
              taxOwners: taxOwnerAssignmentStore.owners,
              defaultTaxOwnerId: session.profile.defaultTaxOwnerId,
              taxOwnerErrorMessage: taxOwnerAssignmentStore.errorMessage,
              onUpdate: { updated in save(updated) },
              onDiscardPendingUpdate: { categoryStore.cancelDebouncedSave() },
              onDelete: deleteCategory(id:replacementId:)
            )
            .id(selected.id)
          }
        }
        .toolbar {
          ToolbarItem(placement: .primaryAction) {
            if taxOwnerAssignmentStore.selectedCategory != nil {
              Button {
                taxOwnerAssignmentStore.select(nil)
              } label: {
                Label("Hide Details", systemImage: "sidebar.trailing")
              }
              .help("Hide Details")
            }
          }
        }
      #else
        .sheet(item: selectedCategoryBinding) { selected in
          NavigationStack {
            CategoryDetailView(
              category: selected,
              categories: categoryStore.categories,
              taxOwners: taxOwnerAssignmentStore.owners,
              defaultTaxOwnerId: session.profile.defaultTaxOwnerId,
              taxOwnerErrorMessage: taxOwnerAssignmentStore.errorMessage,
              onUpdate: { updated in save(updated) },
              onDiscardPendingUpdate: { categoryStore.cancelDebouncedSave() },
              onDelete: deleteCategory(id:replacementId:)
            )
            .toolbar {
              ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                  taxOwnerAssignmentStore.select(nil)
                }
              }
            }
          }
        }
      #endif
      .sheet(isPresented: $showCreateSheet) {
        CreateCategorySheet(
          categories: categoryStore.categories,
          initialParentId: taxOwnerAssignmentStore.selectedCategory?.id,
          taxOwners: taxOwnerAssignmentStore.owners,
          defaultTaxOwnerId: session.profile.defaultTaxOwnerId,
          taxOwnerErrorMessage: taxOwnerAssignmentStore.errorMessage,
          createErrorMessage: createErrorMessage,
          isSubmitting: isCreatingCategory,
          onCreate: createCategory(_:)
        )
        .onDisappear {
          guard !isCreatingCategory else { return }
          createRequestId = nil
          createErrorMessage = nil
        }
      }
      .focusedSceneValue(\.selectedCategory, selectedCategoryBinding)
      .focusedSceneValue(\.newCategoryAction) {
        showCreateSheet = true
      }
      .onChange(of: showCreateSheet) { _, isPresented in
        if isPresented { retryTaxOwnerLoad() }
      }
      .onChange(of: taxOwnerAssignmentStore.selectedCategory?.id) { _, selectedId in
        if selectedId != nil { retryTaxOwnerLoad() }
      }
      .onReceive(NotificationCenter.default.publisher(for: .requestCategoryEdit)) { note in
        guard let id = note.object as? UUID,
          let category = categoryStore.categories.by(id: id)
        else { return }
        taxOwnerAssignmentStore.select(category)
      }
      .task {
        await taxOwnerAssignmentStore.observeOwners(from: session.backend.taxOwners)
      }
      .task {
        await taxOwnerAssignmentStore.observeErrors(from: session.backend.taxOwners)
      }
  }

  private func retryTaxOwnerLoad() {
    Task { await taxOwnerAssignmentStore.loadOwners(from: session.backend.taxOwners) }
  }

  private func createCategory(_ newCategory: Category) {
    guard !isCreatingCategory else { return }
    let requestId = UUID()
    createRequestId = requestId
    isCreatingCategory = true
    createErrorMessage = nil

    Task {
      let created = await categoryStore.create(newCategory)
      guard createRequestId == requestId else { return }
      isCreatingCategory = false
      if created != nil {
        createRequestId = nil
        showCreateSheet = false
      } else {
        createErrorMessage = "Couldn't create category. Check the details and try again."
      }
    }
  }

  private func deleteCategory(id: UUID, replacementId: UUID?) {
    Task {
      if await categoryStore.delete(id: id, withReplacement: replacementId),
        taxOwnerAssignmentStore.selectedCategory?.id == id
      {
        taxOwnerAssignmentStore.select(nil)
      }
    }
  }

}

extension CategoriesView {
  private var filteredCategories: [Category] {
    if searchText.isEmpty {
      return categoryStore.categories.roots
    }
    return categoryStore.categories.roots.filter {
      matchesSearch($0)
    }
  }

  private func matchesSearch(_ category: Category) -> Bool {
    if category.name.localizedCaseInsensitiveContains(searchText) {
      return true
    }
    return categoryStore.categories.children(of: category.id).contains {
      $0.name.localizedCaseInsensitiveContains(searchText)
    }
  }

  private var listView: some View {
    List(selection: selectedCategoryBinding) {
      ForEach(filteredCategories) { category in
        CategoryNodeView(
          category: category,
          categories: categoryStore.categories
        )
        .accessibilityLabel(category.name)
        .tag(category)
        .contextMenu {
          Button("Edit Category\u{2026}", systemImage: "pencil") {
            taxOwnerAssignmentStore.select(category)
          }
        }
        .swipeActions(edge: .leading) {
          Button {
            taxOwnerAssignmentStore.select(category)
          } label: {
            Label("Edit Category", systemImage: "pencil")
          }
          .tint(.blue)
        }
      }
    }
    #if os(macOS)
      .listStyle(.inset)
    #else
      .listStyle(.plain)
    #endif
    .profileNavigationTitle("Categories")
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          showCreateSheet = true
        } label: {
          Label("Add Category", systemImage: "plus")
        }
      }
    }
    // No `.task { categoryStore.load() }` — the reactive store
    // subscribes to `repository.observeAll()` in init. No
    // `.refreshable` — pull-to-refresh would be a no-op against a live
    // observation.
    .searchable(text: $searchText, prompt: "Search categories")
    .overlay {
      if categoryStore.categories.roots.isEmpty {
        ContentUnavailableView(
          "No Categories",
          systemImage: "tag",
          description: Text(
            PlatformActionVerb.emptyStatePrompt(
              buttonLabel: "+", suffix: "to add your first category."))
        )
      }
    }
  }
}

// MARK: - Node View

private struct CategoryNodeView: View {
  let category: Category
  let categories: Categories

  var body: some View {
    let children = categories.children(of: category.id)

    if children.isEmpty {
      Label(category.name, systemImage: "tag")
        .contentShape(.rect)
    } else {
      DisclosureGroup {
        ForEach(children) { child in
          CategoryNodeView(category: child, categories: categories)
            .contentShape(.rect)
            .tag(child)
        }
      } label: {
        Label(category.name, systemImage: "folder")
          .contentShape(.rect)
      }
    }
  }
}

#Preview("Categories List") {
  let backend = PreviewBackend.create()
  let store = CategoryStore(repository: backend.categories)

  NavigationStack {
    CategoriesView(categoryStore: store)
  }
  .previewProfileEnvironment()
  .task {
    let groceriesId = UUID()
    for cat in [
      Category(id: groceriesId, name: "Groceries"),
      Category(name: "Fruit", parentId: groceriesId),
      Category(name: "Vegetables", parentId: groceriesId),
      Category(name: "Transport"),
      Category(name: "Entertainment"),
    ] {
      _ = try? await backend.categories.create(cat)
    }
    // CategoryStore is reactive — it'll see the seeded categories via
    // `observeAll()` without an explicit load() call.
  }
}
