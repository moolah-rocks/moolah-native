# Moolah UI Style Guide

**Version:** 1.0
**Platform targets:** macOS 26+ (primary), iOS 26+ (secondary)
**Based on:** Apple Human Interface Guidelines (2025)

---

## 1. Design Principles

### macOS-First Philosophy
Moolah is optimized for the desktop experience, where users manage their finances with precision, keyboard efficiency, and high information density. The iOS version inherits these patterns but adapts for touch and portability.

**Core Tenets:**
- **Clarity:** Financial data must be instantly scannable and unambiguous
- **Efficiency:** Minimize clicks/taps for common tasks (add transaction, categorize, filter)
- **Precision:** Support keyboard navigation, drag & drop, and pointer-based workflows
- **Trustworthiness:** Use conservative, professional design; avoid playful or frivolous UI

### Adaptive Data Density
- **macOS/iPadOS:** Compact lists, smaller text, maximize visible transactions (10–15 per screen)
- **iPhone:** Comfortable spacing, larger touch targets, prioritize readability (5–8 per screen)
- Use SwiftUI's `@Environment(\.horizontalSizeClass)` and `@Environment(\.verticalSizeClass)` to adapt

---

## 2. Brand Identity

Moolah has a brand guide at `guides/BRAND_GUIDE.md` that defines voice, tone, color palette, typography, logo usage, and approved marketing copy. When making UI decisions:

- **Apple HIG is primary.** This is a native Mac/iOS app. It must look and feel like a first-class citizen of the platform. SF Pro for all UI text, system colors for semantic meaning, standard controls and navigation patterns. Never sacrifice native feel for brand expression.
- **The brand guide is supplementary.** Reference it for: language and tone in user-facing strings (empty states, onboarding, error messages), the income-blue/expense-red/balance-gold color story when choosing accent treatments, and understanding the product's personality ("Solid money. Chill vibes.").
- **Where they conflict, HIG wins.** For example: the brand guide specifies Poppins as the brand typeface, but the app uses SF Pro because that's the system font. The brand palette defines specific hex colors, but the app uses semantic system colors (`.green`, `.red`, `.secondary`) for automatic dark mode adaptation.

See `guides/BRAND_GUIDE.md` for the full brand reference.

---

## 3. Layout & Navigation

### Navigation Structure
```
NavigationSplitView (macOS/iPad) or NavigationStack (iPhone)
├─ Sidebar (200–250pt)
│  ├─ Accounts section
│  ├─ Earmarks section
│  └─ Navigation items (All Transactions, Upcoming, Categories)
├─ Content (flexible width)
│  └─ Transaction lists, account views, analysis dashboard
└─ Inspector (trailing sidebar via .inspector(), shown on selection)
   └─ Forms, transaction details, category editing
```

**Sidebar (macOS/iPad):**
- Use `.navigationSplitViewStyle(.balanced)` to allow resizing
- Show section headers with SF Symbols (e.g., `"dollarsign.circle"` for Accounts)
- Use `List` with `.listStyle(.sidebar)` for native appearance
- Add toolbar buttons for user menu (top) and global actions

**Primary List:**
- Use `List` with `.listStyle(.inset)` on macOS for bordered appearance
- Use `.listStyle(.plain)` on iOS for full-width rows
- Always provide `.refreshable` for pull-to-refresh (iOS) or Cmd+R (macOS)
- Support `.searchable()` for filtering lists

**Detail Panel (Inspector):**
- macOS: Use `.inspector()` modifier — shown as a trailing sidebar at the window level
- iOS: Use `.sheet()` presentation wrapped in `NavigationStack`
- Must be attached at the outermost view level (see Detail Panels section below)
- Use `Form` for editing, `VStack` for read-only details

### Spacing & Sizing

| Element | macOS | iPad | iPhone |
|---------|-------|------|--------|
| List row height | 44–52pt | 52–60pt | 60–68pt |
| Inspector width | System default (~350pt) | System default | Full screen (sheet) |
| Sidebar width | 220pt | 220pt | N/A |
| Form section spacing | 16pt | 20pt | 24pt |
| Inline padding | 12pt | 16pt | 20pt |
| Sheet content padding (custom content) | 24pt | 20pt | 20pt |
| Sheet content padding (Form) | System (do not override) | System | System |
| Popover content padding | 16pt | 16pt | 16pt |
| Sheet minimum frame (macOS) | 400×300pt (simple) / 500×400pt (multi-section) | — | — |

