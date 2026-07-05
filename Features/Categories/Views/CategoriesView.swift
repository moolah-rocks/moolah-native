import SwiftUI

// MARK: - Categories View

struct CategoriesView: View {
  let categoryStore: CategoryStore

  @State private var showCreateSheet = false
  @State private var selectedCategory: Category?
  @State private var showDetailSheet = false
  @State private var searchText = ""

  private var showCategoryInspectorBinding: Binding<Bool> {
    Binding(
      get: { selectedCategory != nil },
      set: { if !$0 { selectedCategory = nil } }
    )
  }

  /// Debounced auto-save from the detail inspector — the detail view
  /// fires `onUpdate` on every keystroke; the 300ms debounce coalesces
  /// them into a single write (mirrors the transaction detail panel).
  ///
  /// The debounce action is kept synchronous so `debouncedSave`'s returned
  /// task represents "the action ran" (its awaitable contract): the
  /// optimistic `selectedCategory` re-seed happens synchronously, then the
  /// write fires as an independent `Task`, exactly as
  /// `TransactionInspectorModifier` does. Re-seeding only when the category
  /// is still selected means a quick switch away while the debounce is
  /// pending does not clobber the new selection — while the write still
  /// lands, so the edit is never lost.
  private func save(_ updated: Category) {
    categoryStore.debouncedSave {
      if selectedCategory?.id == updated.id {
        selectedCategory = updated
      }
      Task { _ = await categoryStore.update(updated) }
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
              onUpdate: { updated in save(updated) },
              onDelete: { id, replacementId in
                Task {
                  if await categoryStore.delete(id: id, withReplacement: replacementId) {
                    selectedCategory = nil
                  }
                }
              }
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
              onUpdate: { updated in save(updated) },
              onDelete: { id, replacementId in
                Task {
                  if await categoryStore.delete(id: id, withReplacement: replacementId) {
                    selectedCategory = nil
                  }
                }
              }
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
          onCreate: { newCategory in
            Task {
              _ = await categoryStore.create(newCategory)
              showCreateSheet = false
            }
          }
        )
      }
      .focusedSceneValue(\.selectedCategory, $selectedCategory)
      .focusedSceneValue(\.newCategoryAction) {
        showCreateSheet = true
      }
      .onReceive(NotificationCenter.default.publisher(for: .requestCategoryEdit)) { note in
        guard let id = note.object as? UUID,
          let category = categoryStore.categories.by(id: id)
        else { return }
        selectedCategory = category
      }
  }

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
