import Charts
import SwiftUI

struct InvestmentValuesView: View {
  let account: Account
  let store: InvestmentStore
  @State private var showingAddValue = false

  var body: some View {
    VStack(spacing: 0) {
      if store.values.isEmpty && !store.isLoading {
        ContentUnavailableView(
          "No Values Recorded",
          systemImage: "chart.line.uptrend.xyaxis",
          description: Text("Record a value to start tracking this investment over time.")
        )
      } else {
        if store.values.count > 1 {
          ExpandableChart(title: account.name) {
            investmentChart
              .frame(height: 200)
          }
          .padding()

          Divider()
        }

        List {
          ForEach(store.values) { value in
            InvestmentValueListRow(value: value) {
              Task {
                await store.removeValue(accountId: account.id, date: value.date)
              }
            }
          }
        }
        .listStyle(.inset)
      }
    }
    .navigationTitle(account.name)
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          showingAddValue = true
        } label: {
          Label("Add Value", systemImage: "plus")
        }
      }
    }
    .sheet(isPresented: $showingAddValue) {
      AddInvestmentValueView(
        accountId: account.id, instrument: account.instrument, store: store)
    }
    .task {
      await store.loadValues(accountId: account.id)
    }
    .refreshable {
      await store.loadValues(accountId: account.id)
    }
  }

  @ViewBuilder private var investmentChart: some View {
    let chartValues = store.values.reversed()
    Chart {
      ForEach(chartValues) { value in
        LineMark(
          x: .value("Date", value.date),
          y: .value("Value", Double(truncating: value.value.quantity as NSDecimalNumber))
        )
        .foregroundStyle(Color.chartBlue)
        .interpolationMethod(.catmullRom)

        AreaMark(
          x: .value("Date", value.date),
          y: .value("Value", Double(truncating: value.value.quantity as NSDecimalNumber))
        )
        .foregroundStyle(Color.chartBlue.opacity(0.1))
        .interpolationMethod(.catmullRom)
      }
    }
    .chartYAxis {
      AxisMarks(position: .leading) { axisValue in
        if let decimal = axisValue.as(Decimal.self) {
          AxisValueLabel {
            Text(decimal, format: .currency(code: account.instrument.id))
              .font(.caption)
              .monospacedDigit()
          }
        }
      }
    }
    .chartXAxis {
      AxisMarks { axisValue in
        if let date = axisValue.as(Date.self) {
          AxisValueLabel {
            Text(date, format: .dateTime.month(.abbreviated).year())
              .font(.caption)
          }
        }
      }
    }
    .accessibilityLabel("Investment value over time")
  }
}

#Preview {
  let backend = PreviewBackend.create()
  let store = InvestmentStore(
    repository: backend.investments,
    transactionRepository: backend.transactions,
    conversionService: backend.conversionService
  )
  let account = Account(
    name: "Brokerage",
    type: .investment,
    instrument: .AUD
  )
  NavigationStack {
    InvestmentValuesView(account: account, store: store)
  }
  .frame(width: 560, height: 480)
  .task {
    _ = try? await backend.accounts.create(account, openingBalance: .zero(instrument: .AUD))
    let calendar = Calendar.current
    for monthsAgo in (0..<6).reversed() {
      let date = calendar.date(byAdding: .month, value: -monthsAgo, to: Date()) ?? Date()
      let quantity: Decimal = 9_000 + Decimal(6 - monthsAgo) * 350
      await store.setValue(
        accountId: account.id,
        date: date,
        value: InstrumentAmount(quantity: quantity, instrument: .AUD)
      )
    }
    await store.loadValues(accountId: account.id)
  }
}
