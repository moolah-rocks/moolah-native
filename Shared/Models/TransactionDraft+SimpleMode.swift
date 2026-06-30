import Foundation

// MARK: - Computed Accessors (Simple Mode)

extension TransactionDraft {
  /// The leg the simple UI binds to for amount display/editing.
  var relevantLeg: LegDraft {
    get { legDrafts[relevantLegIndex] }
    set { legDrafts[relevantLegIndex] = newValue }
  }

  /// The counterpart leg in a simple transfer (the leg that isn't the relevant one).
  /// Nil for non-transfer simple transactions.
  var counterpartLeg: LegDraft? {
    guard legDrafts.count == 2 else { return nil }
    let otherIndex = relevantLegIndex == 0 ? 1 : 0
    return legDrafts[otherIndex]
  }

  /// Index of the counterpart leg (the one that isn't the relevant leg) in a simple transfer.
  /// Nil for non-transfer simple transactions. Implementation detail of the simple-mode helpers.
  var counterpartLegIndex: Int? {
    guard legDrafts.count == 2 else { return nil }
    return relevantLegIndex == 0 ? 1 : 0
  }

  /// The transaction type, read from the relevant leg.
  var type: TransactionType {
    relevantLeg.type
  }

  /// The account on the relevant leg.
  var accountId: UUID? {
    get { relevantLeg.accountId }
    set { legDrafts[relevantLegIndex].accountId = newValue }
  }

  /// The display amount text from the relevant leg.
  var amountText: String {
    relevantLeg.amountText
  }

  /// The counterpart account (for simple transfers).
  var toAccountId: UUID? {
    get { counterpartLeg?.accountId }
    set {
      if let idx = counterpartLegIndex {
        legDrafts[idx].accountId = newValue
      }
    }
  }

  /// Category on the primary leg (index 0).
  var categoryId: UUID? {
    get { legDrafts[0].categoryId }
    set { legDrafts[0].categoryId = newValue }
  }

  /// Category text on the primary leg (index 0).
  var categoryText: String {
    get { legDrafts[0].categoryText }
    set { legDrafts[0].categoryText = newValue }
  }

  /// Earmark on the primary leg (index 0).
  var earmarkId: UUID? {
    get { legDrafts[0].earmarkId }
    set { legDrafts[0].earmarkId = newValue }
  }

  /// Reconcile `categoryText` with `categoryId` via
  /// `Categories.normalisedSelection(text:id:)`. Clearing the field to empty
  /// removes the category (the only way to remove one from the leg); a
  /// resolving id rewrites the text to its canonical path; anything else
  /// clears both. Called from the view on category-field blur so
  /// partially-typed text that never committed doesn't linger in the draft.
  mutating func normaliseCategoryText(using categories: Categories) {
    let normalised = categories.normalisedSelection(text: categoryText, id: categoryId)
    categoryText = normalised.text
    categoryId = normalised.id
  }

  /// Per-leg variant of `normaliseCategoryText(using:)`. Reconciles the
  /// leg at `index` so its `categoryText` matches the canonical path of
  /// its `categoryId`, or clears both when the field was cleared to empty
  /// or the id is gone. Called from each leg's category-field blur handler.
  mutating func normaliseLegCategoryText(at index: Int, using categories: Categories) {
    let normalised = categories.normalisedSelection(
      text: legDrafts[index].categoryText, id: legDrafts[index].categoryId)
    legDrafts[index].categoryText = normalised.text
    legDrafts[index].categoryId = normalised.id
  }

  /// Commits the currently-highlighted suggestion to the simple-mode
  /// category, falling back to `normaliseCategoryText(using:)` when no
  /// suggestion is highlighted. Called from the category field's blur
  /// handler so the suggestion the user navigated to with arrow keys is
  /// captured even when they Tab or click out instead of pressing Enter
  /// (#509). Without this, blurring with a highlight pending drops the
  /// suggestion and then clears the typed text because the unmatched
  /// path doesn't resolve to any `categoryId`.
  mutating func commitHighlightedCategoryOrNormalise(
    highlighted: CategorySuggestion?, using categories: Categories
  ) {
    if let highlighted {
      commitCategorySelection(id: highlighted.id, path: highlighted.path)
    } else {
      normaliseCategoryText(using: categories)
    }
  }

  /// Per-leg variant of `commitHighlightedCategoryOrNormalise(...)`. See
  /// that method's note for the motivation.
  mutating func commitHighlightedLegCategoryOrNormalise(
    at index: Int, highlighted: CategorySuggestion?, using categories: Categories
  ) {
    if let highlighted {
      commitLegCategorySelection(at: index, id: highlighted.id, path: highlighted.path)
    } else {
      normaliseLegCategoryText(at: index, using: categories)
    }
  }

  /// Sets the simple-mode category id and display path in a single
  /// mutation. Must be a single mutating method (not two separate
  /// `categoryId = …; categoryText = …` writes through a `@Binding`):
  /// SwiftUI snapshots the source between consecutive binding writes, so
  /// the second write is built from a snapshot taken before the first
  /// landed and clobbers it. With two writes, `categoryId` silently
  /// reverts to nil, then `normaliseCategoryText(using:)` on the next
  /// blur clears the field (#509).
  mutating func commitCategorySelection(id: UUID, path: String) {
    categoryId = id
    categoryText = path
  }

  /// Per-leg variant of `commitCategorySelection(id:path:)`. See that
  /// method's note for why a single mutating call is required.
  mutating func commitLegCategorySelection(at index: Int, id: UUID, path: String) {
    legDrafts[index].categoryId = id
    legDrafts[index].categoryText = path
  }

