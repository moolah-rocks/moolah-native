import SwiftUI

/// The "Type" picker section.
///
/// Renders one of three forms depending on the underlying transaction:
/// - Read-only "Opening balance" label when any leg is an opening balance
///   (the user can't change the type of the seed transaction).
/// - Read-only "Custom" label when the transaction has no sub-transactions or
///   has multi-leg structure that can't be re-expressed as a simple
///   income/expense/transfer/trade.
/// - The interactive `Picker` of income / expense / transfer / trade / custom.
///
/// While the interactive picker is visible, the section publishes a
/// `setTransactionTypeAction` focused-scene-value so the Transaction > Type
/// menu items (⌥⌘1–⌥⌘5) drive the same code path as the picker — even
/// while a text field has focus. Focus is migrated to the new mode's
/// primary amount slot when the form structure changes (see
/// `TransactionDetailFocus.remapping(toStructure:)`).
struct TransactionDetailModeSection: View {
  let transaction: Transaction
  @Binding var draft: TransactionDraft
  let accounts: Accounts
  @FocusState.Binding var focusedField: TransactionDetailFocus?

  /// Available modes, in display order (also the ⌥⌘1–⌥⌘5 mapping).
  private static let modes: [TransactionDetailMode] = [
    .income, .expense, .transfer, .trade, .custom,
  ]

  private var modeBinding: Binding<TransactionDetailMode> {
    Binding(get: { currentMode() }, set: { applyModeChange(to: $0) })
  }

  private func currentMode() -> TransactionDetailMode {
    if draft.isCustom { return .custom }
    if draft.legDrafts.contains(where: { $0.type == .trade }) { return .trade }
    switch draft.type {
    case .income: return .income
    case .expense: return .expense
    case .transfer: return .transfer
    case .openingBalance: return .expense
    case .trade: return .trade
    }
  }

  /// Apply a mode change and migrate focus when the form's structure
  /// changes. Used by both the picker binding and the menu-driven
  /// `setTransactionTypeAction` so the two paths share semantics.
  private func applyModeChange(to newMode: TransactionDetailMode) {
    let oldStructure = currentMode().focusStructure
    let newStructure = newMode.focusStructure
    applyMode(newMode)
    guard oldStructure != newStructure, let oldFocus = focusedField else { return }
    focusedField = oldFocus.remapping(toStructure: newStructure)
  }

  private func applyMode(_ newMode: TransactionDetailMode) {
    let wasTrade = draft.legDrafts.contains { $0.type == .trade }
    switch newMode {
    case .custom: draft.isCustom = true
    case .trade: setTradeMode(wasTrade: wasTrade)
    case .income: setSimpleMode(.income, wasTrade: wasTrade)
    case .expense: setSimpleMode(.expense, wasTrade: wasTrade)
    case .transfer: setSimpleMode(.transfer, wasTrade: wasTrade)
    }
  }

  private func setTradeMode(wasTrade: Bool) {
    if wasTrade && draft.isCustom {
      draft.isCustom = false
    } else if !wasTrade {
      guard draft.canSwitchToTrade(accounts: accounts) else { return }
      draft.switchToTrade(accounts: accounts)
    }
  }

  private func setSimpleMode(_ type: TransactionType, wasTrade: Bool) {
    if wasTrade {
      draft.switchFromTrade(to: type, accounts: accounts)
    } else if draft.isCustom {
      guard draft.canSwitchToSimple else { return }
      draft.switchToSimple()
      draft.setType(type, accounts: accounts)
    } else {
      draft.setType(type, accounts: accounts)
    }
  }

  /// Single source of truth for whether the type can be interactively
  /// changed. Drives both the body's branching (picker vs read-only label)
  /// and the publication of `setTransactionTypeAction` to the menu.
  private var pickerInteractive: Bool {
    guard !draft.legDrafts.isEmpty else { return false }
    let hasOpeningBalance = transaction.legs.contains(where: { $0.type == .openingBalance })
    let irreducibleCustom =
      !transaction.isSimple && !transaction.isTrade && !draft.isCustom
    return !hasOpeningBalance && !irreducibleCustom
  }

  private var hasOpeningBalance: Bool {
    transaction.legs.contains { $0.type == .openingBalance }
  }

  private var readOnlyCustomAccessibilityHint: String {
    if draft.legDrafts.isEmpty {
      return "Add a sub-transaction before changing the transaction type."
    }
    return "This transaction has custom sub-transactions and cannot be changed to a simpler type."
  }

  var body: some View {
    Section {
      if hasOpeningBalance {
        LabeledContent("Type") {
          Text(TransactionType.openingBalance.displayName)
            .foregroundStyle(.secondary)
        }
      } else if !pickerInteractive {
        LabeledContent("Type") {
          Text("Custom").foregroundStyle(.secondary)
        }
        .accessibilityHint(readOnlyCustomAccessibilityHint)
      } else {
        Picker("Type", selection: modeBinding) {
          ForEach(Self.modes, id: \.self) { mode in
            Text(mode.displayName).tag(mode)
          }
        }
        .accessibilityLabel("Transaction type")
        .accessibilityIdentifier(UITestIdentifiers.Detail.modeTypePicker)
        #if os(iOS)
          .pickerStyle(.segmented)
          .background { iPadShortcutButtons }
        #else
          .focusedSceneValue(\.setTransactionTypeAction) { mode in
            applyModeChange(to: mode)
          }
        #endif
      }
    }
  }

  #if os(iOS)
    /// Hidden buttons that bind ⌥⌘1–⌥⌘5 on iPad with a hardware keyboard.
    /// macOS uses the Transaction > Type menu items instead (per UI Guide
    /// §14), but iOS has no menu bar — `keyboardShortcut` only fires when
    /// the bound `Button` is in the view tree, hence this tiny invisible
    /// surface placed inside the section's `.background` so it joins the
    /// responder chain only while the picker is visible.
    @ViewBuilder private var iPadShortcutButtons: some View {
      HStack(spacing: 0) {
        shortcutButton(label: "Income", key: "1") { applyModeChange(to: .income) }
        shortcutButton(label: "Expense", key: "2") { applyModeChange(to: .expense) }
        shortcutButton(label: "Transfer", key: "3") { applyModeChange(to: .transfer) }
        shortcutButton(label: "Trade", key: "4") { applyModeChange(to: .trade) }
        shortcutButton(label: "Custom", key: "5") { applyModeChange(to: .custom) }
      }
      .frame(width: 0, height: 0)
      .opacity(0)
      .accessibilityHidden(true)
    }

    private func shortcutButton(
      label: String, key: KeyEquivalent, action: @escaping () -> Void
    ) -> some View {
      Button(label, action: action)
        .keyboardShortcut(key, modifiers: [.option, .command])
    }
  #endif
}
