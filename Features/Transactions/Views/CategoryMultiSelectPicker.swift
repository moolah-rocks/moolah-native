import SwiftUI

/// Searchable, hierarchical multi-select picker for categories.
struct CategoryMultiSelectPicker: View {
  let categories: Categories
  @Binding var selectedIds: Set<UUID>

  @State private var searchText: String = ""

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      #if os(macOS)
        searchField
        Divider()
      #endif
      list
    }
    #if os(iOS)
      // `.searchable` installs a search item into the surrounding
      // navigation/toolbar. That is fine for the iOS `NavigationLink`
      // host, but on macOS this picker is presented inside a `.popover`,
      // where routing a search item through the window's `NSToolbar`
      // bridge crashes (`-[NSToolbar _insertNewItemWithItemIdentifier:…]`
      // during the popover's preference update). macOS therefore uses the
      // inline `searchField` above instead. Mirrors `AccountMultiSelectPicker`.
      .searchable(text: $searchText, prompt: "Search categories")
      .navigationTitle("Categories")
      .navigationBarTitleDisplayMode(.inline)
    #endif
  }

  #if os(macOS)
    /// Inline search field for the macOS popover host — see the note on
    /// `.searchable` in `body` for why the toolbar-backed modifier can't
    /// be used here.
    private var searchField: some View {
      HStack(spacing: 6) {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
        TextField("Search categories", text: $searchText)
          .textFieldStyle(.plain)
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 5)
      .background(.quinary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
      .padding(.horizontal, 16)
      .padding(.vertical, 8)
    }
  #endif

  // Inline header rather than `.toolbar`: SwiftUI toolbar items don't
  // render inside a macOS popover, so a toolbar Clear would be invisible
  // on the macOS host. The inline header works on both platforms.
  // The macOS popover gets its title from the inline label below; the
  // iOS NavigationLink host already supplies one via `navigationTitle`.
  private var header: some View {
    HStack {
      #if os(macOS)
        Text("Categories")
          .font(.headline)
      #endif
      Spacer()
      // Whole-value reassignment for the same propagation reason as
      // the per-row toggle.
      Button("Clear") { selectedIds = [] }
        .disabled(selectedIds.isEmpty)
        .help("Clear all selected categories")
        .accessibilityLabel("Clear selected categories")
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
  }

  private var list: some View {
    List {
      if categories.roots.isEmpty {
        ContentUnavailableView("No Categories", systemImage: "folder")
      } else if visibleEntries.isEmpty {
        ContentUnavailableView.search(text: searchText)
      } else {
        ForEach(visibleEntries, id: \.category.id) { entry in
          row(for: entry)
        }
      }
    }
    .listStyle(.plain)
  }

  private var visibleEntries: [Categories.FlatEntry] {
    categories.flattenedByPath(matching: searchText)
  }

  private func row(for entry: Categories.FlatEntry) -> some View {
    let label = searchText.isEmpty ? entry.category.name : entry.path
    let indent = searchText.isEmpty ? entry.depth : 0
    let isParent = categories.hasChildren(entry.category.id)
    return Toggle(
      isOn: Binding(
        get: { selectedIds.contains(entry.category.id) },
        set: { isOn in
          // Read-modify-write the whole `Set<UUID>` rather than calling
          // a mutating method (`insert(_:)` / `remove(_:)`) on the
          // `@Binding` projection. The mutating-method form did not
          // propagate updates back to the host's `@State` when the
          // picker was hosted inside a macOS popover (issue #781).
          // Whole-value reassignment goes through `Binding.wrappedValue`'s
          // `nonmutating set` unambiguously, which fixes it. The same
          // pattern is mirrored in the Clear button and in
          // `SubtreeContextMenu` below.
          var updated = selectedIds
          if isOn {
            updated.insert(entry.category.id)
          } else {
            updated.remove(entry.category.id)
          }
          selectedIds = updated
        }
      )
    ) {
      Text(label)
        .lineLimit(2)
        .truncationMode(.tail)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.leading, CGFloat(indent * 16))
    .contentShape(.rect)
    .accessibilityLabel(entry.path)
    .accessibilityHint(entry.depth > 0 ? "Subcategory" : "Top-level category")
    .modifier(
      SubtreeContextMenu(
        category: entry.category,
        path: entry.path,
        isParent: isParent,
        categories: categories,
        selectedIds: $selectedIds
      )
    )
  }
}

/// Conditional context menu attached only to parent rows. Avoids the
/// "always-attached, empty-on-leaves" pattern, which can intercept
/// right-click on some SwiftUI versions even when the menu body is empty.
///
/// "Select all in <Parent>" intentionally selects the parent itself plus
/// every descendant — the unit `Categories.subtreeIds(of:)` returns. The
/// per-row `Toggle` still toggles only the parent for users who want
/// finer-grained control.
private struct SubtreeContextMenu: ViewModifier {
  let category: Category
  let path: String
  let isParent: Bool
  let categories: Categories
  @Binding var selectedIds: Set<UUID>

  func body(content: Content) -> some View {
    if isParent {
      content.contextMenu {
        Button("Select all in \(category.name)") {
          selectedIds = selectedIds.union(categories.subtreeIds(of: category.id))
        }
        .accessibilityLabel("Select all in \(path)")
        Button("Deselect all in \(category.name)") {
          selectedIds = selectedIds.subtracting(categories.subtreeIds(of: category.id))
        }
        .accessibilityLabel("Deselect all in \(path)")
      }
    } else {
      content
    }
  }
}

#Preview {
  @Previewable @State var selected: Set<UUID> = []

  let groceries = Category(name: "Groceries")
  let costco = Category(name: "Costco", parentId: groceries.id)
  let farmers = Category(name: "Farmers Market", parentId: groceries.id)
  let transport = Category(name: "Transport")
  let fuel = Category(name: "Fuel", parentId: transport.id)

  let categories = Categories(from: [
    groceries, costco, farmers, transport, fuel,
  ])

  return CategoryMultiSelectPicker(
    categories: categories,
    selectedIds: $selected
  )
  .frame(width: 320, height: 420)
}
