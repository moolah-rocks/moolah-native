import Foundation

/// Parent-category text + resolved id pair driven by the autocomplete
/// field in the create-category sheet (and any future edit sheet that
/// reparents an existing category). Bundles the two pieces so the blur
/// normalisation rules live in one testable place rather than as a
/// private method on the view.
///
/// Callers bind `text` to `CategoryAutocompleteField` and read `id`
/// when constructing the new `Category`. On suggestion accept, call
/// `commit(_:)`. On field blur, call `commitHighlightedOrNormalise(...)`.
struct ParentCategorySelection: Equatable {
  /// The resolved category id, or `nil` for a top-level category.
  var id: UUID?
  /// The text shown in the autocomplete field. Empty string means
  /// "no parent" — the user explicitly cleared it or never typed one.
  var text: String

  init(id: UUID? = nil, text: String = "") {
    self.id = id
    self.text = text
  }

  /// Build an initial selection from a pre-existing parent id by
  /// resolving its canonical path so the autocomplete field renders
  /// the path on first show. If `initialId` does not resolve to a
  /// live category — e.g. it was deleted on another device since the
  /// caller cached it — both `id` and `text` are cleared, preventing
  /// a submit from creating a new category with a dangling parent.
  init(initialId: UUID?, in categories: Categories) {
    if let id = initialId, let category = categories.by(id: id) {
      self.id = id
      self.text = categories.path(for: category)
    } else {
      self.id = nil
      self.text = ""
    }
  }

  /// Sets `id` and `text` to `suggestion` in a single mutating call.
  /// `TransactionDraft.commitCategorySelection` documents the constraint:
  /// SwiftUI snapshots between binding writes, so two separate writes
  /// can clobber each other; one mutating method avoids that.
  mutating func commit(_ suggestion: CategorySuggestion) {
    id = suggestion.id
    text = suggestion.path
  }

  /// Reconciles `text` with `id` on field blur. A highlighted suggestion at
  /// blur time wins — committing matches the simple-mode category field's
  /// behaviour that fixes Tab-from-highlight clearing the field (#509).
  /// Otherwise delegates to `Categories.normalisedSelection(text:id:)`: an
  /// empty field clears `id` ("no parent → top-level category"), a resolving
  /// id restores its canonical path, and an unresolvable id clears both.
  mutating func commitHighlightedOrNormalise(
    highlighted: CategorySuggestion?, in categories: Categories
  ) {
    if let highlighted {
      commit(highlighted)
      return
    }
    let normalised = categories.normalisedSelection(text: text, id: id)
    text = normalised.text
    id = normalised.id
  }
}
