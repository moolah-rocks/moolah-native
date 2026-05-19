import SwiftUI

// Sheets presented by `RecentlyAddedView` — the read-only transaction
// summary for the "Open" context-menu action and the search-to-rule
// shortcut. Both types are file-visible to this feature and referenced
// only from `RecentlyAddedView`.

/// Thin read-only transaction summary for the Recently Added context-menu
/// "Open" action. Shows date, amount, legs, and the raw import origin so
/// the user can verify what was imported without launching the full
/// editor. For edits, they navigate to the transaction list and open it
/// there.
struct RecentlyAddedDetailSheet: View {
  let transaction: Transaction
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      detailForm
        .formStyle(.grouped)
        .navigationTitle("Transaction")
        .toolbar {
          ToolbarItem(placement: .confirmationAction) {
            Button("Done") { dismiss() }
          }
        }
        #if os(macOS)
          .frame(minWidth: 480, minHeight: 420)
        #endif
    }
  }
}

extension RecentlyAddedDetailSheet {
  private var detailForm: some View {
    Form {
      transactionSection
      legsSection
      importOriginSection
    }
  }

  private var transactionSection: some View {
    Section("Transaction") {
      LabeledContent("Date") {
        Text(transaction.date, format: .dateTime.day().month().year())
          .monospacedDigit()
      }
      if let payee = transaction.payee, !payee.isEmpty {
        LabeledContent("Payee", value: payee)
      }
      if let notes = transaction.notes, !notes.isEmpty {
        LabeledContent("Notes", value: notes)
      }
    }
  }

  private var legsSection: some View {
    Section("Legs") {
      ForEach(transaction.legs) { leg in
        HStack {
          Text(leg.type.rawValue.capitalized)
            .foregroundStyle(.secondary)
          Spacer()
          InstrumentAmountView(
            amount: InstrumentAmount(
              quantity: leg.quantity, instrument: leg.instrument),
            font: .body)
        }
        .accessibilityElement(children: .combine)
      }
    }
  }

  @ViewBuilder private var importOriginSection: some View {
    if let origin = transaction.importOrigin?.singleOrigin {
      Section("Import origin") {
        LabeledContent("Source", value: origin.sourceFilename ?? origin.parserIdentifier)
        LabeledContent("Raw description", value: origin.rawDescription)
        if let ref = origin.bankReference, !ref.isEmpty {
          LabeledContent("Bank reference", value: ref)
        }
        LabeledContent("Imported") {
          Text(origin.importedAt, format: .dateTime.day().month().year().hour().minute())
            .monospacedDigit()
        }
      }
    }
  }
}

/// Bridges a Recently Added search query into a pre-filled rule editor.
/// The query is tokenised on whitespace; each token becomes a term in a
/// single `descriptionContains` condition.
struct RecentlyAddedRuleFromSearchSheet: View {
  let query: String
  @Environment(ImportRuleStore.self) private var ruleStore

  var body: some View {
    RuleEditorView(
      initialRule: ImportRule(
        name: "Rule from \"\(query.prefix(20))\"",
        position: ruleStore.rules.count,
        conditions: [.descriptionContains(tokens)],
        actions: []),
      onSave: { rule in
        Task { await ruleStore.create(rule) }
      })
  }
}

extension RecentlyAddedRuleFromSearchSheet {
  private var tokens: [String] {
    query
      .split(separator: " ", omittingEmptySubsequences: true)
      .map { String($0) }
  }
}
