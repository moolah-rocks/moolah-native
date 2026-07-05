// Row builders and totals for `EarmarkBudgetSectionView`, split out to keep
// the main type body under the `type_body_length` threshold (see
// `SidebarView` / `SidebarView+Sections.swift` for the established precedent
// of this split). These members read/write state declared on the primary
// type as `internal` rather than `private` for that reason.

import SwiftUI

extension EarmarkBudgetSectionView {
  var totalActual: InstrumentAmount {
    // All line items share the earmark's instrument (see
    // `guides/INSTRUMENT_CONVERSION_GUIDE.md` Rule 1/2). Budget items are
    // stored in the earmark's instrument; category balances are fetched
    // with `targetInstrument: earmark.instrument` in the primary file.
    lineItems.reduce(.zero(instrument: earmark.instrument)) { $0 + $1.actual }
  }

  var totalBudgeted: InstrumentAmount {
    lineItems.reduce(.zero(instrument: earmark.instrument)) { $0 + $1.budgeted }
  }

  var totalRemaining: InstrumentAmount {
    totalBudgeted + totalActual
  }

  var unallocated: InstrumentAmount? {
    BudgetLineItem.unallocatedAmount(
      budgetItems: earmarkStore.budgetItems,
      savingsGoal: earmark.savingsGoal
    )
  }

  var budgetList: some View {
    List {
      Section {
        headerRow
          .listRowBackground(Color.clear)

        ForEach(lineItems) { lineItem in
          budgetRow(lineItem)
            // The synthesized "Uncategorised" row has no backing budget item
            // to remove (see `deleteBudgetItems`) — suppress the swipe
            // affordance instead of silently no-oping on it.
            .deleteDisabled(lineItem.id == BudgetLineItem.uncategorisedId)
        }
        .onDelete { offsets in
          deleteBudgetItems(at: offsets)
        }
      }

      Section {
        totalRow

        if let unallocated {
          unallocatedRow(unallocated)
        }
      }
    }
    #if os(macOS)
      .listStyle(.inset)
    #else
      .listStyle(.plain)
    #endif
  }

  var headerRow: some View {
    HStack(spacing: 0) {
      Text("Category")
        .frame(maxWidth: .infinity, alignment: .leading)
      Text("Actual")
        .frame(minWidth: columnMinWidth, idealWidth: columnIdealWidth, alignment: .trailing)
      Text("Budget")
        .frame(minWidth: columnMinWidth, idealWidth: columnIdealWidth, alignment: .trailing)
      Text("Remaining")
        .frame(minWidth: columnMinWidth, idealWidth: columnIdealWidth, alignment: .trailing)
    }
    .font(.caption)
    .foregroundStyle(.secondary)
    .accessibilityAddTraits(.isHeader)
  }

  func budgetRow(_ lineItem: BudgetLineItem) -> some View {
    // The synthesized "Uncategorised" row (see `BudgetLineItem.uncategorisedId`) has no
    // real category behind it, so its budget cell isn't editable — tapping to edit would
    // otherwise save a budget item keyed to the sentinel id.
    let isUncategorisedRow = lineItem.id == BudgetLineItem.uncategorisedId

    return HStack(spacing: 0) {
      Text(lineItem.categoryPath)
        .frame(maxWidth: .infinity, alignment: .leading)
        .font(.body)

      InstrumentAmountView(amount: lineItem.actual)
        .font(.body)
        .frame(minWidth: columnMinWidth, idealWidth: columnIdealWidth, alignment: .trailing)

      Group {
        if isUncategorisedRow {
          // `.secondary` (rather than the editable rows' `.primary`) signals
          // this cell is non-interactive — there is no budget item behind
          // the synthesized "Uncategorised" row to edit.
          InstrumentAmountView(amount: lineItem.budgeted, colorOverride: .secondary)
        } else {
          Button {
            editingLineItem = lineItem
          } label: {
            InstrumentAmountView(amount: lineItem.budgeted, colorOverride: .primary)
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Edit budget for \(lineItem.categoryPath)")
        }
      }
      .font(.body)
      .frame(minWidth: columnMinWidth, idealWidth: columnIdealWidth, alignment: .trailing)

      InstrumentAmountView(amount: lineItem.remaining)
        .font(.body)
        .frame(minWidth: columnMinWidth, idealWidth: columnIdealWidth, alignment: .trailing)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      "\(lineItem.categoryPath): spent \(lineItem.actual.formatted), budget \(lineItem.budgeted.formatted), remaining \(lineItem.remaining.formatted)"
    )
  }

  var totalRow: some View {
    HStack(spacing: 0) {
      Text("Total")
        .font(.headline)
        .frame(maxWidth: .infinity, alignment: .leading)

      InstrumentAmountView(amount: totalActual)
        .font(.headline)
        .frame(minWidth: columnMinWidth, idealWidth: columnIdealWidth, alignment: .trailing)

      InstrumentAmountView(amount: totalBudgeted, colorOverride: .primary)
        .font(.headline)
        .frame(minWidth: columnMinWidth, idealWidth: columnIdealWidth, alignment: .trailing)

      InstrumentAmountView(amount: totalRemaining)
        .font(.headline)
        .frame(minWidth: columnMinWidth, idealWidth: columnIdealWidth, alignment: .trailing)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      "Total: spent \(totalActual.formatted), budget \(totalBudgeted.formatted), remaining \(totalRemaining.formatted)"
    )
  }

  func unallocatedRow(_ amount: InstrumentAmount) -> some View {
    HStack(spacing: 0) {
      Text("Unallocated")
        .font(.body)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)

      Spacer()
        .frame(minWidth: columnMinWidth, idealWidth: columnIdealWidth)

      InstrumentAmountView(amount: amount)
        .font(.body)
        .frame(minWidth: columnMinWidth, idealWidth: columnIdealWidth, alignment: .trailing)

      InstrumentAmountView(amount: amount)
        .font(.body)
        .frame(minWidth: columnMinWidth, idealWidth: columnIdealWidth, alignment: .trailing)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Unallocated: \(amount.formatted)")
  }

  func deleteBudgetItems(at offsets: IndexSet) {
    let items = lineItems
    // Use confirmation for first item; swipe-delete only allows single items.
    // The synthesized "Uncategorised" row has no backing budget item to remove.
    if let first = offsets.first, items[first].id != BudgetLineItem.uncategorisedId {
      deleteConfirmation = items[first]
    }
  }
}
