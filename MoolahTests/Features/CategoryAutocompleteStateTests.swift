import Foundation
import Testing

@testable import Moolah

@Suite("CategoryAutocompleteState")
struct CategoryAutocompleteStateTests {
  @Test
  func testCancelClosesDropdownWithoutArmingJustSelected() {
    var state = CategoryAutocompleteState(
      showSuggestions: true,
      highlightedIndex: 0,
      justSelected: false
    )

    state.cancel()

    #expect(state.showSuggestions == false)
    #expect(state.highlightedIndex == nil)
    // See `PayeeAutocompleteStateTests` for the reasoning — the text
    // didn't change on Escape, so the next keystroke must be free to
    // re-open the dropdown.
    #expect(state.justSelected == false)
  }

  @Test
  func testDismissArmsJustSelectedSoBindingDrivenOnChangeIsEaten() {
    var state = CategoryAutocompleteState(
      showSuggestions: true,
      highlightedIndex: 0,
      justSelected: false
    )

    state.dismiss()

    #expect(state.showSuggestions == false)
    #expect(state.highlightedIndex == nil)
    #expect(state.justSelected == true)
  }

  @Test
  func testHighlightedSuggestionReturnsTheArrowKeyedRow() {
    let groceriesId = UUID()
    let gymId = UUID()
    let categories = Categories(
      from: [
        Category(id: groceriesId, name: "Groceries"),
        Category(id: gymId, name: "Gym"),
      ])

    var state = CategoryAutocompleteState(
      showSuggestions: true,
      highlightedIndex: 1,
      justSelected: false
    )

    let highlighted = state.highlightedSuggestion(for: "G", in: categories)

    // The visible-suggestion list is sorted by path (canonical category
    // tree order), so index 1 of "G" is "Gym".
    #expect(highlighted?.id == gymId)
    #expect(highlighted?.path == "Gym")

    state.highlightedIndex = nil
    #expect(state.highlightedSuggestion(for: "G", in: categories) == nil)
  }

  @Test
  func testHighlightedSuggestionReturnsNilForOutOfRangeIndex() {
    let categories = Categories(from: [Category(id: UUID(), name: "Groceries")])

    let state = CategoryAutocompleteState(
      showSuggestions: true,
      highlightedIndex: 5,
      justSelected: false
    )

    #expect(state.highlightedSuggestion(for: "G", in: categories) == nil)
  }

  @Test
  func testHighlightedSuggestionReturnsNilWhenDropdownHidden() {
    let categories = Categories(from: [Category(id: UUID(), name: "Groceries")])

    let state = CategoryAutocompleteState(
      showSuggestions: false,
      highlightedIndex: 0,
      justSelected: false
    )

    #expect(state.highlightedSuggestion(for: "G", in: categories) == nil)
  }

  @Test
  func testCreateCategoryAutocompleteIgnoresMutationsWhileSubmitting() {
    let groceriesId = UUID()
    let gymId = UUID()
    let categories = Categories(
      from: [
        Category(id: groceriesId, name: "Groceries"),
        Category(id: gymId, name: "Gym"),
      ])
    let suggestion = CategorySuggestion(id: groceriesId, path: "Groceries")
    var state = CategoryAutocompleteState(showSuggestions: true, highlightedIndex: 0)
    var parent = ParentCategorySelection(id: nil, text: "G")

    #expect(
      !CreateCategoryParentAutocomplete.shouldShowSuggestions(
        isSubmitting: true,
        pickerState: state,
        visibleSuggestions: [suggestion]))

    state.showSuggestions = false
    CreateCategoryParentAutocomplete.openDropdownIfFocused(
      isSubmitting: true,
      isParentFocused: true,
      pickerState: &state)
    #expect(state.showSuggestions == false)
    state = CategoryAutocompleteState(showSuggestions: true, highlightedIndex: 0)

    CreateCategoryParentAutocomplete.acceptHighlightedParent(
      isSubmitting: true,
      pickerState: &state,
      parent: &parent,
      categories: categories)
    #expect(parent.id == nil)
    #expect(parent.text == "G")

    CreateCategoryParentAutocomplete.selectParent(
      isSubmitting: true,
      suggestion: suggestion,
      pickerState: &state,
      parent: &parent)
    #expect(parent.id == nil)
    #expect(parent.text == "G")

    CreateCategoryParentAutocomplete.handleParentBlur(
      isSubmitting: true,
      pickerState: &state,
      parent: &parent,
      categories: categories)
    #expect(state.showSuggestions == false)
    #expect(state.justSelected == false)
    #expect(parent.id == nil)
    #expect(parent.text == "G")
  }
}
