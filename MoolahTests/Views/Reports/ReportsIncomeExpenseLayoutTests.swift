import Foundation
import Testing

@testable import Moolah

@Suite("ReportsIncomeExpenseLayout")
struct ReportsIncomeExpenseLayoutTests {
  @Test("iPhone reports scroll Income then Expenses in one vertical flow")
  func iOSPresentationUsesOneVerticalScrollFlow() {
    #expect(
      ReportsIncomeExpenseLayout.iOSPresentation == [.singleVerticalScroll, .income, .expenses])
  }
}
