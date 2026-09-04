import SwiftUI

/// Rule editor sheet. Two sections — Conditions (If any/all of these are
/// true) and Actions (Perform these). Each row has a field/operator/value
/// dropdown. Save writes back through the `onSave` closure; Cancel throws
/// the draft away.
struct RuleEditorView: View {
  @State private var rule: ImportRule
  /// UUID-keyed view-state wrappers around each condition / action. Using
  /// stable IDs (rather than `Array.Index` offsets) keeps SwiftUI's view
  /// identity pinned to the same row after a mid-list delete, so focus,
  /// in-flight text edits, and Binding reads don't jump to a stale index.
  @State private var identifiedConditions: [IdentifiedCondition]
  @State private var identifiedActions: [IdentifiedAction]
  @State private var affectedCount: Int?
  @State private var countingTask: Task<Void, Never>?
  let onSave: (ImportRule) -> Void
  @Environment(\.dismiss) private var dismiss
  @Environment(CategoryStore.self) private var categoryStore
  @Environment(AccountStore.self) private var accountStore
  @Environment(ImportRuleStore.self) private var ruleStore
  @Environment(ProfileSession.self) private var session

  init(initialRule: ImportRule, onSave: @escaping (ImportRule) -> Void) {
    _rule = State(initialValue: initialRule)
    _identifiedConditions = State(
      initialValue: initialRule.conditions.map {
        IdentifiedCondition(id: UUID(), condition: $0)
      })
    _identifiedActions = State(
      initialValue: initialRule.actions.map {
        IdentifiedAction(id: UUID(), action: $0)
      })
    self.onSave = onSave
  }

  var body: some View {
    NavigationStack {
      form
    }
    #if os(macOS)
      .frame(minWidth: 540, minHeight: 520)
    #endif
  }