  /// Whether the "other account" label should read "From Account" instead of "To Account".
  /// True when viewing from the counterpart's perspective (the relevant leg is not the primary leg).
  var showFromAccount: Bool {
    relevantLegIndex != 0
  }

  /// Whether the current draft is a cross-currency transfer: both legs have accounts with different instruments.
  func isCrossCurrencyTransfer(accounts: Accounts) -> Bool {
    guard legDrafts.count == 2, type == .transfer else { return false }
    guard let acctIdA = legDrafts[0].accountId, let acctIdB = legDrafts[1].accountId,
      let accountA = accounts.by(id: acctIdA), let accountB = accounts.by(id: acctIdB)
    else { return false }
    return accountA.instrument != accountB.instrument
  }
}

// MARK: - Editing Methods (Simple Mode)

extension TransactionDraft {
  /// Change the transaction type, adding/removing counterpart legs as needed.
  mutating func setType(_ newType: TransactionType, accounts: Accounts) {
    let wasTransfer = type == .transfer
    let isTransfer = newType == .transfer

    if !wasTransfer && isTransfer {
      // Adding a counterpart leg for transfer
      let currentAccountId = relevantLeg.accountId
      let defaultAccount = accounts.sidebarOrdered(excluding: currentAccountId).first

      // Parse-negate-format the counterpart amount
      let counterpartAmount = negatedAmountText(relevantLeg.amountText)

      let counterpartLeg = LegDraft(
        legId: nil,
        type: .transfer,
        accountId: defaultAccount?.id,
        amountText: counterpartAmount,
        categoryId: nil,
        categoryText: "",
        earmarkId: nil,
        instrument: defaultAccount?.instrument
      )

      legDrafts[relevantLegIndex].type = .transfer
      // Insert counterpart at the other position
      if relevantLegIndex == 0 {
        legDrafts.append(counterpartLeg)
      } else {
        legDrafts.insert(counterpartLeg, at: 0)
      }
    } else if wasTransfer && !isTransfer {
      // Removing counterpart leg
      if let idx = counterpartLegIndex {
        legDrafts.remove(at: idx)
        // Adjust relevantLegIndex if needed
        if relevantLegIndex > idx {
          relevantLegIndex -= 1
        }
      }
      legDrafts[relevantLegIndex].type = newType
    } else {
      // Just changing type on existing legs (expense ↔ income)
      for i in legDrafts.indices {
        legDrafts[i].type = newType
      }
    }
  }

  /// Change the display amount on the relevant leg, mirroring to counterpart for transfers.
  /// When `accounts` is provided and the draft is a cross-currency transfer, the counterpart
  /// amount is left unchanged (independent editing).
  mutating func setAmount(_ text: String, accounts: Accounts? = nil) {
    legDrafts[relevantLegIndex].amountText = text

    // Mirror to counterpart for simple transfers
    if let idx = counterpartLegIndex {
      let isCrossCurrency = accounts.map { isCrossCurrencyTransfer(accounts: $0) } ?? false
      if !isCrossCurrency {
        legDrafts[idx].amountText = negatedAmountText(text)
      }
    }
  }

  /// Set the counterpart leg's display amount directly (for cross-currency transfers).
  mutating func setCounterpartAmount(_ text: String) {
    if let idx = counterpartLegIndex {
      legDrafts[idx].amountText = text
    }
  }

  /// Parse display text, negate, and format. Returns "" if unparseable.
  /// Preserves the decimal precision from the input text.
  func negatedAmountText(_ text: String) -> String {
    // Use a dummy decimals value — we just need to parse and negate
    guard let value = InstrumentAmount.parseQuantity(from: text, decimals: 10) else {
      return ""
    }
    let negated = -value
    if negated == .zero {
      return "0"
    }
    // Preserve the number of decimal places from the input
    let decimalPlaces: Int
    if let dotIndex = text.firstIndex(of: ".") {
      decimalPlaces = text.distance(from: text.index(after: dotIndex), to: text.endIndex)
    } else {
      decimalPlaces = 0
    }
    return negated.formatted(.number.precision(.fractionLength(decimalPlaces)).grouping(.never))
  }
}

// MARK: - Mode Switching

extension TransactionDraft {
  /// Whether the current legs satisfy simple-mode rules, allowing a switch to simple mode.
  /// Cross-currency transfers are allowed (amounts need not negate).
  var canSwitchToSimple: Bool {
    if legDrafts.count <= 1 { return true }
    guard legDrafts.count == 2 else { return false }
    let primary = legDrafts[0]
    let counterpart = legDrafts[1]
    guard primary.type == counterpart.type && primary.type == .transfer else { return false }
    guard counterpart.categoryId == nil && counterpart.earmarkId == nil else { return false }
    guard primary.accountId != nil && counterpart.accountId != nil else { return false }
    guard primary.accountId != counterpart.accountId else { return false }
    return true
  }

  /// Switch from custom to simple mode. Only call when `canSwitchToSimple` is true.
  mutating func switchToSimple() {
    isCustom = false
    repinRelevantLeg()
  }

  /// When switching from cross-currency to same-currency, snap the counterpart amount
  /// to the negated primary amount (resume standard mirroring).
  mutating func snapToSameCurrencyIfNeeded(accounts: Accounts) {
    guard let idx = counterpartLegIndex, !isCrossCurrencyTransfer(accounts: accounts) else {
      return
    }
    legDrafts[idx].amountText = negatedAmountText(legDrafts[relevantLegIndex].amountText)
  }
}
