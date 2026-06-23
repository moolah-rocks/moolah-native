import SwiftUI
import Testing

@testable import Moolah

@Suite("CategoryColorAssignment")
struct CategoryColorAssignmentTests {
  @Test("Uncategorized (nil id) is always gray")
  func nilIsGray() {
    let assignment = CategoryColorAssignment(orderedCategoryIds: [nil, UUID()])
    #expect(assignment.color(for: nil) == .gray)
  }

  @Test("An id not present in the breakdown is gray")
  func unknownIdIsGray() {
    let assignment = CategoryColorAssignment(orderedCategoryIds: [UUID()])
    #expect(assignment.color(for: UUID()) == .gray)
  }

  @Test("Distinct categories take the palette colors in encounter order")
  func distinctCategoriesGetPaletteInOrder() {
    let ids = (0..<CategoryColorAssignment.palette.count).map { _ in UUID() }
    let assignment = CategoryColorAssignment(orderedCategoryIds: ids)
    for (index, id) in ids.enumerated() {
      #expect(assignment.color(for: id) == CategoryColorAssignment.palette[index])
    }
  }

  @Test("A nil slot does not consume a palette color")
  func uncategorizedDoesNotConsumePaletteSlot() {
    let first = UUID()
    let second = UUID()
    let assignment = CategoryColorAssignment(orderedCategoryIds: [first, nil, second])
    #expect(assignment.color(for: first) == CategoryColorAssignment.palette[0])
    #expect(assignment.color(for: second) == CategoryColorAssignment.palette[1])
  }

  @Test("Categories beyond the palette fall back to gray")
  func overflowCategoriesAreGray() {
    let count = CategoryColorAssignment.palette.count
    let ids = (0..<(count + 3)).map { _ in UUID() }  // three past the palette
    let assignment = CategoryColorAssignment(orderedCategoryIds: ids)
    #expect(assignment.color(for: ids[count - 1]) == CategoryColorAssignment.palette[count - 1])
    for overflowIndex in count..<ids.count {
      #expect(assignment.color(for: ids[overflowIndex]) == .gray)
    }
  }

  @Test("A category keeps the same color however often it appears")
  func repeatedIdsAreStable() {
    let first = UUID()
    let second = UUID()
    let assignment = CategoryColorAssignment(orderedCategoryIds: [first, second, first, second])
    #expect(assignment.color(for: first) == CategoryColorAssignment.palette[0])
    #expect(assignment.color(for: second) == CategoryColorAssignment.palette[1])
  }
}