  private var form: some View {
    Form {
      ruleSection
      conditionsSection
      actionsSection
      previewSection
    }
    .formStyle(.grouped)
    .navigationTitle(rule.name.isEmpty ? "New Rule" : rule.name)
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button("Cancel") { dismiss() }
      }
      ToolbarItem(placement: .confirmationAction) {
        Button("Save") {
          var out = rule
          out.conditions = identifiedConditions.map(\.condition)
          out.actions = identifiedActions.map(\.action)
          onSave(out)
          dismiss()
        }
        .disabled(rule.name.isEmpty)
      }
    }
    .task(id: previewKey) {
      await schedulePreview()
    }
  }

  private var ruleSection: some View {
    Section(header: Text("Rule")) {
      TextField("Name", text: $rule.name)
      Toggle("Enabled", isOn: $rule.enabled)
      Picker(
        "Applies to",
        selection: Binding(
          get: { rule.accountScope },
          set: { rule.accountScope = $0 })
      ) {
        Text("All accounts").tag(UUID?.none)
        ForEach(accountStore.accounts.ordered, id: \.id) { account in
          Text(account.name).tag(UUID?.some(account.id))
        }
      }
    }
  }

  private var conditionsSection: some View {
    Section(header: Text("If \(matchModeLabel) of these are true")) {
      Picker("Match mode", selection: $rule.matchMode) {
        Text("All").tag(MatchMode.all)
        Text("Any").tag(MatchMode.any)
      }
      .pickerStyle(.segmented)
      ForEach($identifiedConditions) { $item in
        RuleEditorConditionRow(
          condition: $item.condition,
          onDelete: {
            identifiedConditions.removeAll { $0.id == item.id }
          })
      }
      Button {
        identifiedConditions.append(
          IdentifiedCondition(id: UUID(), condition: .descriptionContains([""])))
      } label: {
        Label("Add Condition", systemImage: "plus.circle")
      }
    }
  }

  private var actionsSection: some View {
    Section(header: Text("Perform these actions")) {
      ForEach($identifiedActions) { $item in
        RuleEditorActionRow(
          action: $item.action,
          categories: categoryStore.categories,
          accounts: accountStore.accounts,
          onDelete: {
            identifiedActions.removeAll { $0.id == item.id }
          })
      }
      addActionMenu
    }
  }

  @ViewBuilder private var addActionMenu: some View {
    Menu {
      Button("Set Payee") {
        identifiedActions.append(
          IdentifiedAction(id: UUID(), action: .setPayee("")))
      }
      // Only offer Set Category when categories exist — spec forbids
      // rules referencing invented category UUIDs.
      if let firstCategory = categoryStore.categories.flattenedByPath().first?.category {
        Button("Set Category") {
          identifiedActions.append(
            IdentifiedAction(id: UUID(), action: .setCategory(firstCategory.id)))
        }
      }
      Button("Append Note") {
        identifiedActions.append(
          IdentifiedAction(id: UUID(), action: .appendNote("")))
      }
      if let firstAccount = accountStore.accounts.ordered.first {
        Button("Mark as Transfer") {
          identifiedActions.append(
            IdentifiedAction(
              id: UUID(),
              action: .markAsTransfer(toAccountId: firstAccount.id)))
        }
      }
      Button("Skip Row") {
        identifiedActions.append(
          IdentifiedAction(id: UUID(), action: .skip))
      }
    } label: {
      Label("Add Action", systemImage: "plus.circle")
    }
  }

  private var previewSection: some View {
    Section(header: Text("Preview")) {
      HStack(spacing: 6) {
        if affectedCount == nil {
          ProgressView().controlSize(.small)
        }
        Text(previewText)
          .font(.subheadline)
          .foregroundStyle(affectedCount == nil ? .secondary : .primary)
      }
    }
  }

  /// Serialises the conditions + matchMode + accountScope so the preview
  /// task cancels and re-runs on any change, but not on name / action edits
  /// (which don't affect the match set).
  private var previewKey: String {
    var bits: [String] = [rule.matchMode.rawValue]
    for item in identifiedConditions {
      bits.append(String(describing: item.condition))
    }
    if let scope = rule.accountScope {
      bits.append("scope:\(scope.uuidString)")
    }
    return bits.joined(separator: "|")
  }

  private var previewText: String {
    guard let count = affectedCount else {
      return "Counting past transactions…"
    }
    switch count {
    case 0: return "No past transactions would match this rule."
    case 1: return "1 past transaction would match this rule."
    default: return "\(count) past transactions would match this rule."
    }
  }

  /// Wait a short debounce before re-counting so typing in the token
  /// editor doesn't hammer the backend.
  private func schedulePreview() async {
    affectedCount = nil
    do {
      try await Task.sleep(nanoseconds: 500_000_000)
    } catch {
      return
    }
    if Task.isCancelled { return }
    let count = await ruleStore.countAffected(
      conditions: identifiedConditions.map(\.condition),
      matchMode: rule.matchMode,
      accountScope: rule.accountScope,
      backend: session.backend)
    if Task.isCancelled { return }
    affectedCount = count
  }

  private var matchModeLabel: String {
    rule.matchMode == .all ? "all" : "any"
  }
}

// MARK: - UUID-keyed view-state wrappers

/// Wraps a `RuleCondition` with a persistent UUID so SwiftUI `ForEach` can
/// keep view identity stable across mid-list deletes. Mirrors into
/// `rule.conditions` on Save.
private struct IdentifiedCondition: Identifiable {
  let id: UUID
  var condition: RuleCondition
}

/// Wraps a `RuleAction` with a persistent UUID for the same reason.
private struct IdentifiedAction: Identifiable {
  let id: UUID
  var action: RuleAction
}

// `RuleEditorConditionRow` / `RuleEditorConditionKind` live in
// `RuleEditorConditionRow.swift`; `RuleEditorActionRow` / `RuleEditorActionKind`
// live in `RuleEditorActionRow.swift`.
