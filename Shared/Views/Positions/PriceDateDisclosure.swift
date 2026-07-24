import SwiftUI

enum PriceDateDisclosureStyle {
  case full
  case compact
}

struct PriceDateDisclosureText {
  let oldestDate: Date

  var formattedDate: String {
    oldestDate.formatted(
      Date.FormatStyle(calendar: .utc, timeZone: .utc)
        .day()
        .month(.abbreviated))
  }

  var fullDate: String {
    oldestDate.formatted(
      Date.FormatStyle(calendar: .utc, timeZone: .utc)
        .day()
        .month(.wide)
        .year())
  }

  func label(for style: PriceDateDisclosureStyle) -> String {
    switch style {
    case .full:
      "Daily prices · oldest \(formattedDate)"
    case .compact:
      "Prices · \(formattedDate)"
    }
  }
}

/// Compact provenance disclosure for a converted aggregate. The visible date
/// is deliberately the oldest effective daily input: an aggregate is only as
/// current as its stalest market price or exchange rate.
struct PriceDateDisclosure: View {
  let oldestDate: Date
  var style: PriceDateDisclosureStyle = .full

  @State private var isShowingDetails = false

  private var text: PriceDateDisclosureText {
    PriceDateDisclosureText(oldestDate: oldestDate)
  }

  var body: some View {
    Button {
      isShowingDetails.toggle()
    } label: {
      Label(text.label(for: style), systemImage: "clock")
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(.secondary)
    }
    .buttonStyle(.plain)
    #if os(iOS)
      .frame(minHeight: 44)
      .contentShape(Rectangle())
    #endif
    .accessibilityLabel("Price information. Oldest daily price \(text.fullDate)")
    .accessibilityHint("Shows how the valuation date is determined")
    .popover(isPresented: $isShowingDetails, arrowEdge: .bottom) {
      VStack(alignment: .leading, spacing: 8) {
        Text("Price Data")
          .font(.headline)
        Text("Oldest daily input: \(text.fullDate)")
          .font(.body)
          .monospacedDigit()
        Text(
          "Values use completed daily market prices and exchange rates. Newer inputs may also contribute to this total."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      .frame(width: 280, alignment: .leading)
      .padding()
    }
  }
}

#Preview {
  PriceDateDisclosure(
    oldestDate: Calendar.utc.date(
      from: DateComponents(year: 2026, month: 7, day: 23)) ?? Date()
  )
  .padding()
}
