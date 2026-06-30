import Foundation

struct Category: Codable, Sendable, Identifiable, Hashable {
  let id: UUID
  var name: String
  var parentId: UUID?

  init(id: UUID = UUID(), name: String, parentId: UUID? = nil) {
    self.id = id
    self.name = name
    self.parentId = parentId
  }
}

/// A lookup structure for categories, supporting hierarchy traversal.
struct Categories: Sendable {
  private let byId: [UUID: Category]
  private let childrenOf: [UUID?: [Category]]

  init(from categories: [Category]) {
    byId = categories.reduce(into: [:]) { $0[$1.id] = $1 }
    childrenOf = Dictionary(grouping: categories, by: \.parentId)
  }

  func by(id: UUID) -> Category? {
    byId[id]
  }

  /// Top-level categories (those with no parent).
  var roots: [Category] {
    (childrenOf[nil] ?? []).sorted { $0.name < $1.name }
  }

  /// Direct children of a given category.
  func children(of parentId: UUID) -> [Category] {
    (childrenOf[parentId] ?? []).sorted { $0.name < $1.name }
  }

  /// Whether `id` has at least one direct child. Single dictionary lookup —
  /// preferred over `!children(of: id).isEmpty` for hot per-row checks
  /// because it skips the array allocation and sort.
  func hasChildren(_ id: UUID) -> Bool {
    !(childrenOf[id]?.isEmpty ?? true)
  }

  /// Full path for a category, e.g. "Income:Salary:Janet".
  func path(for category: Category) -> String {
    var parts: [String] = [category.name]
    var current = category
    while let parentId = current.parentId, let parent = by(id: parentId) {
      parts.insert(parent.name, at: 0)
      current = parent
    }
    return parts.joined(separator: ":")
  }

  /// Reconcile a category autocomplete field's `(text, id)` pair against
  /// this snapshot — the shared blur-normalisation rule used by the
  /// transaction leg/simple category fields and the parent-category picker.
  ///
  /// - Empty/whitespace `text` → cleared (`nil` id, `""` text). Clearing the
  ///   field is the gesture that removes the category.
  /// - A non-empty `text` whose `id` resolves to a live category → `text`
  ///   reset to that category's canonical path (drops partially-typed input).
  /// - Anything else (no id, or an id that no longer resolves) → cleared.
  ///
  /// Returns the reconciled pair; callers assign it back to their own
  /// storage. Does not handle a highlighted suggestion — callers that
  /// support arrow-key selection commit that first and only fall through
  /// here when nothing is highlighted.
  func normalisedSelection(text: String, id: UUID?) -> (text: String, id: UUID?) {
    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return (text: "", id: nil)
    }
    if let id, let category = by(id: id) {
      return (text: path(for: category), id: id)
    }
    return (text: "", id: nil)
  }

  /// Every category in the subtree rooted at `parentId`, in depth-first
  /// pre-order with siblings sorted by name (inherited from `children(of:)`).
  ///
  /// The category identified by `parentId` is not included — callers that
  /// need to operate on the whole subtree (e.g. selecting parent + descendants
  /// for a multi-category filter) must add the root id themselves. Returns an
  /// empty array when `parentId` has no children or is not found.
  func descendants(of parentId: UUID) -> [Category] {
    var result: [Category] = []
    for child in children(of: parentId) {
      result.append(child)
      result.append(contentsOf: descendants(of: child.id))
    }
    return result
  }

  /// All ids in the subtree rooted at `id` — the id itself plus every
  /// descendant. The returned set is the unit operated on by callers
  /// who select or deselect a whole branch (e.g. the picker's subtree
  /// shortcut). For an id with no descendants — including ids that
  /// aren't in this `Categories` value — the result is the singleton
  /// containing only that id.
  func subtreeIds(of id: UUID) -> Set<UUID> {
    var ids: Set<UUID> = [id]
    ids.formUnion(descendants(of: id).lazy.map(\.id))
    return ids
  }

  /// Filter-trigger label for a multi-category selection.
  ///
  /// Callers that hold an arbitrary `Set<UUID>` (e.g. a persisted filter
  /// preference) use this instead of `path(for:)` directly because the
  /// selection may reference deleted categories. Orphaned ids are silently
  /// dropped so the label always reflects only categories that are still
  /// selectable: `"All"` when none remain, the full path when exactly one
  /// remains, and `"\(N) selected"` for two or more.
  func selectionSummary(for selectedIds: Set<UUID>) -> String {
    let presentIds = selectedIds.filter { byId[$0] != nil }
    switch presentIds.count {
    case 0:
      return "All"
    case 1:
      guard let id = presentIds.first, let category = byId[id] else { return "All" }
      return path(for: category)
    default:
      return "\(presentIds.count) selected"
    }
  }

  /// An entry in the flattened category list.
  struct FlatEntry: Sendable {
    let category: Category
    let path: String

    /// Hierarchy depth derived from the colon-separated path.
    /// Roots have depth `0`; each level of nesting adds `1`.
    ///
    /// - Precondition: `Category.name` values must not contain `":"`.
    ///   `path(for:)` uses `":"` as the hierarchy separator, so a colon
    ///   inside a name produces an artificially high depth and incorrect
    ///   indentation. The current model accepts arbitrary `String` names
    ///   without UI validation, so callers that synthesise categories
    ///   need to keep colons out of names themselves.
    var depth: Int { path.split(separator: ":").count - 1 }
  }

  /// All categories flattened with full paths, sorted alphabetically by path.
  func flattenedByPath() -> [FlatEntry] {
    var result: [FlatEntry] = []
    func collect(_ parentId: UUID?) {
      let children = parentId.map { self.children(of: $0) } ?? roots
      for child in children {
        result.append(FlatEntry(category: child, path: path(for: child)))
        collect(child.id)
      }
    }
    collect(nil)
    return result.sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
  }

  /// Subset of `flattenedByPath()` whose paths contain `query` (case-insensitive,
  /// substring match). Whitespace at either end of `query` is ignored. An empty
  /// or whitespace-only query returns the full result of `flattenedByPath()`.
  func flattenedByPath(matching query: String) -> [FlatEntry] {
    let trimmed = query.trimmingCharacters(in: .whitespaces)
    let all = flattenedByPath()
    guard !trimmed.isEmpty else { return all }
    return all.filter { $0.path.localizedCaseInsensitiveContains(trimmed) }
  }
}
