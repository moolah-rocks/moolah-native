import SwiftUI

// MARK: - Categories View

struct CategoriesView: View {
  let categoryStore: CategoryStore

  @Environment(ProfileSession.self) private var session

  @State private var showCreateSheet = false
  @State private var selectedCategory: Category?
  @State private var showDetailSheet = false
  @State private var searchText = ""
  @State private var taxOwners: [TaxOwner] = []
  @State private var taxOwnerErrorMessage: String?
  @State private var createErrorMessage: String?
  @State private var isCreatingCategory = false
  @State private var createRequestId: UUID?

  private var showCategoryInspectorBinding: Binding<Bool> {
    Binding(
      get: { selectedCategory != nil },
      set: { if !$0 { selectedCategory = nil } }
    )
  }

  /// Debounced auto-save from the detail inspector — the detail view
  /// fires `onUpdate` on every keystroke; the 300ms debounce coalesces
  /// them into a single write. The optimistic `selectedCategory` re-seed
  /// and the persistence write live inside the store-owned debounce task
  /// so cancellation and tests observe the whole save.
  private func save(_ updated: Category) {
    categoryStore.debouncedSave {
      if selectedCategory?.id == updated.id {
        selectedCategory = updated
      }
      _ = await categoryStore.update(updated)
    }
  }

  var body: some View {
    listView
      #if os(macOS)
        .inspector(isPresented: showCategoryInspectorBinding) {
          if let selected = selectedCategory {
            CategoryDetailView(
              category: selected,
              categories: categoryStore.categories,
              taxOwners: taxOwners,
              defaultTaxOwnerId: session.profile.defaultTaxOwnerId,
              taxOwnerErrorMessage: taxOwnerErrorMessage,
              onUpdate: { updated in save(updated) },
              onDiscardPendingUpdate: { categoryStore.cancelDebouncedSave() },
              onDelete: deleteCategory(id:replacementId:)
            )
            .id(selected.id)
          }
        }
        .toolbar {
          ToolbarItem(placement: .primaryAction) {
            if selectedCategory != nil {
              Button {
                selectedCategory = nil
              } label: {
                Label("Hide Details", systemImage: "sidebar.trailing")
              }
              .help("Hide Details")
            }
          }
        }
      #else
        .sheet(item: $selectedCategory) { selected in
          NavigationStack {
            CategoryDetailView(
              category: selected,
              categories: categoryStore.categories,
              taxOwners: taxOwners,
              defaultTaxOwnerId: session.profile.defaultTaxOwnerId,
              taxOwnerErrorMessage: taxOwnerErrorMessage,
              onUpdate: { updated in save(updated) },
              onDiscardPendingUpdate: { categoryStore.cancelDebouncedSave() },
              onDelete: deleteCategory(id:replacementId:)
            )
            .toolbar {
              ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                  selectedCategory = nil
                }
              }
            }
          }
        }
      #endif
      .sheet(isPresented: $showCreateSheet) {
        CreateCategorySheet(
          categories: categoryStore.categories,
          initialParentId: selectedCategory?.id,
          taxOwners: taxOwners,
          defaultTaxOwnerId: session.profile.defaultTaxOwnerId,
          taxOwnerErrorMessage: taxOwnerErrorMessage,
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
      .focusedSceneValue(\.selectedCategory, $selectedCategory)
      .focusedSceneValue(\.newCategoryAction) {
        showCreateSheet = true
      }
      .onChange(of: showCreateSheet) { _, isPresented in
        if isPresented { retryTaxOwnerLoad() }
      }
      .onChange(of: selectedCategory?.id) { _, selectedId in
        if selectedId != nil { retryTaxOwnerLoad() }
      }
      .onReceive(NotificationCenter.default.publisher(for: .requestCategoryEdit)) { note in
        guard let id = note.object as? UUID,
          let category = categoryStore.categories.by(id: id)
        else { return }
        selectedCategory = category
      }
      .task {
        await observeTaxOwners()
      }
      .task {
        await observeTaxOwnerErrors()
      }
  }

  private func observeTaxOwners() async {
    for await owners in session.backend.taxOwners.observeAll() {
      guard !Task.isCancelled else { return }
      taxOwners = owners
      taxOwnerErrorMessage = nil
      selectedCategory = selectedCategory.map { category in
        Self.category(category, pruningTaxOwnersAgainst: owners)
      }
    }
  }

  private func observeTaxOwnerErrors() async {
    for await _ in session.backend.taxOwners.observeErrors() {
      guard !Task.isCancelled else { return }
      taxOwnerErrorMessage = Self.taxOwnerLoadErrorMessage
    }
  }

  private func retryTaxOwnerLoad() {
    Task {
      do {
        let state = Self.taxOwnerLoadSuccess(
          owners: try await session.backend.taxOwners.fetchAll(),
          selectedCategory: selectedCategory)
        taxOwners = state.owners
        taxOwnerErrorMessage = state.errorMessage
        selectedCategory = state.selectedCategory
      } catch {
        let state = Self.taxOwnerLoadFailure(selectedCategory: selectedCategory)
        taxOwnerErrorMessage = state.errorMessage
        selectedCategory = state.selectedCategory
      }
    }
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
        selectedCategory?.id == id
      {
        selectedCategory = nil
      }
    }
  }

  static let taxOwnerLoadErrorMessage =
    "Couldn't load tax owners. Reopen the category editor and try again."

  struct TaxOwnerLoadState: Equatable {
    let owners: [TaxOwner]
    let errorMessage: String?
    let selectedCategory: Category?
  }

  static func taxOwnerLoadSuccess(
    owners: [TaxOwner],
    selectedCategory: Category?
  ) -> TaxOwnerLoadState {
    TaxOwnerLoadState(
      owners: owners,
      errorMessage: nil,
      selectedCategory: selectedCategory.map { category in
        Self.category(category, pruningTaxOwnersAgainst: owners)
      })
  }

  static func taxOwnerLoadFailure(selectedCategory: Category?) -> TaxOwnerLoadState {
    TaxOwnerLoadState(
      owners: [],
      errorMessage: Self.taxOwnerLoadErrorMessage,
      selectedCategory: selectedCategory)
  }

  static func category(_ category: Category, pruningTaxOwnersAgainst owners: [TaxOwner])
    -> Category
  {
    var pruned = category
    pruned.taxOwnerIds = TaxOwnerAssignmentState.prunedSelectedOwnerIds(
      category.taxOwnerIds, validOwners: owners)
    return pruned
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
    List(selection: $selectedCategory) {
      ForEach(filteredCategories) { category in
        CategoryNodeView(
          category: category,
          categories: categoryStore.categories
        )
        .accessibilityLabel(category.name)
        .tag(category)
        .contextMenu {
          Button("Edit Category\u{2026}", systemImage: "pencil") {
            selectedCategory = category
          }
        }
        .swipeActions(edge: .leading) {
          Button {
            selectedCategory = category
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
