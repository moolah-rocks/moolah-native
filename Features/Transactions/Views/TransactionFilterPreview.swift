import SwiftUI

private struct TransactionFilterPreview: View {
  private let calendar: Calendar
  private let range: ClosedRange<Date>

  init() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Pacific/Kiritimati") ?? .gmt
    let end =
      calendar.date(
        from: DateComponents(year: 2026, month: 6, day: 15, hour: 23)) ?? Date()
    self.calendar = calendar
    self.range = (calendar.date(byAdding: .month, value: -1, to: end) ?? end)...end
  }

  var body: some View {
    TransactionFilterView(
      filter: TransactionFilter(dateRange: range, dateRangeCalendar: calendar),
      scopeAccountIds: [],
      accounts: Accounts(from: [
        Account(id: UUID(), name: "Checking", type: .bank, instrument: .AUD),
        Account(id: UUID(), name: "Savings", type: .bank, instrument: .AUD),
      ]),
      categories: Categories(from: [
        Category(id: UUID(), name: "Groceries", parentId: nil),
        Category(id: UUID(), name: "Transport", parentId: nil),
      ]),
      earmarks: Earmarks(from: [Earmark(name: "Emergency Fund", instrument: .AUD)]),
      onApply: { _ in })
  }
}

#Preview { TransactionFilterPreview() }