See [Sheets & Dialogs](#sheets--dialogs) in Section 6 for full guidance on sheet padding, sizing, and button placement.

### View-tree stability for views with `.searchable` / `.toolbar`

The detail column wraps every leaf in `NavigationStack { … }.id(selection)`
(see `App/ContentView.swift`). The `.id(selection)` is load-bearing: it
forces SwiftUI to fully tear down the previous leaf's `NavigationStack`
(and its `NSToolbar` host) before mounting the next leaf. Two `NSToolbar`s
never coexist, so the AppKit toolbar bridge cannot double-register
`com.apple.SwiftUI.search`.

Two prior incidents drove this design — `InvestmentAccountView` flipping
between `legacyValuationsLayout` and `positionTrackedLayout` after `.task`
resolved (commit `010fb55b`), and the crypto-account `accountDetail`
wrapping the wallet header + `TransactionListView` in a `VStack` whose
first child appeared/disappeared with `account.type == .crypto` (PR #821,
commit `08a99a2d`). Both fired the same
`NSInternalInconsistencyException: NSToolbar already contains an item
with the identifier com.apple.SwiftUI.search` assertion. The structural
fix eliminates the failure mode at its source rather than patching each
new instance.

**Searchable invariant (two-part rule, exhaustive):**

1. Any leaf that contains a `TransactionListView` (e.g.,
   `StandardAccountView`, `CryptoWalletAccountView`, `AllTransactionsView`,
   `EarmarkDetailView`, `InvestmentAccountView`, `UpcomingView`) registers
   exactly one `.searchable(text:)`, and it lives inside
   `TransactionListView`. No other code in such a leaf may register
   `.searchable`.
2. Any leaf that does NOT contain a `TransactionListView` (e.g.,
   `CategoriesView`) may register at most one `.searchable(text:)` directly
   on its own root view. Two `.searchable` modifiers in the same leaf are
   forbidden regardless of leaf type.

**Toolbar accumulation:** `TransactionListView` owns the standard
transaction-list toolbar items (filter / refresh / add). Leaves that need
additional toolbar items add them via a sibling `.toolbar { … }` modifier
on the leaf's body — SwiftUI accumulates these into the leaf's single
`NSToolbar` because there is exactly one `NavigationStack` per leaf. There
is no `extraToolbar:` parameter on `TransactionListView`.

**Inspector placement:** the `.transactionInspector(...)` modifier
attaches at the leaf's body level — i.e., inside the per-leaf
`NavigationStack`, on the outermost view of the leaf's content. SwiftUI
hoists the inspector to the window level for rendering, so the placement
does not affect layout, but keeping the modifier at the leaf level scopes
the inspector's binding to the leaf's `@State selectedTransaction`. Do
not move it up to the `ContentView.detail` level.

**Composition shells** (`PositionsTransactionsSplit`, and after PR-3 /
PR-2: `RecordedValueInvestmentLayout`, `EarmarkOverviewWithTabs`) are
content-only: they do not register `.toolbar` or `.searchable`.

The `code-review` and `ui-review` agents flag any new view that violates
the searchable invariant. Treat agent findings on this rule as Critical.

---

## 4. Typography

### Font Hierarchy
Use **SF Pro** (system default) for all text. **Never** override with custom fonts for financial data.

| Style | Usage | macOS | iOS |
|-------|-------|-------|-----|
| **Large Title** | Screen titles (navigation bar) | `.font(.largeTitle)` 26pt | `.font(.largeTitle)` 34pt |
| **Title** | Section headers | `.font(.title)` 22pt | `.font(.title)` 28pt |
| **Headline** | List row primary text | `.font(.headline)` 14pt semibold | `.font(.headline)` 17pt semibold |
| **Body** | List row secondary text | `.font(.body)` 13pt | `.font(.body)` 17pt |
| **Subheadline** | Metadata (dates, notes) | `.font(.subheadline)` 11pt | `.font(.subheadline)` 15pt |
| **Caption** | Auxiliary info | `.font(.caption)` 10pt | `.font(.caption)` 12pt |

**Monospaced Digits:**
- Always use `.monospacedDigit()` for amounts, balances, and dates to prevent layout jitter
- Example: `Text("$1,234.56").monospacedDigit()`

**Dynamic Type:**
- Respect user's text size preferences via `.dynamicTypeSize(.medium...(.accessibility3))`
- Test layouts at largest accessibility sizes to ensure no clipping

---

## 5. Color & Theming

### Semantic Color System
Moolah uses semantic colors to communicate financial meaning at a glance.

#### Transaction Amount Colors
```swift
// Current implementation in InstrumentAmountView.swift
.foregroundStyle(amount.isPositive ? .green : amount.isNegative ? .red : .primary)
```

| Amount | Color | Usage |
|--------|-------|-------|
| Positive (income, inflows) | `.green` | System green (adaptive to light/dark mode) |
| Negative (expenses, outflows) | `.red` | System red |
| Zero | `.primary` | Standard text color |
| Balances (neutral) | `.secondary` | Use `colorOverride: .secondary` |

#### Expense Amount Display Convention
Expenses are stored internally as **negative quantities** (they reduce the account balance). However, when displaying expense totals to the user (e.g., in category breakdowns, analysis summaries), **negate them to positive** values. Users expect "an expense of $20" — not "$-20". A negative expense (e.g., a refund) should display as a negative value.

```swift
// Server returns a -50.00 quantity for a $50 expense
// Display as: $50.00 (positive)
let displayAmount = InstrumentAmount(
  quantity: max(0, -serverAmount.quantity),
  instrument: serverAmount.instrument)
```

This matches the web app's `Math.max(0, -totalExpenses)` pattern. This convention applies to both aggregated expense summaries **and** expense amount fields in forms/editors — users enter and see positive values (e.g., "$50"), and the sign is applied internally based on transaction type. Transaction lists that show the raw signed amount (with income positive and expenses negative) are the exception.

**Do:**
- Use system colors (`.green`, `.red`) for automatic dark mode adaptation
- Reserve `.green` and `.red` exclusively for amounts; don't use for buttons or accents
- Use `.secondary` for muted text (e.g., running balances, notes)

**Don't:**
- Mix custom RGB values with semantic colors (one documented exception: see `Selected-Row Contrast Override (Exception)` below)
- Use color alone to convey information (always pair with text/icons for accessibility)

#### Selected-Row Contrast Override (Exception)
When an amount is rendered on a row whose selection background is prominent (the focused sidebar's blue selection highlight), the standard `.green` / `.red` system colours read as muddy and lose legibility. Verified visually on light and dark mode in Xcode previews; system colours `.mint` and `.pink` were also tried and rejected — both are too desaturated against the saturated blue.

In this **specific** context, override with hand-tuned bright values:

```swift
private static let selectedPositiveColor = Color(red: 0.55, green: 1.0, blue: 0.65)
private static let selectedNegativeColor = Color(red: 1.0, green: 0.6, blue: 0.6)
```

These literals are the **only** place in the app where hardcoded RGB values are permitted.

Apply the override only when both:

1. The row is selected (`isSelected == true`), and
2. The selection background is prominent (`backgroundProminence == .increased`). When the sidebar is unfocused the background is grey and the standard `.green` / `.red` are more readable — fall back to those.

`Color(red:green:blue:)` uses sRGB and does **not** adapt between light and dark appearances. The chosen values are intentionally bright (HSL lightness > 0.80) so they read well against the focused-sidebar blue in both modes without needing appearance variants. Tuned against the macOS 26 sidebar selection palette; re-verify visually if Apple revises the focused-sidebar selection colour in a future macOS release.

The reference implementation is `SidebarRowView.amountColorOverride` in `Features/Accounts/Views/AccountSidebarRow.swift`. Any new override site must follow the same two-condition gate.

#### Accent Color
- **macOS:** Default blue (`.accentColor(.blue)`) for buttons, links, selection
- **iOS:** Use default tint color (`.tint(.blue)`)
- Apply globally in `MoolahApp.swift` via `.tint(.blue)`

#### Background Colors
| Element | Light Mode | Dark Mode |
|---------|-----------|-----------|
| Primary background | `.background` | `.background` |
| Secondary background (forms) | `.secondaryGroupedBackground` | `.secondaryGroupedBackground` |
| Elevated surfaces (popovers) | `.regularMaterial` | `.regularMaterial` |

### Dark Mode
- **Always test in dark mode** via Xcode preview or system settings
- Use system colors exclusively to ensure proper adaptation (the one permitted exception is documented in `Selected-Row Contrast Override (Exception)` above)
- Avoid pure black (`#000000`) or pure white (`#FFFFFF`); use `.primary` / `.background`

---

## 6. Components & Patterns

### Lists

#### Transaction Row
**Layout:**
```
┌─────────────────────────────────────────────────┐
│ [Icon] Payee Name              $-1,234.56       │
│        Category • Date         Balance: $4,567  │ (optional)
└─────────────────────────────────────────────────┘
```

**Implementation guidelines:**
```swift
HStack(alignment: .firstTextBaseline, spacing: 12) {
  // Icon (24×24pt)
  Image(systemName: transactionIcon)
    .frame(width: 24, height: 24)
    .foregroundStyle(.secondary)

  VStack(alignment: .leading, spacing: 4) {
    Text(payee)
      .font(.headline)
    HStack(spacing: 4) {
      Text(category)
      Text("•")
      Text(date, format: .dateTime.month(.abbreviated).day())
    }
    .font(.subheadline)
    .foregroundStyle(.secondary)
  }

  Spacer()

  VStack(alignment: .trailing, spacing: 4) {
    InstrumentAmountView(amount: amount, font: .body)
    if let balance = balance {
      InstrumentAmountView(amount: balance, colorOverride: .secondary, font: .caption)
    }
  }
}
.padding(.vertical, 8) // macOS: 8pt, iOS: 12pt via @Environment
```

**Swipe Actions (iOS):**
```swift
.swipeActions(edge: .trailing) {
  Button(role: .destructive) {
    deleteTransaction()
  } label: {
    Label("Delete", systemImage: "trash")
  }
}
```

**Context Menu (macOS):**
```swift
.contextMenu {
  Button("Edit", systemImage: "pencil") { editTransaction() }
  Button("Duplicate", systemImage: "doc.on.doc") { duplicateTransaction() }
  Divider()
  Button("Delete", systemImage: "trash", role: .destructive) { deleteTransaction() }
}
```

#### Empty States
Use `ContentUnavailableView` for empty lists. Because macOS users click and iOS
users tap, build the prompt with `PlatformActionVerb.emptyStatePrompt(_:_:)` so
the verb matches the platform (never hardcode "Tap" or "Click"):
```swift
ContentUnavailableView(
  "No Transactions",
  systemImage: "tray",
  description: Text(
    PlatformActionVerb.emptyStatePrompt(buttonLabel: "+", suffix: "to add your first transaction")
  )
)
```

**Icons:** Use SF Symbols that match the domain:
- Transactions: `"tray"`, `"arrow.left.arrow.right"`
- Accounts: `"banknote"`, `"creditcard"`
- Categories: `"folder"`, `"tag"`

### Forms

#### Transaction Detail Form
```swift
Form {
  Section("Details") {
    Picker("Type", selection: $type) {
      Text("Income").tag(TransactionType.income)
      Text("Expense").tag(TransactionType.expense)
      Text("Transfer").tag(TransactionType.transfer)
    }

    TextField("Payee", text: $payee)
      .textFieldStyle(.roundedBorder) // macOS only

    DatePicker("Date", selection: $date, displayedComponents: .date)
  }

  Section("Amount") {
    // Custom amount entry view
    AmountTextField(cents: $cents)
  }
}
.formStyle(.grouped) // iOS: grouped inset, macOS: bordered sections
```

**Date fields — keep the default stepper style.** Leave `DatePicker` bare in a Form; on macOS it renders as a numeric field with up/down stepper arrows. Don't "modernise" it with `.datePickerStyle(.compact)`, a custom button + calendar popover, or a wrapped `NSDatePicker`. The arrow keys adjusting the focused date component (day/month/year) are a deliberate keyboard affordance the other styles lose, and `.compact` looks near-identical in a Form anyway. Only change the style if the user explicitly asks.

**Field Validation:**
- Show validation errors inline below fields using `.foregroundStyle(.red)` text
- Use `.disabled(true)` on save button until form is valid
- Provide immediate feedback (not just on submit)

**Form Section Order:**
Follow this standard order for transaction forms:
1. Type selection (if applicable)
2. Details (payee, amount, date)
3. Accounts
4. Categories/Earmarks
5. Recurrence (scheduled transactions)
6. Notes
7. Destructive actions (delete)

**Multi-line Text Input:**
- Use `TextField(axis: .vertical)` with `.lineLimit(3...6)` for short notes
- Use `TextEditor` with `.frame(height:)` for longer content (>6 lines)
- Always set bounds to prevent layout issues

#### Placeholder Text (`prompt:`)

Placeholder text inside an empty input field is a **hint about the expected content**, not a label substitute and not a default value. The first arg of `TextField(_:text:)` is already the leading row label in a grouped Form on macOS; the `prompt:` parameter is the placeholder shown in the input area when the field is empty.

**The rule:** the placeholder must clearly read as guidance, never as data the user can submit. If the field is empty and the placeholder looks like a value, users will mistake it for a pre-filled default and not understand why the submit button is still disabled.

**Decision tree:**
1. **Row already labelled and the input type is obvious** → no placeholder. (`TextField("Name", text: $name)` is fine on its own; Apple's own forms do this for most fields.)
2. **Placeholder adds genuinely new information** → use it, phrased as a clear hint:
   - **Example:** `prompt: Text("e.g. Everyday")` — the `e.g.` framing is unambiguous.
   - **Format:** `prompt: Text("yyyy-mm-dd")` for an unformatted text date.
   - **Type:** `prompt: Text("Required")` when the empty state needs flagging.
3. **There is a sensible default the form would accept** → pre-fill the field with that default and select it (`TextSelection`), so the user can type to overwrite. **Don't put it in `prompt:`.**

```swift
// ✅ Hint — clearly an example
TextField("Name", text: $name, prompt: Text("e.g. Everyday"))

// ✅ No placeholder — label is sufficient
TextField("Name", text: $name)

// ❌ Looks like a default the form would accept
TextField("Name", text: $name, prompt: Text("New Account"))

// ❌ Placeholder used as the only label (disappears on focus, hurts a11y)
TextField("", text: $name, prompt: Text("Name"))
```

**Sources:** [Apple HIG — Text fields](https://developer.apple.com/design/human-interface-guidelines/text-fields), Nielsen Norman Group's [Placeholders in Form Fields Are Harmful](https://www.nngroup.com/articles/form-design-placeholders/).

#### Custom Transaction Form

When a profile supports custom (multi-leg) transactions, the form uses a different section order to accommodate sub-transaction sections:

1. Type (picker label: "Custom"; displays `"arrow.trianglehead.branch"` icon in `.purple`)
2. Details (payee, date)
3. Sub-transaction sections (one section per leg; header/button labels use "Sub-transaction")
4. Recurrence
5. Notes
6. Pay (for scheduled transactions)
7. Delete (destructive)

**Terminology conventions:**
- Use "Custom" as the type picker label shown to users
- Use "Sub-transaction" for section headers and add/remove button labels shown to users
- Use `leg` / `legs` in code (model types, variable names, function parameters)

### Scheduled Transactions

#### Recurrence UI Pattern
Use a Toggle + conditional fields for recurrence settings:
```swift
Section("Recurrence") {
  Toggle("Repeat", isOn: $isRepeating)

  if isRepeating {
    HStack {
      Text("Every")
      Spacer()
      TextField("", value: $recurEvery, format: .number)
        .keyboardType(.numberPad)
        .multilineTextAlignment(.trailing)
        .frame(minWidth: 40, idealWidth: 60, maxWidth: 80)
        .accessibilityLabel("Recurrence interval")
    }

    Picker("Period", selection: $recurPeriod) {
      Text("Days").tag(RecurPeriod.day)
      Text("Weeks").tag(RecurPeriod.week)
      Text("Months").tag(RecurPeriod.month)
      Text("Years").tag(RecurPeriod.year)
    }
    .accessibilityLabel("Recurrence period")
  }
}
```

**Validation:**
- Both period and frequency must be set when repeat is enabled
- Frequency must be ≥ 1
- Disable save button if incomplete

#### Upcoming Transactions Display
Structure upcoming lists with "Overdue" and "Upcoming" sections:
```swift
List {
  Section("Overdue") {
    ForEach(overdueTransactions) { transaction in
      UpcomingRow(transaction: transaction, isOverdue: true)
    }
  }

  Section("Upcoming") {
    ForEach(upcomingTransactions) { transaction in
      UpcomingRow(transaction: transaction, isOverdue: false)
    }
  }
}
```

**Overdue Visual Treatment:**
- ⚠️ Use **icon + color** to indicate overdue (not color alone)
- Red text + exclamation triangle icon
- Add `.accessibilityLabel("Overdue")` to icon

```swift
HStack(spacing: 4) {
  if isOverdue {
    Image(systemName: "exclamationmark.triangle.fill")
      .foregroundStyle(.red)
      .imageScale(.small)
      .accessibilityLabel("Overdue")
  }
  Text(transaction.payee)
    .foregroundStyle(isOverdue ? .red : .primary)
}
```

**Recurrence Description:**
Display in caption text with accessibility label:
```swift
Text("Every 2 weeks")
  .font(.caption)
  .foregroundStyle(.secondary)
  .accessibilityLabel("Repeats every 2 weeks")
```

**Pay Action:**
- iOS: Use `.buttonStyle(.borderedProminent)` for primary action
- macOS: Use `.buttonStyle(.bordered)` to match platform conventions
- Include accessibility label with payee name

### Buttons & Actions

#### Primary Actions
```swift
// iOS: Use .buttonStyle(.borderedProminent)
Button("Add Transaction") { ... }
  .buttonStyle(.borderedProminent)
  .controlSize(.large)

// macOS: Use default .bordered style, rely on accent color
Button("Save") { ... }
  .buttonStyle(.bordered)
  .keyboardShortcut(.return, modifiers: .command)
```

#### Destructive Actions
```swift
Button("Delete Account", role: .destructive) { ... }
  .buttonStyle(.bordered)
```

#### Toolbar Buttons
```swift
.toolbar {
  ToolbarItem(placement: .primaryAction) {
    Button { createTransaction() } label: {
      Label("Add Transaction", systemImage: "plus")
    }
  }
}
```

**macOS:**
- Use `Label` with `.labelStyle(.iconOnly)` for compact toolbar
- Add keyboard shortcuts via `.keyboardShortcut(.defaultAction)`

**iOS:**
- Use `Label` with `.labelStyle(.titleAndIcon)` in sheets/modals
- Prefer SF Symbols in toolbar for space efficiency

### Sheets & Dialogs

Sheets (`.sheet`, `.fullScreenCover`, `.popover`) and dialogs must keep content visually inset from the sheet edges. Apple's HIG — and every well-built Mac/iOS app — uses generous margins around dialog content. Text or controls that run flush to the sheet edges look broken and make a sheet feel unfinished. This applies on both macOS (where sheets are floating panels over the parent window) and iOS (where they slide up from the bottom).

**The rule:** every sheet needs visible breathing room between its content and the sheet's outer chrome. Choose the right technique for the content type below — do not hand-roll padding when a system style already provides it.

#### Padding by content type

| Content inside the sheet | macOS | iOS | How to achieve it |
|---|---|---|---|
| `Form` with `.formStyle(.grouped)` | ✅ Automatic | ✅ Automatic | Use this for **all editing sheets**. The grouped form style provides the correct outer margins and inter-section spacing on both platforms. |
| Custom `VStack` / `ScrollView` / flow UI | 24pt all sides | 20pt horizontal, 24pt vertical | Apply `.padding(.horizontal, 20).padding(.vertical, 24)` on macOS and platform-match on iOS, or use `.padding(24)` / `.padding(20)` when uniform. |
| `.popover` custom content | 16pt all sides | 16pt all sides | `.padding(16)` on the popover's root view. |
| `.alert` / `.confirmationDialog` | ✅ System-controlled | ✅ System-controlled | Never add padding — the system lays out title, message, and buttons. |

`Form` is the correct primitive for any sheet that edits data (create/edit earmark, account, category, transaction, token). It gets the correct outer margin, section grouping, and focus handling for free on both platforms. **Reach for `VStack` only when the sheet is presenting status, progress, or a wizard-style flow** (e.g., migration, onboarding) where a form is the wrong metaphor.

#### Sheet sizing (macOS)

macOS sheets shrink to fit their content by default, which produces cramped, awkward dialogs. Always set a minimum frame on the sheet's root view:

| Sheet purpose | Minimum size |
|---|---|
| Simple edit form (1–2 fields) | `.frame(minWidth: 400, minHeight: 300)` |
| Multi-section form | `.frame(minWidth: 500, minHeight: 400)` |
| Status / progress / confirmation with detail | `.frame(minWidth: 420, minHeight: 280)` |
| Wizard or multi-step flow | `.frame(minWidth: 520, minHeight: 420)` |

Wrap the frame modifier in `#if os(macOS)` when iOS should remain fullscreen-style.

#### Button placement

- **macOS:** Cancel / confirm buttons live in the toolbar via `.cancellationAction` and `.confirmationAction` placements. Do not place them in the sheet body.
- **iOS:** Same pattern — `NavigationStack` + toolbar buttons. A `Done` or `Save` confirmation button goes on the trailing side.
- **Status/wizard sheets** (no Form) may use inline buttons at the bottom with `.controlSize(.large)` and `.buttonStyle(.borderedProminent)` for the primary action. Pair with `.padding()` and a `HStack(spacing: 12)` when showing multiple choices.

#### Examples

Correct — `Form` gets system padding automatically:
```swift
NavigationStack {
  Form {
    Section("Details") {
      TextField("Name", text: $name)
    }
  }
  .formStyle(.grouped)
  .navigationTitle("Edit Category")
  .toolbar { /* Cancel / Save */ }
}
#if os(macOS)
.frame(minWidth: 400, minHeight: 300)
#endif
```

Correct — custom content with explicit padding and minimum frame:
```swift
VStack(spacing: 16) {
  Image(systemName: "checkmark.circle.fill")
  Text("Migration Complete").font(.title)
  // ...
}
.padding(24)
#if os(macOS)
.frame(minWidth: 420, minHeight: 300)
#endif
```

Wrong — plain content with no padding:
```swift
// Text and buttons touch the sheet edges
VStack {
  Text("Warning")
  Button("Confirm") { ... }
}
```

Wrong — hand-rolling padding around a `Form` (the form already provides it, producing doubled margins):
```swift
Form { ... }
  .padding(20)   // ❌ Don't — duplicates system padding
```

#### Anti-patterns

- ❌ Plain `VStack` / `ScrollView` / `List` in a `.sheet` with no outer padding
- ❌ Adding `.padding()` to a `Form` — system padding already applies; this produces doubled margins
- ❌ Applying padding to `.alert` or `.confirmationDialog` — the system owns their layout
- ❌ Missing `.frame(minWidth:minHeight:)` on macOS sheets (produces a too-small panel)
- ❌ Placing Cancel/Save buttons inside the sheet body instead of the toolbar (Form sheets only)
- ❌ Mixing padding values across similar sheets (e.g., `.padding(16)` in one, `.padding(32)` in another) — pick `20`/`24` and stay consistent

### Detail Panels (Inspector Pattern)

Detail panels (transaction detail, category detail) use SwiftUI's `.inspector()` modifier on macOS and `.sheet()` on iOS. The inspector appears as a trailing sidebar at the window level.

**Critical rule:** The `.inspector()` or `.sheet()` must be attached to the **outermost view that fills the NavigationSplitView detail column** — never to a view nested inside a card, tab, or scroll view. If the inspector is attached too deep in the hierarchy, it will be constrained to that subview's bounds instead of spanning the full window height.

**Use `TransactionInspectorModifier`** (via `.transactionInspector()`) for transaction detail panels. It handles both platforms and includes a toolbar close button on macOS.

**When a view embeds `TransactionListView`** (e.g., `EarmarkDetailView`, `InvestmentAccountView`), the parent must:
1. Own the `@State var selectedTransaction: Transaction?`
2. Pass a binding to `TransactionListView` via the `selectedTransaction:` parameter
3. Attach `.transactionInspector()` at its own level

```swift
// Parent view that embeds TransactionListView
struct EarmarkDetailView: View {
  @State private var selectedTransaction: Transaction?

  var body: some View {
    VStack {
      overviewPanel
      TransactionListView(
        title: ..., filter: ..., accounts: ...,
        categories: ..., earmarks: ...,
        transactionStore: ...,
        selectedTransaction: $selectedTransaction  // pass binding
      )
    }
    .transactionInspector(                         // attach at parent level
      selectedTransaction: $selectedTransaction,
      accounts: accounts, categories: categories,
      earmarks: earmarks, transactionStore: transactionStore
    )
  }
}
```

**When `TransactionListView` is the direct detail content** (e.g., in `ContentView`), omit the `selectedTransaction:` parameter — it manages its own state and inspector internally.

**Toolbar close button:** The `TransactionInspectorModifier` automatically adds a `sidebar.trailing` toolbar button on macOS to dismiss the inspector. For non-transaction inspectors (e.g., category detail), add the button manually:
```swift
.toolbar {
  ToolbarItem(placement: .automatic) {
    if selectedCategory != nil {
      Button { selectedCategory = nil } label: {
        Label("Hide Details", systemImage: "sidebar.trailing")
      }
      .help("Hide Details")
    }
  }
}
```

**iOS behavior:** On iOS, detail panels always use `.sheet(item:)` wrapped in a `NavigationStack` with a "Done" toolbar button.

---

## 7. Data Visualization (Charts)

### Swift Charts Integration
Use **Swift Charts** for spending trends, budget progress, and balance history.

#### Spending Over Time (Line Chart)
```swift
import Charts

Chart(transactions) { transaction in
  LineMark(
    x: .value("Date", transaction.date),
    y: .value("Amount", transaction.amount.decimalValue)
  )
  .foregroundStyle(.green)
}
.chartXAxis {
  AxisMarks(values: .stride(by: .day, count: 7))
}
.chartYAxis {
  AxisMarks(format: .currency(code: "AUD"))
}
.frame(height: 200)
```

#### Category Spending (Bar Chart)
```swift
Chart(categoryTotals) { category in
  BarMark(
    x: .value("Amount", category.total.decimalValue),
    y: .value("Category", category.name)
  )
  .foregroundStyle(by: .value("Category", category.name))
}
.chartLegend(.hidden) // Categories are on Y-axis
```

#### Budget Progress (Gauge)
```swift
Gauge(value: spent, in: 0...budgeted) {
  Text(category.name)
} currentValueLabel: {
  InstrumentAmountView(amount: spentAmount, font: .body)
} minimumValueLabel: {
  Text("$0")
} maximumValueLabel: {
  InstrumentAmountView(amount: budgetedAmount, font: .caption)
}
.gaugeStyle(.accessoryCircularCapacity)
.tint(spent > budgeted ? .red : .green)
```

**Chart Guidelines:**
- Keep charts **simple**; avoid 3D, gradients, or excessive decoration
- Use **monochrome** or semantic colors (green/red for gains/losses)
- Provide **context:** always label axes, show units, include legends if multi-series
- Test with **zero data** and **extreme values** (e.g., $0, negative balances)

---

## 8. Iconography

### SF Symbols Usage
Moolah uses SF Symbols 6 for all icons. **Never** use custom bitmap icons.

#### Standard Icons
| Concept | Symbol | Example Usage |
|---------|--------|---------------|
| Transaction | `"arrow.left.arrow.right"` | Generic transaction icon |
| Income | `"arrow.up"` | Positive flow (money in) |
| Expense | `"arrow.down"` | Negative flow (money out) |
| Transfer | `"arrow.left.arrow.right"` | Between accounts |
| Custom | `"arrow.trianglehead.branch"` | Multi-leg transactions with mixed types |
| Account | `"creditcard"`, `"banknote"` | Bank accounts, cash |
| Category | `"tag"`, `"folder"` | Transaction categories |
| Earmark/Budget | `"bookmark.fill"` | Earmark allocations and savings goals |
| Calendar | `"calendar"` | Scheduled transactions |
| Search | `"magnifyingglass"` | Search/filter |
| Add | `"plus"` | Create new item |
| Edit | `"pencil"` | Edit existing |
| Delete | `"trash"` | Remove item |
| Settings | `"gearshape"` | User preferences |

#### Transaction Type Icon Colors

| Type | Color | Notes |
|------|-------|-------|
| Income | `.green` | Positive flow |
| Expense | `.red` | Negative flow |
| Transfer | `.blue` | Between accounts |
| Opening Balance | `.orange` | System-generated |
| Custom | `.purple` | Multi-leg transactions with mixed types |

#### Rendering Modes
```swift
// Monochrome (default, use semantic colors)
Image(systemName: "arrow.up")
  .foregroundStyle(.green)

// Hierarchical (automatic depth via opacity)
Image(systemName: "creditcard")
  .symbolRenderingMode(.hierarchical)

// Palette (multi-color, use sparingly)
Image(systemName: "chart.pie.fill")
  .symbolRenderingMode(.palette)
  .foregroundStyle(.blue, .green, .red)
```

**Sizing:**
- List icons: 20×20pt (macOS), 24×24pt (iOS)
- Toolbar icons: 16×16pt (macOS), 22×22pt (iOS)
- Empty state icons: 64×64pt (all platforms)

---

## 9. Accessibility

### VoiceOver Support
- Always provide `.accessibilityLabel()` for images and custom controls
- Use `.accessibilityValue()` for amounts: `"One thousand two hundred thirty-four dollars and fifty-six cents"`
- Group related elements with `.accessibilityElement(children: .combine)`

**Example:**
```swift
HStack {
  Text(transaction.payee)
  Spacer()
  InstrumentAmountView(amount: transaction.amount)
}
.accessibilityElement(children: .combine)
.accessibilityLabel("\(transaction.payee), \(transaction.amount.decimalValue.formatted(.currency(code: transaction.amount.currency.code)))")
```

### Keyboard Navigation (macOS)

See **Section 13: Focus, Tab Order & Selection** for focus management, tab order, and list selection patterns.

See **Section 14: Menu Bar & Commands (macOS)** for the full keyboard shortcut inventory and the rules for keeping menu bar, toolbar, and context menus coherent.

### Color Contrast
- Ensure **4.5:1** contrast ratio for body text (13pt+)
- Ensure **3:1** contrast ratio for large text (18pt+)
- Test with **Increase Contrast** enabled in Accessibility settings
- Use system colors to automatically meet WCAG AA standards

### Reduce Motion
- Disable decorative animations when `.accessibilityReduceMotion` is enabled
- Keep essential animations (e.g., loading spinners)

```swift
@Environment(\.accessibilityReduceMotion) var reduceMotion

var animation: Animation? {
  reduceMotion ? nil : .easeInOut
}
```

---

## 10. Implementation Checklist

### Before Building a New Screen
- [ ] Choose the appropriate navigation pattern (split view vs. stack)
- [ ] Define the empty state (`ContentUnavailableView`)
- [ ] Plan keyboard shortcuts (macOS)
- [ ] Identify swipe actions (iOS) and context menus (macOS)
- [ ] Design for both size classes (compact/regular)

### During Development
- [ ] Use semantic colors (`.green`, `.red`, `.secondary`)
- [ ] Apply `.monospacedDigit()` to all amounts
- [ ] Add `.refreshable` for pull-to-refresh
- [ ] Implement `.searchable()` if list is filterable
- [ ] Test with Dynamic Type at largest size
- [ ] Test in dark mode

### Before Shipping
- [ ] Run with VoiceOver enabled (at least one screen)
- [ ] Verify keyboard navigation (macOS)
- [ ] Test with Increase Contrast enabled
- [ ] Check color contrast ratios (use Xcode Accessibility Inspector)
- [ ] Validate forms prevent submission of invalid data
- [ ] Test with slow network (loading states, errors)

---

## 11. Anti-Patterns (Avoid These)

### Layout
- ❌ Fixed pixel widths on text elements (breaks Dynamic Type)
- ❌ Hardcoded colors (e.g., `Color(red: 0.2, green: 0.8, blue: 0.3)`)
- ❌ Using `GeometryReader` for spacing (prefer `Spacer()`, `padding()`)
- ❌ Over-nesting `VStack`/`HStack` (flatten where possible)
- ❌ Sheet content flush to the sheet edges — use `Form` or `.padding(24)` on macOS / `.padding(20)` on iOS (see Sheets & Dialogs)
- ❌ macOS sheets without a minimum `.frame(minWidth:minHeight:)` — they collapse to unreadable panels
- ❌ Wrapping a `.searchable` / `.toolbar`-bearing view in a structurally-flipping parent (e.g. `VStack` whose first child is gated by `if`). Crashes AppKit's toolbar bridge with a duplicate `com.apple.SwiftUI.search` item; use the host view's accessory slot or `.safeAreaInset(edge:)` instead. See [§3 — view-tree stability for views with toolbars](#view-tree-stability-for-views-with-searchable--toolbar).

### Typography
- ❌ Custom fonts for amounts (always use SF Pro with `.monospacedDigit()`)
- ❌ Setting explicit `.frame(height:)` on text (causes clipping)
- ❌ ALL CAPS TEXT (use `.textCase(.uppercase)` if required by HIG)

### Interaction
- ❌ Buttons without clear labels (icon-only without `.accessibilityLabel`)
- ❌ Destructive actions without confirmation dialogs
- ❌ Touch targets smaller than 44×44pt (iOS)
- ❌ Relying solely on color to communicate state (add icons/text)

### Data Display
- ❌ Showing raw cents values (e.g., "5023¢") — always format as currency
- ❌ Truncating amounts with `...` (use `.minimumScaleFactor()` if needed)
- ❌ Inconsistent date formats (use `.formatted(.dateTime.month().day())`)

---

## 12. Resources

- [Apple Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/)
- [SF Symbols App](https://developer.apple.com/sf-symbols/) (browse all symbols)
- [Swift Charts Documentation](https://developer.apple.com/documentation/charts)
- [Accessibility Developer Guide](https://developer.apple.com/accessibility/)
- [Color Contrast Analyzer](https://www.figma.com/community/plugin/733159460536249875) (Figma plugin)

---

## 13. Focus, Tab Order & Selection

> **See also: `guides/FOCUS_GUIDE.md` for the canonical focus rules.** This section gives the Moolah-specific patterns; `FOCUS_GUIDE.md` covers the underlying SwiftUI focus model in depth (focus containers, `@FocusState` semantics, when `defaultFocus` silently no-ops, macOS popover key-window behaviour, the `.buttonStyle(.plain)` activation gap, anti-patterns, and a quick-reference table). Read it before touching any view that uses `@FocusState`, `.focused`, `.focusable`, `.defaultFocus`, `.focusSection`, or `.focusedSceneValue`.

macOS users expect full keyboard-driven workflows. Focus management, tab order, and selection behavior are first-class interaction concerns — not accessibility afterthoughts. This section covers the patterns and rules for making Moolah feel like a native Mac app under the keyboard.

### Form Focus Management

Use a single **optional enum** `@FocusState` per form, with one case per focusable field:

```swift
enum TransactionField: Hashable {
    case payee
    case amount
    case date
    case notes
}

@FocusState private var focusedField: TransactionField?

// Bind each field
TextField("Payee", text: $payee)
    .focused($focusedField, equals: .payee)

AmountTextField(cents: $cents)
    .focused($focusedField, equals: .amount)

DatePicker("Date", selection: $date)
    .focused($focusedField, equals: .date)

TextField("Notes", text: $notes, axis: .vertical)
    .focused($focusedField, equals: .notes)
```

**Rules:**
- One enum per form, one case per focusable field. Never use multiple boolean `@FocusState` properties — they don't compose.
- Set initial focus with `defaultFocus` on the form container (macOS):
  ```swift
  Form { ... }
      .defaultFocus($focusedField, .payee)
  ```
- **Caveat — `defaultFocus` does not pull focus in from outside its region.** It picks the default target *within* a focus region once focus enters that region. If the form is presented alongside a scene-level focus claimant (a `.searchable` toolbar field is the usual culprit) the search field holds first-responder and `defaultFocus` silently does nothing. Two mitigations, applied at the surrounding view rather than the form:
  1. Blur the claimant explicitly when the form presents — `.onChange(of: selected) { if $1 != nil { searchFieldFocused = false } }` on the list.
  2. Back `defaultFocus` with an imperative `.task(id:)` on the form that sets `focusedField = .target` once the view is in the window hierarchy.
- Advance focus on submit — when Return is pressed in a text field, move to the next logical field:
  ```swift
  TextField("Payee", text: $payee)
      .focused($focusedField, equals: .payee)
      .onSubmit { focusedField = .amount }
  ```
- Dismiss focus explicitly when the form is complete: `focusedField = nil`
- **Don't** apply `.focusable()` to standard controls (`TextField`, `Picker`, `Toggle`, `DatePicker`) — they're already focusable. Adding it produces double focus rings and requires two Tab presses to advance.

### List & Table Selection

Use `List(_:selection:rowContent:)` to get native keyboard selection for free:

```swift
// Single selection
@State private var selectedTransaction: Transaction.ID?

List(transactions, selection: $selectedTransaction) { transaction in
    TransactionRow(transaction: transaction)
        .contentShape(.rect)  // Entire row is clickable
}
.contextMenu(forSelectionType: Transaction.ID.self) { selection in
    Button("Edit", systemImage: "pencil") { editTransaction(selection) }
    Button("Delete", systemImage: "trash", role: .destructive) {
        deleteTransactions(selection)
    }
} primaryAction: { selection in
    // Double-click (macOS) / Return key — open detail
    openDetail(for: selection)
}
```

**Rules:**
- Always use `List(_:selection:rowContent:)` — this gives you arrow key navigation, Shift+click extend selection, and Cmd+click toggle selection for free.
- Always apply `.contentShape(.rect)` to rows so the entire row area is clickable, not just the text content.
- Wire `primaryAction` for double-click and Return — this is the standard macOS pattern for "open" or "drill in."
- Arrow keys move selection; Return triggers primary action; Escape clears selection — these are built-in behaviours, don't override them.
- For multi-selection, use `Set<Transaction.ID>` instead of an optional single ID:
  ```swift
  @State private var selectedTransactions: Set<Transaction.ID> = []
  ```
- Context menus via `contextMenu(forSelectionType:menu:primaryAction:)` automatically receive the current selection set — they work for both single and multi-selection.
- **Don't** build custom keyboard handlers for arrow navigation in lists — `List(selection:)` handles this natively.

### Tab Order & Focus Sections

**Default behaviour:** Tab moves focus in reading order — leading to trailing, then top to bottom. This works well for simple forms but breaks down in multi-column layouts.

**Use `focusSection()` to group columns** so Tab completes one column before moving to the next:

```swift
HStack {
    // Tab through all fields in the sidebar before moving to content
    SidebarForm(...)
        .focusSection()

    ContentArea(...)
        .focusSection()
}
```

**Rules:**
- `focusSection()` only organises existing focusable views into groups — it doesn't make non-focusable views focusable.
- In `NavigationSplitView`, the sidebar and detail are already separate focus sections — Tab within the sidebar stays in the sidebar.
- Inspector panels are separate focus sections. Users Tab within them independently. Escape or the close button dismisses them.
- **Don't** try to control exact tab order between individual fields — SwiftUI doesn't support explicit ordering. Instead, arrange the view hierarchy so reading order matches the desired tab order.
- If reading order doesn't match the desired flow, restructure the view hierarchy rather than fighting the framework.

### Focused Values & Menu Commands

Wire selection state to menu bar commands using `@FocusedValue` so that menu items respond to the active view's selection:

```swift
// 1. Define the key
struct SelectedTransactionKey: FocusedValueKey {
    typealias Value = Binding<Transaction?>
}

extension FocusedValues {
    var selectedTransaction: Binding<Transaction?>? {
        get { self[SelectedTransactionKey.self] }
        set { self[SelectedTransactionKey.self] = newValue }
    }
}

// 2. Publish from the view that owns the selection
TransactionListView(...)
    .focusedSceneValue(\.selectedTransaction, $selectedTransaction)

// 3. Consume in menu commands
struct MoolahCommands: Commands {
    @FocusedValue(\.selectedTransaction) var selectedTransaction

    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Button("Duplicate Transaction") {
                // Use selectedTransaction binding
            }
            .keyboardShortcut("d", modifiers: .command)
            .disabled(selectedTransaction?.wrappedValue == nil)
        }
    }
}
```

**Rules:**
- Use `focusedSceneValue` (not `focusedValue`) when the value should be available scene-wide — this is almost always what you want for menu commands.
- Use `focusedValue` only when visibility should be limited to the focused view subtree.
- Disable menu items when no selection exists — don't hide them. Users expect to see the full menu structure.
- Menu commands that operate on a selection should accept `Set<ID>` to work with both single and multi-selection.

### Standard Keyboard Expectations

These are macOS conventions that users expect. Violating them makes the app feel foreign.

| Key | Expected Behaviour |
|-----|---------------------|
| **Tab / Shift+Tab** | Move focus forward/backward through controls |
| **Arrow keys** | Move selection within a list, table, or segmented control |
| **Return** | Activate the default button; trigger primary action on selected list item |
| **Space** | Activate the focused control (button, checkbox, toggle) |
| **Escape** | Dismiss the current sheet, popover, or inspector; cancel current operation; clear selection in a list |
| **Cmd+.** | Cancel (equivalent to Escape in dialogs — works even when Escape is intercepted) |
| **Delete** | Delete selected item(s) with confirmation |
| **Cmd+A** | Select all (in lists that support multi-selection, and in text fields) |

**Rules:**
- Sheets and inspectors **must** dismiss on Escape. Use `.keyboardShortcut(.escape)` on cancel/close buttons, or rely on SwiftUI's built-in sheet dismissal.
- Confirmation dialogs should have the destructive action as **non-default** — Return should trigger the safe action (Cancel), not Delete.
- In dialogs with Cancel/Save, Cancel has the focus ring (activated by Space), Save is the default button (activated by Return).
- Support full keyboard access: every interactive control must be reachable via Tab. Test with System Settings > Keyboard > Keyboard Navigation enabled.
- **Don't** intercept Escape for custom behaviour when a sheet or popover is visible — the system dismissal must take priority.

---

## 14. Menu Bar & Commands (macOS)

On macOS the menu bar is the **canonical index of every command the app can perform.** Full-keyboard-access users, VoiceOver users, and power users all discover commands by browsing menus and by typing a command name into Help > Search. If an action isn't in the menu bar, for a significant fraction of users it doesn't exist.

iOS is different: menus there are contextual and scoped to a specific control. The rules in this section apply to macOS only. Where a command needs platform parity, implement it on iOS as a toolbar item, context menu, or keyboard shortcut on the relevant view — not via the Mac menu bar.

### Philosophy

- **Every user-initiated action has a menu item.** Toolbar buttons, context menus, and swipe actions exist *in addition to* a menu entry, never *instead of* one. The only exceptions are direct-manipulation gestures that have no clear verb (drag, pinch, click to select).
- **Menu bar, toolbar, and context menu must agree.** If the toolbar has a ⌘F shortcut for "Find Transaction", the menu bar must have a matching Edit > Find Transaction… item with the same shortcut. If a context menu offers "Reconcile", a top-level menu must offer it too.
- **Disable, don't hide.** Items reveal *what the app can do*. A greyed-out `Delete Transaction` with no selection is better than a menu that changes shape based on state. Reserve hiding for items that depend on license/build/mode (debug-only, admin-only), never on transient selection.
- **Menus are for ⌘-modified commands.** Single-key shortcuts for list navigation (`j`, `k`, `space`, `return`) do not belong in the menu bar — they go in a Keyboard Shortcuts help window.

### Top-Level Menu Structure

Moolah's macOS menu bar, left to right:

**Moolah · File · Edit · View · Go · Transaction · Window · Help**

Do not add a generic "Actions" or "Tools" menu. Domain commands go under a menu named for the primary noun they act on (see `Transaction` below).

#### Moolah (App Menu)

System-provided. Never reorder or rename:

- `About Moolah` — no ellipsis (opens a fixed window, takes no input)
- `Settings…` — ⌘, automatic via the `Settings { }` scene
- `Services ▸` — system-provided
- `Hide Moolah` — ⌘H
- `Hide Others` — ⌥⌘H
- `Show All`
- `Quit Moolah` — ⌘Q

SwiftUI placement: `.appInfo` (About), `.appSettings` (Settings), `.systemServices`, `.appVisibility`. Only `.appInfo` is customized — for the custom About window.

#### File

Creation, import/export, and per-window I/O. Use `.newItem`, `.saveItem`, `.importExport` placements.

```
File
  New Transaction              ⌘N       (.newItem — replacing)
  New Earmark                  ⇧⌘N      (.newItem — after)
  New Account…                 ⌃⌘N      (.newItem — after)
  New Category…                ⌥⌘N      (.newItem — after)
  —
  New Window                   ⌥⇧⌘N     (SwiftUI default when WindowGroup is present)
  Open Profile ▸                        (.saveItem — before; submenu of profiles)
  —
  Close Window                 ⌘W       (system-provided)
  —
  Import Profile…              ⇧⌘I      (.importExport)
  Export Profile…              ⇧⌘E      (.importExport)
  —
  Sign Out                     ⇧⌘Q      (bottom of File, before system Quit)
```

Rationale: the "New" group owns the ⌘N namespace (see §14 Keyboard Shortcuts). New Window moves out to ⌥⇧⌘N so ⌘N can mean "create the primary noun" (a Mac convention Electron apps routinely break).

#### Edit

Standard pasteboard and undo/redo plus app-specific copy/find actions. Use `.undoRedo`, `.pasteboard`, `.textEditing` placements. Even in a finance app where users aren't editing rich text, the Edit menu should exist with the standard items so system services and VoiceOver work correctly.

```
Edit
  Undo Edit Transaction        ⌘Z
  Redo Edit Transaction        ⇧⌘Z
  —
  Cut                          ⌘X
  Copy                         ⌘C
  Paste                        ⌘V
  Delete
  Select All                   ⌘A
  —
  Copy Transaction Link        ⌃⌘C      (only when a single transaction is selected)
  —
  Find Transactions…           ⌘F       (focuses the search field; not a separate window)
  Find Next                    ⌘G
  Find Previous                ⇧⌘G
```

Do **not** pull in `TextEditingCommands()` or `TextFormattingCommands()` — Moolah doesn't edit rich text. Add pasteboard and find items manually.

Undo/Redo labels should **include the action name** — `Undo Edit Transaction`, `Undo Pay Scheduled Transaction`, `Undo Delete Earmark`. SwiftUI manages this automatically when you use the environment `UndoManager`.

#### View

Chrome and display-state toggles only. No destinations, no creation actions.

```
View
  Show Sidebar                 ⌃⌘S
  Show Inspector               ⌥⌘I
  —
  Sort Transactions By ▸
    Date
    Amount
    Payee
    Category
  Group Transactions By Date
  —
  Show Running Balance
  Show Hidden Accounts         ⇧⌘H
  —
  Show Toolbar                 ⌥⌘T
  Customize Toolbar…
  —
  Enter Full Screen            ⌃⌘F
```

Compose from `SidebarCommands()`, `ToolbarCommands()`, and `InspectorCommands()` for the platform-standard items (these provide the correct label flip, placements, and localization automatically).

#### Go

Sidebar navigation. Modeled on NetNewsWire and Mail.

```
Go
  Accounts                     ⌘1
  Transactions                 ⌘2
  Scheduled                    ⌘3
  Earmarks                     ⌘4
  Categories                   ⌘5
  Reports                      ⌘6
  —
  Go Back                      ⌘[
  Go Forward                   ⌘]
```

⌘0 is reserved for "bring the Main Window forward" (see Window menu). ⌘1–⌘9 map to primary sidebar destinations *only* — never arbitrary actions.

#### Transaction

The primary domain menu. Named for the noun the commands act on (Apple's Mail has `Mailbox` / `Message`; NetNewsWire has `Article`). Contains verbs that operate on the current selection.

```
Transaction
  Edit Transaction…                    (opens inspector; fires on list double-click / Return)
  Duplicate Transaction        ⌘D
  —
  Mark as Cleared              ⌘K
  Mark All as Cleared          ⇧⌘K
  —
  Pay Scheduled Transaction            (no shortcut — ⌘P is reserved for Print)
  Skip Next Occurrence
  —
  Reveal in Account
  Copy Transaction Link        ⌃⌘C
  —
  Delete Transaction…                  (ellipsis — confirmation alert; Delete key fires on list focus)
```

Pay Scheduled Transaction is intentionally shortcut-less: ⌘P is a universal Mac shortcut for Print and must not be reassigned, even in apps without a Print command — users hit it reflexively and expect nothing bad to happen. The action is reachable from the Transaction menu, the inline Pay button on upcoming rows, and the context menu.

Every item here **must** be disabled (not hidden) when no transaction is selected — use a `@FocusedValue(\.selectedTransaction)` binding.

Labels match the selection count: `Delete Transaction` with one selected, `Delete 3 Transactions` with many. Prefer the singular when it reads naturally either way.

#### Additional Domain Menus (Account, Earmark)

When the app has more than one primary noun the user acts on, each gets its own domain menu positioned between `Transaction` and `Window`:

```
… View · Go · Transaction · Account · Earmark · Window · Help
```

Each domain menu follows the same rules as `Transaction` — verb-phrase items, operate on the focused window's selection via `@FocusedValue`, disabled (not hidden) when no selection is present. Keep each menu short (3–6 items). If a domain has only one or two menu-worthy actions, inline them into `Transaction` under a noun prefix (`Edit Account…`, `View Account Transactions`) instead of creating a dedicated menu.

Do not create a domain menu just to host a single command. And do not invent a generic `Domain` or `Items` menu that covers multiple nouns — each menu owns exactly one noun.

#### Window

Mostly SwiftUI-provided via `.windowSize`, `.windowArrangement`, `.singleWindowList`:

```
Window
  Minimize                     ⌘M
  Zoom
  —
  Tile Window to Left of Screen
  Tile Window to Right of Screen
  —
  Transactions                 ⌘0       (bring main window forward)
  About Moolah                          (if open)
  —
  Bring All to Front
  —
  [dynamic list of open profile windows]
```

Don't override the SwiftUI defaults. The list at the bottom populates automatically.

#### Help

Keep — **never remove the Help menu.** It provides the search field that indexes every menu item by name, which is how VoiceOver and Full Keyboard Access users discover disabled commands.

```
Help
  Search                                (SwiftUI-provided)
  Moolah Help                  ⌘?
  Keyboard Shortcuts…          ⇧⌘/
  —
  Release Notes…
  Report a Bug…
  —
  Privacy Policy
  Terms of Service
```

The `Keyboard Shortcuts…` item opens an in-app cheatsheet window listing every shortcut — including the single-key list-navigation ones that don't live in menus (`j`, `k`, `space`, `return`). This is a standard pattern in every Mac-assed Mac app (NetNewsWire, Things, OmniFocus).

### Naming Conventions

**Title case** throughout. Capitalize every word except prepositions of four or fewer letters; always capitalize the first and last word. Never sentence case. Examples: `Save As…`, `Move to Trash`, `Open Recent`, `Mark as Cleared`.

**Verbs for actions, nouns for attributes.** `Print`, `Copy`, `Export…`, `Mark as Cleared` are verb phrases. `Date`, `Amount`, `Bodoni`, `12 pt` inside a `Sort By ▸` submenu are allowed noun attributes.

**Ellipsis (…)** — use the single U+2026 character, never three periods (`...`). An ellipsis appears **iff the item requires additional user input before the action takes effect**:

| Needs ellipsis | No ellipsis |
|----------------|-------------|
| `Save As…` (file picker) | `Save` |
| `Export Profile…` (save panel) | `Refresh` |
| `Find Transactions…` (focuses field) | `About Moolah` |
| `Import Profile…` (open panel) | `Show Sidebar` |
| `New Transaction…` if opening a form sheet | `New Window` |
| `Customize Toolbar…` (opens sheet) | `Sign Out` |
| `Delete Transaction…` when a confirm alert appears | `Quit Moolah` |

Confirm-only dialogs for destructive actions earn an ellipsis as a warning. Windows opened by name (About, Inspector, Sidebar) do not — the click *is* the action.

**Toggle state.** Prefer the verb-pair pattern that flips the label on state change:

| ✅ Good | ❌ Bad |
|---------|--------|
| `Show Sidebar` / `Hide Sidebar` | `☑ Sidebar` |
| `Show Hidden Accounts` / `Hide Hidden Accounts` | `Hidden Accounts (on)` |
| `Show Running Balance` / `Hide Running Balance` | Checkmark-only `Running Balance` |

Apple HIG verbatim: *"Don't use this kind of toggled item [a checkmark] to indicate the presence or absence of a feature such as a grid or ruler. It's unclear whether the checkmark means that the feature is in effect or whether choosing the command turns the feature on."*

Reserve checkmarks for **style-attribute radio groups** inside submenus: `Sort By ▸ Date` / `Amount` / `Payee` — one has a checkmark, the others don't.

**Singular vs plural by selection count.**

```swift
// Bad — ambiguous
Button("Delete", role: .destructive) { … }

// Good — labels match selection
let label = selectionCount == 1
    ? "Delete Transaction"
    : "Delete \(selectionCount) Transactions"
Button(label, role: .destructive) { … }
```

Prefer the singular form when either reads naturally (`Mark as Cleared` works for 1 or N). Use the explicit count only when plural grammar forces it.

**Include the app name** in `About Moolah`, `Hide Moolah`, `Quit Moolah`, `Moolah Help`. These four are the only places the app's name appears in the standard menus.

**Keep the object noun.** `Mark as Cleared` not `Mark Cleared`; `Copy Transaction Link` not `Copy Link`; `Sort Transactions By ▸` not `Sort By ▸`. The extra word clarifies which thing is being acted on and reads better in VoiceOver.

### Keyboard Shortcuts

#### Reserved Shortcuts — Never Reassign

These shortcuts are owned by macOS or by universal Mac convention. Using them for a different action breaks user expectations and — in many cases — the Mac itself.

| Shortcut | Meaning | Source |
|----------|---------|--------|
| ⌘C / ⌘X / ⌘V / ⌘A | Copy / Cut / Paste / Select All | Universal |
| ⌘Z / ⇧⌘Z | Undo / Redo | Universal |
| ⌘S / ⇧⌘S | Save / Save As | Document apps |
| ⌘O | Open | Universal |
| ⌘N | New (the app's primary "new" action) | Universal |
| ⌘W | Close Window | System |
| ⇧⌘W | Close All Windows | System |
| ⌘Q | Quit | System |
| ⌘, | Settings | System |
| ⌘F / ⌘G / ⇧⌘G | Find / Find Next / Find Previous | Universal |
| ⌘P | Print | Universal |
| ⌘H / ⌥⌘H | Hide / Hide Others | System |
| ⌘M | Minimize | System |
| ⌘T | New Tab | System (tabbed apps) |
| ⌘R | Refresh / Reload | Universal |
| ⌘1…⌘9 | Switch to primary destination | Universal |
| ⌘0 | Main Window / Actual Size | Universal |
| ⌘Space / ⌘Tab / ⌘` | System | Reserved |
| ⇧⌘3 / ⇧⌘4 / ⇧⌘5 | Screenshots | System |
| ⌘? | Help | System |
| ⌘. | Cancel (in dialogs) | System |

#### Modifier Conventions

- **Shift = reverse direction, or larger scope.** `⇧⌘Z` reverses Undo. `⇧⌘G` finds previous. `⇧⌘K` marks *all* as cleared (vs `⌘K` marks one). Shift may also stand in as a collision-avoider when the natural `⌘`-only key is already reserved — e.g. Account > Sync Now uses `⇧⌘R` because `⌘R` is taken by Refresh.
- **Option = alternate behavior, or apply to all siblings.** `⌥⌘H` hides others (not self). `⌥⌘W` would close all windows in many apps. Hold Option to reveal hidden alternate menu items (see **Alternate Items** below).
- **Control = rarely used for app shortcuts.** Reserved for text-navigation conventions (`^A` line start, `^E` line end). Avoid inventing ⌃-only shortcuts.
- **Command = the app-level primary modifier.** Every app command uses ⌘ as its base. Unmodified keys (`j`, `k`, Space) are for list navigation only.

**Modifier display order** when shown in menus: Control · Option · Shift · Command · key → `⌃⌥⇧⌘N`. SwiftUI's `.keyboardShortcut(_:modifiers:)` emits this order automatically.

#### Moolah-Specific Shortcut Map

Assign shortcuts only when the action is **frequent** (used more than a few times per session) and **has a menu item** that displays the shortcut. Never put a shortcut on a view-only button without a matching menu item.

| Action | Shortcut | Menu |
|--------|----------|------|
| New Transaction | ⌘N | File |
| New Earmark | ⇧⌘N | File |
| New Account… | ⌃⌘N | File |
| New Category… | ⌥⌘N | File |
| New Window | ⌥⇧⌘N | File (SwiftUI default) |
| Open Profile… (submenu) | — | File |
| Import Profile… | ⇧⌘I | File |
| Export Profile… | ⇧⌘E | File |
| Close Window | ⌘W | File (system) |
| Sign Out | ⇧⌘Q | File |
| Find Transactions… | ⌘F | Edit |
| Find Next / Previous | ⌘G / ⇧⌘G | Edit |
| Copy Transaction Link | ⌃⌘C | Edit |
| Show/Hide Sidebar | ⌃⌘S | View |
| Show/Hide Inspector | ⌥⌘I | View |
| Show/Hide Hidden Accounts | ⇧⌘H | View |
| Show/Hide Spam Transactions | — | View |
| Enter/Exit Full Screen | ⌃⌘F | View |
| Go to Accounts / Transactions / … | ⌘1…⌘6 | Go |
| Back / Forward | ⌘[ / ⌘] | Go |
| Sync Now | ⇧⌘R | Account (synced accounts only; ⌘R taken by Refresh). Full resync is the adjacent `Resync Now (Full History)` menu item — no shortcut (SwiftUI can't do an Option-alternate; header button's Option relabel carries the mnemonic). |
| Duplicate Transaction | ⌘D | Transaction |
| Mark as Cleared / All | ⌘K / ⇧⌘K | Transaction |
| Pay Scheduled Transaction | — | Transaction (⌘P reserved for Print) |
| Edit Transaction… | — | Transaction (list primaryAction on Return/double-click) |
| Delete Transaction… | — | Transaction (Delete key on list focus via onDeleteCommand) |
| Refresh | ⌘R | (no menu item — handled by `.refreshable`; see note) |
| Moolah Help | ⌘? | Help |
| Keyboard Shortcuts | ⇧⌘/ | Help |

**Note on ⌘R:** SwiftUI's `.refreshable` modifier wires ⌘R automatically in lists that support it. If you want the shortcut available outside a scrollable list, add a File > Refresh item.

**List-navigation shortcuts** (not in menus; documented in the Keyboard Shortcuts help sheet):

| Key | Action |
|-----|--------|
| ↑ / ↓ | Move selection up/down |
| j / k | Next / previous (Mail-style, optional) |
| Space | Primary action on selected item (open inspector) |
| Return | Primary action on selected item |
| Escape | Deselect / dismiss inspector |
| ⌫ | Delete selected item |

Every interactive control must still be reachable via **Tab** with Full Keyboard Access enabled, independent of these shortcuts.

### Icons in Menu Items

**Default: no icons in menu items.** Mac menus have been text-only for forty years, and users read them by text. macOS 26 introduced optional SF Symbols in menus, but Apple's own adoption is inconsistent and the strong community consensus (including [Daring Fireball](https://daringfireball.net/2026/03/what_to_do_about_those_menu_item_icons_in_macos_26_tahoe)) is **reserve icons for the rare items where the glyph adds real information, so they stand out**.

Acceptable uses:

- **Share submenu** — system-inserted; per-destination icon.
- **Open Profile submenu** — the profile's currency flag or avatar; the icon carries identity that the text does not.
- **Recent Items submenu** — file-type icon for each entry.
- **Items that mirror a toolbar button** where the toolbar's SF Symbol is the recognized shorthand for the action (e.g., `Reveal in Finder` with `magnifyingglass`). Use sparingly.

**Context menus (right-click / long-press) are a separate case.** iOS renders contextual menus with leading icons by convention, and macOS 26 does the same. Keep `systemImage:` on context-menu `Button`s — they read as system-native on iOS and provide visual affordance on macOS. The "no icons by default" rule applies to **the menu bar only** (`CommandMenu`, `CommandGroup`).

Unacceptable:

- Icons on every item in File/Edit/View.
- Icons on standard text commands (Cut/Copy/Paste/Undo/Select All).
- Icons on destructive items to try to make them stand out (the grouping and naming carry that weight).
- Icons on `About Moolah`, `Quit Moolah`, `Hide Moolah`.

### Grouping & Dividers

Every menu should read as **3–5 items per group, 2–4 groups per menu.** Separate groups with `Divider()` (rendered as `NSMenuItem.separator`).

Chunk by semantic intent, not alphabetically:

```
File
  [Create group]                 New Transaction, New Earmark, New Account, New Category
  ─
  [Window group]                 New Window, Open Profile
  ─
  [I/O group]                    Import Profile, Export Profile
  ─
  [Lifecycle group]              Sign Out
```

**Most-frequent item goes at the top of its group.** For `Transaction`: `Edit…` appears first because pressing Return on a selected row is the expected flow.

**Long menus need submenus.** Once a menu crosses 12 items, promote the most attribute-like group into a submenu (`Sort By ▸`, `Display ▸`).

**Destructive actions occupy their own group at the bottom.**

### Submenus

**One level deep. Maximum two.** No submenus inside submenus inside submenus.

Use submenus for:

- **Attribute sets**: `Sort By ▸`, `Group By ▸`, `Display ▸`. These are radio groups with checkmarks.
- **Related commands that can't all fit inline**: `Find ▸ Find…` / `Find Next` / `Find Previous` / `Jump to Selection`.
- **Dynamic lists**: `Open Profile ▸`, `Recent Transactions ▸`.

Do **not** use submenus for:

- Unrelated actions bucketed under a topic (`File Operations ▸ Save / Print / Export` is wrong).
- Anything with three or fewer items — inline them instead.
- The menu's primary commands.

Submenu titles are nouns or noun phrases, never ellipsis-suffixed. The child items may take ellipses normally.

### Dynamic Menus

For data-driven lists (profiles, recent items):

```swift
Menu("Open Profile") {
    ForEach(profileStore.profiles) { profile in
        Button(profile.label) { openWindow(value: profile.id) }
    }
    if profileStore.profiles.isEmpty {
        Text("No Profiles")  // disabled placeholder — Text in a menu renders as disabled
    }
    Divider()
    SettingsLink { Text("Manage Profiles…") }
}
```

Rules:

- **Never show an empty submenu.** Provide a disabled placeholder like `No Profiles` or `No Recent Items`.
- **Cap recents at 10** (Apple's Finder convention). Older entries fall off.
- **Non-recent data lists** (accounts, profiles) show every entry sorted stably.
- **Include a terminal management item** when the list is user-editable: `Clear Menu` or `Manage Profiles…` after a divider.
- **Alternate items** revealed by ⌥ must have a primary-accessible equivalent elsewhere. Never make ⌥ the only path.

### Enabled vs Disabled State

Menu items exist to describe what the app can do. Users browse menus to learn the app, and Help > Search only finds items that exist in a menu.

- **Disable, don't hide** when an item is unavailable for the current selection or state. SwiftUI: `.disabled(binding.wrappedValue == nil)`.
- **Hide** only when the item depends on build mode (debug-only), entitlement (admin/pro feature), or platform (macOS-only item on iOS).
- **Never disable an entire menu.** The title stays enabled; individual items go dim. macOS handles this automatically when every item is disabled.
- **Communicate why an item is disabled** via the view's `.help("…")` tooltip on the underlying control, or via adjacent UI (a status line). Don't put explanatory text in the menu item name itself.
- Disabled items must still be visible to VoiceOver and to Help > Search.

### Destructive Actions

- **Bottom group**, separated by `Divider`. Never mixed with safe actions.
- **Specific verbs.** `Delete Transaction`, `Remove Account`, `Empty Recycle Bin`. Not bare `Remove` or `Delete`.
- **Confirm irreversible deletions** with an `Alert` and a destructive-styled button. If the action is undoable via Undo Manager, the confirm may be skipped.
- **Ellipsis if a confirm alert appears** — `Delete Profile…`. The ellipsis signals "this will ask you something."
- **No bare shortcut on destructive items.** Use the Delete key on selection (requires focus) for list-item deletion. Never assign `⌘⌫` alone — too easy to misfire.
- **The menu item itself is not red or icon-marked.** The confirmation alert carries the visual warning.

### Context Menu ↔ Menu Bar Parity

Every context menu item (right-click on a list row) should have a matching top-level menu bar item in the domain menu (`Transaction`, `Account`, etc.). Users right-click for speed, but they discover the feature in the menu bar.

```swift
// Context menu on a transaction row
.contextMenu {
    Button("Edit Transaction…") { openInspector() }
    Button("Duplicate Transaction") { duplicate() }
    Button("Mark as Cleared") { markCleared() }
    Divider()
    Button("Delete Transaction", role: .destructive) { confirmDelete() }
}

// Must be mirrored by:
CommandMenu("Transaction") {
    Button("Edit Transaction…") { … }                  // no menu shortcut — fires on list focus
    Button("Duplicate Transaction") { … }.keyboardShortcut("d")
    Button("Mark as Cleared") { … }.keyboardShortcut("k")
    Divider()
    Button("Delete Transaction…", role: .destructive) { … }   // ellipsis for confirmation
}
```

Wire both to the same action via a `@FocusedValue` (see Section 13).

### Toolbar ↔ Menu Bar Parity

Every toolbar button on a primary window must have a menu equivalent. Toolbar-only commands are invisible to keyboard-only users and to Help search.

- Toolbar actions that map to `ToolbarItem(placement: .primaryAction)` → matching menu item in File or the domain menu.
- Toolbar-level ⌘F, ⌘R, ⌘N shortcuts must also appear in the menu bar item that displays that shortcut.
- When the toolbar offers a `Label`-style button, the menu item uses the same verb phrase (`New Transaction` in both).

### SwiftUI Wiring

#### Standard Command Groups

```swift
.commands {
    // App-menu
    AboutCommands()

    // File — compose replacing/before/after newItem and saveItem
    NewTransactionCommands()        // replaces .newItem
    NewEarmarkCommands()            // after .newItem
    NewAccountCommands()            // after .newItem
    NewCategoryCommands()           // after .newItem
    ProfileCommands(…)              // before .saveItem (Open Profile, Import/Export, Sign Out)

    // Edit — roll your own; don't pull TextEditingCommands unless editing text
    FindCommands()                  // .textEditing
    CopyLinkCommands()              // .pasteboard (after)

    // View — compose with SwiftUI-provided builders
    SidebarCommands()
    ToolbarCommands()
    InspectorCommands()
    SortCommands()                  // .sidebar (after)
    ShowHiddenCommands()            // .sidebar (after)

    // Go — new top-level CommandMenu
    GoCommands()

    // Transaction — new top-level CommandMenu
    TransactionCommands()

    // Help
    HelpCommands()                  // after SwiftUI's search field
}
```

Reach for built-in `Commands` structs (`SidebarCommands`, `ToolbarCommands`, `InspectorCommands`) before hand-rolling equivalents — they handle labels, placements, and label flips correctly across localizations.

#### Focused Values Pattern

Any menu command that acts on a selection must receive the selection via `@FocusedValue`. Define one key per piece of state, publish from the view that owns it, consume in the command group:

```swift
// 1. Define
struct SelectedTransactionKey: FocusedValueKey {
    typealias Value = Binding<Transaction?>
}

extension FocusedValues {
    var selectedTransaction: Binding<Transaction?>? {
        get { self[SelectedTransactionKey.self] }
        set { self[SelectedTransactionKey.self] = newValue }
    }
}

// 2. Publish from the view
TransactionListView(…)
    .focusedSceneValue(\.selectedTransaction, $selectedTransaction)

// 3. Consume in the command
struct TransactionCommands: Commands {
    @FocusedValue(\.selectedTransaction) var selection

    var body: some Commands {
        CommandMenu("Transaction") {
            Button("Edit Transaction…") { openInspector(selection?.wrappedValue) }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(selection?.wrappedValue == nil)
        }
    }
}
```

Prefer `focusedSceneValue` over `focusedValue` — scene-wide availability is almost always what menu commands want.

### Anti-Patterns

- ❌ **Repurposing ⌘N for "New Window".** ⌘N belongs to the app's primary creation verb.
- ❌ **Reassigning reserved shortcuts** (⌘H, ⌘M, ⌘Q, ⌘W, ⌘,). Especially ⌘H — common offender.
- ❌ **Duplicate shortcuts across visible commands** (e.g., ⇧⌘N claimed by both New Earmark and New Category). One shortcut, one visible action.
- ❌ **Toolbar shortcuts not surfaced in any menu item.** Invisible to Help search and Full Keyboard Access.
- ❌ **Context-menu-only actions** with no top-level menu entry.
- ❌ **Three-period ellipsis (`...`) instead of U+2026 (`…`).**
- ❌ **Missing ellipsis** on items that open input-requiring dialogs.
- ❌ **Stray ellipsis** on items that act immediately (`About Moolah…`, `Show Inspector…`).
- ❌ **Sentence case** (`Save as…`). Use title case (`Save As…`).
- ❌ **Single checkmark** on a feature toggle (`☑ Sidebar`). Use verb-pair `Show Sidebar` / `Hide Sidebar`.
- ❌ **Hiding items based on selection state.** Disable them instead.
- ❌ **Empty submenus.** Show a disabled `No Profiles` placeholder.
- ❌ **Submenus nested more than one level deep.**
- ❌ **An icon on every menu item.** Icons become noise; reserve for items where the glyph carries identity (Share destinations, profile switcher, toolbar mirrors).
- ❌ **Removing the Help menu** or the SwiftUI search field inside it.
- ❌ **A generic "Actions" or "Tools" top-level menu.** Use the primary noun (`Transaction`, `Account`).
- ❌ **Single-key list-navigation shortcuts** (`j`, `k`, `space`) rendered as menu items. They belong in the Keyboard Shortcuts help sheet.
- ❌ **Undo/Redo without the action name** — use SwiftUI's `UndoManager` so labels read `Undo Edit Transaction`.

---

## Version History
- **1.5** (2026-04-26): Section 13 now opens with a prominent pointer to `guides/FOCUS_GUIDE.md`, the canonical reference for SwiftUI focus management (focus containers, `@FocusState` semantics, `defaultFocus` no-op cases, macOS popover key-window behaviour, anti-patterns).
- **1.4** (2026-04-26): Add "Placeholder Text (`prompt:`)" subsection to Section 6 — placeholders are hints, never default values; decision tree (no placeholder when label suffices; "e.g." / format / "Required" hints; pre-fill defaults instead of placeholdering them); Apple HIG and NN/g citations.
- **1.3** (2026-04-20): Add "Sheets & Dialogs" subsection to Section 6 — content padding rules (24pt macOS custom / 20pt iOS / 16pt popover, system handles `Form` and `.alert`), macOS minimum-frame table, button placement, examples and anti-patterns. Extended Section 3 spacing table and Section 11 layout anti-patterns with sheet padding rules.
- **1.2** (2026-04-17): Add Section 14 — Menu Bar & Commands (macOS), covering top-level menu structure, naming, keyboard shortcuts, icons, grouping, dynamic menus, toolbar/context-menu parity, SwiftUI wiring. Trimmed Section 9's shortcut list in favor of Section 14.
- **1.1** (2026-04-15): Add Section 13 — Focus, Tab Order & Selection (form focus, list selection, focus sections, focused values, keyboard expectations)
- **1.0** (2026-04-08): Initial style guide for Moolah native app (macOS-first, adaptive density, semantic colors, charts)
