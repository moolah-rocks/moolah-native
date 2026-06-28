# Moolah Focus Guide

**Version:** 1.0
**Platform targets:** macOS 26+ (primary), iOS 26+ (secondary)
**Based on:** Apple SwiftUI documentation, WWDC21 "Direct and reflect focus in SwiftUI", WWDC23 "The SwiftUI cookbook for focus", AppKit `NSPopover` / `NSWindow` documentation, plus community resources where Apple's docs are silent.

---

## Mental model

SwiftUI focus is a **declarative reflection of the AppKit/UIKit responder chain**. There is one current focused view per *focus container*, and a focus container is what AppKit would call a key window — i.e. a `WindowGroup` window, a `Settings` scene, a `.sheet`, a `.popover` (which is its own `NSWindow` on macOS), an `.alert`, or a `.fullScreenCover`. Within a container, focus is a single value: nil, or one specific *focusable view*. `@FocusState` is a two-way binding between a Swift property and that one slot — assigning to it asks SwiftUI to move first-responder; reading it tells you where focus currently is. `defaultFocus(_:_:)` only seeds the slot once, the first time SwiftUI evaluates focus inside the region you put it on; if no view is in the responder chain yet (because the container hasn't been told to take key by AppKit), `defaultFocus` has nothing to seed and silently no-ops. Most "focus is broken" bugs in this codebase are not bugs in `@FocusState` itself — they are about the **container** not being key, or about a sibling focusable (a plain-styled button, an inert text field, a `.searchable` toolbar field) sitting earlier in the natural tab order and intercepting the seed.

Read this guide before touching any view that uses `@FocusState`, `.focused`, `.focusable`, `.focusSection`, `.defaultFocus`, `.focusedSceneValue`, or that programmatically moves focus.

---

## 1. The focus model

### 1.1 Focusable views

A *focusable view* is any view that participates in keyboard input routing. SwiftUI auto-vends focusable behaviour for the obvious cases and lets you opt in for custom ones:

| Control | Focusable? | Interaction kind |
|--------|------------|------------------|
| `TextField`, `SecureField`, `TextEditor` | Yes (always) | `.edit` |
| `Button` (with system style: `.bordered`, `.borderedProminent`, `.borderless`, default) | Yes when Full Keyboard Access (macOS) or hardware keyboard (iOS) is enabled | `.activate` |
| `Button(.plain)` | Yes for tab order, but **does not respond to Space** to activate (long-standing SwiftUI gap — see Section 9.4) | `.activate` |
| `Toggle`, `Picker` (`.menu`, `.segmented`), `DatePicker`, `Stepper`, `Slider`, `ColorPicker` | Yes | `.edit` for value editors, `.activate` for picker triggers |
| `Image`, `Text`, `VStack`/`HStack` containers | No, until you add `.focusable()` |
| `Link`, `NavigationLink` (in `List(selection:)`) | Yes | `.activate` |
| `List(_:selection:)` row | Selection, not focus, but the list itself is focusable as a unit |

You make a custom view focusable with the modifier introduced in WWDC21 and refined in WWDC23:

```swift
.focusable(_ isFocusable: Bool = true,
           interactions: FocusInteractions = .automatic)
```

Available on iOS 17+, macOS 14+, tvOS 15+, watchOS 8+ in its current `interactions:` form. Pre-Sonoma, `focusable()` existed but couldn't distinguish *edit* from *activate* — on macOS 14+ a custom view is always focusable on Tab unless you opt out via `interactions: .activate` plus the system "Keyboard navigation" setting.

`FocusInteractions` is an `OptionSet` with three useful members:

- `.activate` — the view responds to focus by being a tap/Space target (a button-like control).
- `.edit` — the view holds typing focus (a text-like control).
- `.automatic` — equivalent to `[.activate, .edit]`.

**Rule of thumb:** never put `.focusable()` on a view that is *already* focusable (`TextField`, `Button`, `Picker`, `Toggle`, `DatePicker`, `Slider`, etc.). Stacking it produces a double focus ring (one drawn by SwiftUI, one drawn by the wrapped AppKit control) and makes Tab require two presses to advance.

### 1.2 Focus scope and focus region

There are two related but distinct concepts. SwiftUI's documentation often uses *region* and *scope* interchangeably, but the underlying APIs are different:

- **Focus container.** Any presentation that hosts its own AppKit window or its own iOS root view: a `Window`/`WindowGroup` scene, `Settings`, `MenuBarExtra`, a `.sheet`, a `.popover`, an `.alert`, a `.confirmationDialog`, a `.fullScreenCover`. Each container has exactly one current focus, totally independent of every other container. When AppKit makes a different `NSWindow` key, the previous container's focus is suspended (not lost) — bring it back to key and focus restores.
- **Focus region** (defined by `.defaultFocus(_:_:priority:)`). A subtree within a container that says "if SwiftUI is choosing a default focus inside me, prefer this binding's value." Multiple regions can nest; the innermost region with a non-nil seed wins.
- **Focus scope** (`.focusScope(_ namespace: Namespace.ID)`). A boundary that limits the reach of the older `prefersDefaultFocus(_:in:)` modifier. Used mainly on tvOS/watchOS where you want one of several views to be the natural starting target. On macOS/iOS prefer `defaultFocus`.
- **Focus section** (`.focusSection()`, macOS 13+, tvOS 15+, iOS 17+). A grouping of focusables that influences *movement* (Tab, arrow keys, Apple TV swipes), not what becomes focused first. A section becomes a navigation target itself: if focus is to the left of a section, Tab picks the leftmost focusable inside it before moving past.

These four concepts sit at different layers — keep them straight. A `.popover` is a focus container. `Form { ... }.defaultFocus($f, .payee)` defines a focus region. `HStack { sidebar; detail }.focusSection()` arranges movement.

### 1.3 Containers per platform

| Container | macOS focus container? | iOS focus container? |
|---|---|---|
| `WindowGroup` window | Yes — backed by `NSWindow` | Yes — root view of scene |
| `Window`, `Settings`, `MenuBarExtra`, `DocumentGroup` window | Yes | n/a |
| `.sheet` | Yes — sheet is its own `NSWindow` (modal) | Yes — but `Bool`-form `@FocusState` works inside |
| `.popover` | **Yes — separate `NSWindow` (`NSPopover`'s child window)** | Adapts to a sheet by default; opt back into popover via `.presentationCompactAdaptation(.popover)` |
| `.alert`, `.confirmationDialog` | Yes (modal) | Yes (modal) |
| `.fullScreenCover` | n/a | Yes |
| `.inspector(...)` | No — same window, different focus section | No — same scene |
| `NavigationStack`, `NavigationSplitView` | No — they live inside a window | No |
| `.searchable` | No — it injects a focusable text field into the toolbar of the surrounding window/scene |

The macOS popover row is the one most people get wrong. A SwiftUI `.popover` on macOS hosts its content in an `NSPopover`, which itself uses a transient borderless `NSWindow` to display. That window has to become key for any text input inside the popover to get first-responder. SwiftUI's `.popover` *does* request key on present — but if the popover content has multiple focusables and SwiftUI hasn't been told which one is the seed, AppKit picks the one nearest the start of the responder chain, which is reading order. That is the root cause of the "Cancel button steals focus" symptom in our reproducer; see Section 6.

---

## 2. `@FocusState` in detail

`@FocusState` is a SwiftUI property wrapper (iOS 15+, macOS 12+, tvOS 15+, watchOS 8+) that owns a single piece of mutable state representing "which value-tagged view inside this view's container currently has focus."

### 2.1 The two storage shapes

```swift
// Shape A: Bool — exactly one binding-target
@FocusState private var isSearchFocused: Bool

// Shape B: Optional<Hashable> — many binding-targets, exactly one or none focused
enum Field: Hashable { case payee, amount, date, notes }
@FocusState private var focusedField: Field?
```

Both shapes drive the *same* underlying focus slot. The Bool shape is convenient when you have exactly one focusable in a small scope (e.g. a toolbar search field, a single-field popover). The Hashable-optional shape is correct for any form with two or more fields.

**Never use multiple parallel `@FocusState<Bool>` properties to track several fields.** They don't compose: setting one to `true` does not clear the others, SwiftUI has no way to enforce mutual exclusion across them, and bug reports range from "two fields show focus rings" to "Tab does nothing." Use one optional-enum `@FocusState` with one case per field.

### 2.2 The `.focused` modifiers

```swift
// Shape A: Bool
.focused(_ binding: FocusState<Bool>.Binding) -> some View

// Shape B: Hashable
.focused<Value>(_ binding: FocusState<Value?>.Binding,
                equals value: Value) -> some View where Value: Hashable
```

The Hashable form is **only** the optional binding form — `Value?` not `Value`. There is no non-optional Hashable form. This is intentional: there must always be a "no field focused" state.

### 2.3 Reading focus

`focusedField` reads as the value SwiftUI most-recently observed in the responder chain inside this container. It can change without you assigning to it (the user clicked a different field, Tab moved focus, the popover dismissed). Use `.onChange(of: focusedField)` to react.

### 2.4 Writing focus

Assigning `focusedField = .amount` asks SwiftUI to update the responder chain on the next runloop turn. Two important rules:

1. **Assignment must happen on the main actor.** `@FocusState`'s setter is `@MainActor`-isolated; from a `Task { ... }` you must hop back to main first or run the task on the main actor.
2. **The target view must already be installed in the window's view hierarchy** when the assignment is processed. If you assign focus before SwiftUI has had a chance to mount the focused view (most often: inside `init`, inside the first `body` evaluation, or inside a `.task` body that runs before the view is in a key window), the assignment is silently dropped. SwiftUI does not retry.

Rule 2 is why every "set focus in `onAppear`" tutorial recommends a delay. The framework gives you no formal "view is now in a key window" hook; in practice the recommended pattern (and what the WWDC23 cookbook uses) is `defaultFocus`, not imperative assignment. See Section 4.

### 2.5 Clearing focus

`focusedField = nil` asks SwiftUI to resign first-responder on the currently focused view. On iOS this dismisses the soft keyboard. On macOS it sets the window's first responder to the window itself (so Tab from there walks into the natural order from the top).

---

## 3. `.focused(_:)` vs `.focused(_:equals:)`

Both compile down to the same internal mechanism — a `_FocusedValueAction` registration that ties a view to a key-path in the focus state. The choice is purely about how you model the state:

```swift
// One field: Bool
@FocusState private var isSearchFocused: Bool

TextField("Search", text: $query)
    .focused($isSearchFocused)
```

```swift
// Many fields: Hashable optional
@FocusState private var field: Field?

TextField("Payee", text: $payee).focused($field, equals: .payee)
TextField("Notes", text: $notes).focused($field, equals: .notes)
```

**Platform quirks:**

- On iOS, the Bool form on a `TextField` that is the only focusable in its sheet works the most reliably for "show keyboard on appear" — set `isFocused = true` from `.task { ... }` and the keyboard pops up. The Hashable form is identical when your enum has exactly one case.
- On macOS, the Bool form on a `TextField` inside a popover is also fine, but you still need a focus seed for the popover's window; bind it from `.defaultFocus($isSearchFocused, true)` on the popover root, not from `.task`.
- Neither form works inside an `.alert` or `.confirmationDialog` — those modals manage their own focus and ignore your binding. Use the alert's own button-default semantics.
- The Hashable form requires the enum to be `Hashable` (note: not `Identifiable`), and the binding type is always `FocusState<Value?>.Binding`. There is no two-parameter equals form taking a non-optional binding.

---

## 4. `.defaultFocus(_:_:priority:)`

```swift
func defaultFocus<V>(_ binding: FocusState<V>.Binding,
                     _ value: V,
                     priority: DefaultFocusEvaluationPriority = .automatic) -> some View
```

Available on **iOS 17+, macOS 14+, tvOS 17+, watchOS 10+**. This is the canonical way to seed initial focus in a focus region. It does *not* run on every body evaluation; SwiftUI evaluates default focus exactly once per (container, focus region) combination — the first time focus is being computed and there is no current focused view in that region.

### 4.1 What `priority` actually does

`DefaultFocusEvaluationPriority` has two cases:

- `.automatic` — "this is a hint." If SwiftUI also has a structural reason to give focus elsewhere (e.g. the user just dragged the window's first responder onto a different view in the same region, or the system restored a saved focus from a previous appearance), that other choice wins.
- `.userInitiated` — "this is intentional, override the automatic ranking." Use this when the natural tab order would land on something other than what the user actually wants (the Cancel-button-steals-focus case in our reproducer).

`.userInitiated` does **not** make `defaultFocus` retry on every appearance, and it does **not** override an explicit `.focused` write — it only outranks `.automatic` defaults during the single evaluation pass.

### 4.2 What `.defaultFocus` cannot do

- It cannot pull focus *into* a region from outside. If an outer focus container (the parent window's `.searchable` toolbar field is the textbook case) is currently key and holds first responder, `defaultFocus` on a child sheet or popover will silently no-op — there is no focus evaluation happening inside the child region because focus is parked outside it. Mitigation: blur the outer claimant explicitly when the child presents (`searchFieldFocused = false` in `.onChange(of: isPresented)` on the parent), or rely on the modal nature of the child to take key (sheets and alerts do this automatically; popovers are flakier — see Section 6).
- It cannot focus a non-focusable view. The `value` you pass must correspond to a `.focused(_, equals:)` binding that's actually installed in the subtree.
- It cannot fire after the first evaluation. If focus has ever been computed in the region and resolved to nil or a different view, changing the seed value won't move focus. To re-seed mid-life, write to the `@FocusState` directly, or use `Environment(\.resetFocus)` (see Section 5.4).

### 4.3 Where to attach it

Attach `.defaultFocus` to the **outermost container of the focus region you want it to seed**, not to the field itself. Conceptually it says "inside this subtree, if you need a default, here's the answer." Putting it on the `TextField` and putting it on the `Form` containing that `TextField` are equivalent in effect, but the latter reads better and survives refactors that move the field around inside the form.

```swift
Form {
    TextField("Payee", text: $payee).focused($field, equals: .payee)
    TextField("Notes", text: $notes).focused($field, equals: .notes)
}
.defaultFocus($field, .payee)             // Form is the region root.
```

### 4.4 Known no-op cases

These are documented in Apple's WWDC sessions or community-reported on the Apple Developer Forums:

1. **macOS popover with a focus claimant outside.** The window-key issue described in Section 6.
2. **A parent `.searchable` is focused.** SwiftUI gives the toolbar search field a higher claim than `defaultFocus` (#681962 on Apple's forums).
3. **`defaultFocus` on a `Form` whose first child is a `Picker`/`Menu`** (macOS only, intermittent): the menu trigger is reported as focused first. Workaround: use `.userInitiated` priority and wrap the desired field in an outer focus region that targets it explicitly.
4. **Inside an `.alert`/`.confirmationDialog`.** Alerts ignore focus seeds — only the default button is honoured.
5. **Inside an iOS sheet with `Bool` `@FocusState`** that you assign in `.onAppear` *and* declare `defaultFocus` — they race; the assignment wins on first appearance and `defaultFocus` does nothing on every subsequent re-presentation. Pick one.

---

## 5. The other focus modifiers

### 5.1 `.focusable(_:interactions:)`

Use to make a non-input view participate in focus, typically for a custom card-style row, a focusable image, or a custom picker.

```swift
RecipeTile(...)
    .focusable(true, interactions: .activate)
```

- Use `.activate` when the view is button-like — focus represents "selected target for Space/Return."
- Use `.edit` when the view holds a value that arrow keys/Digital Crown should mutate.
- Use `.automatic` (the default) only on watchOS/tvOS where both senses apply.
- Pair with `@Environment(\.isFocused)` inside the view body to draw a custom focus indicator, and with `.focusEffectDisabled()` to suppress the default ring if you draw your own.

### 5.2 `.focusScope(_:)`

```swift
@Namespace private var formScope
Form { ... }
    .focusScope(formScope)
    .prefersDefaultFocus(true, in: formScope)
```

`focusScope` plus `prefersDefaultFocus(_:in:)` is the older (iOS 14+ / macOS 12+) cousin of `defaultFocus`. On macOS 14+/iOS 17+ prefer `defaultFocus` — it composes better and doesn't require a `Namespace`. `focusScope` still has one use: limiting how far SwiftUI walks looking for a default-focus candidate in deeply nested hierarchies. You will rarely need it in this codebase.

### 5.3 `.focusSection()` (macOS 13+, iOS 17+, tvOS 15+)

Groups focusables into a navigation block. Tab inside the section completes all focusables before leaving it. Required when the natural reading-order tab path is wrong (multi-column layouts, sidebar/detail splits where you want the sidebar to be exhausted first).

```swift
HStack {
    SidebarForm(...)  .focusSection()
    DetailForm(...)   .focusSection()
}
```

It does **not** make non-focusables focusable — it organises existing ones. A section that contains zero focusables is a no-op.

### 5.4 `Environment(\.resetFocus)`

```swift
@Environment(\.resetFocus) private var resetFocus
@Namespace private var ns
...
Button("Reset") { resetFocus(in: ns) }
```

Forces SwiftUI to re-evaluate default focus inside a namespace. Useful when you want to re-honour `defaultFocus` after some structural change (e.g. you swapped sheet contents in place). Rare. Available iOS 15+, macOS 12+, tvOS 15+, watchOS 8+.

### 5.5 `FocusedValue` / `.focusedValue` / `.focusedSceneValue`

Not for input focus — for **threading data from the focused view to a remote consumer** (most importantly menu bar `Commands`). Already covered in `UI_GUIDE.md` Section 13 and `UI_GUIDE.md` Section 14; the rules summarised here:

- `.focusedSceneValue(\.key, value)` publishes a value as long as *any* descendant view of the scene is focused. Use this for menu commands.
- `.focusedValue(\.key, value)` publishes only while a descendant of the modified view is focused. Use for inspector palettes that should change when focus moves between sibling lists.
- Read in `Commands` with `@FocusedValue(\.key)` (always optional) or `@FocusedBinding(\.key)` for `Binding<T>?` keys.

> **Never read a focused value in a view that also writes focused scene values.** Adding a `@FocusedValue(\.key)` *reader* to a view that already publishes `.focusedSceneValue(...)` makes the body depend on focus state the body itself mutates each pass → invalidate → re-body → rewrite → an infinite `UpdateCycle`. The app pegs ~100% CPU forever; under XCUITest it never quiesces, so every test fails at launch ("main window did not appear", an empty accessibility tree in `tree.txt`), while a plain launch just spins invisibly and "looks fine". Thread the action via a closure from the owner instead (e.g. the parent owns the selection and passes `onNavigate: { selection = $0 }`). Reading the value in a `Commands` block (which doesn't publish focused scene values) is fine. Diagnose a suspected render loop with `sample <pid> 2` — the hot stack names the looping `*.body.getter`.

---

## 6. macOS specifics

### 6.1 Full Keyboard Access

macOS distinguishes "controls that always take focus" (text fields, search fields, lists) from "controls that take focus only when full keyboard access is on" (buttons, segmented controls, sliders, custom focusables with `interactions: .activate`). The setting lives in System Settings → Keyboard → Keyboard navigation. **Most users never turn it on.** When testing focus behaviour, toggle it both ways: under the default setting, your `Tab` order will skip every plain button — that is correct macOS behaviour, not a bug.

### 6.2 `.buttonStyle(.plain)` and focus

Confirmed by an Apple Frameworks Engineer on the Apple Developer Forums (thread #683157, October 2022, response to "Activating SwiftUI buttons with a keyboard"):

> "You aren't missing anything, but neither is this an intentional change. We are working on getting parity with NSButton as regards keyboard interactions and the like, but unfortunately this is one case that hasn't been handled yet for custom buttons."

The current behaviour as of macOS 14/15/26:

- A `Button` with `.buttonStyle(.plain)` (or any custom `ButtonStyle`) is **focusable** for tab order.
- It does **not** activate on Space.
- It does **not** activate on Return either, unless you explicitly make it the default with `.keyboardShortcut(.defaultAction)`.
- It **will become the default focus seed** if it appears first in reading order inside a focus region — even when a more semantically-appropriate `TextField` is right below it.

This is the direct cause of the reproducer in Section 10. A plain Cancel button at the top of a popover claims the focus seed.

**Mitigations, in preferred order:**

1. Make the Cancel button **not focusable for default-focus purposes**: `.focusable(false)` on the button. This excludes it from tab order entirely. Only do this when there is another way to dismiss (Escape key handler, click-outside-to-dismiss).
2. Use `.defaultFocus($field, .search, priority: .userInitiated)` to outrank the button in the seed evaluation. This still leaves the button reachable via Tab — usually the right outcome.
3. Reorder the view tree so the desired focus target appears earlier in reading order. Combined with `.focusable(false)` on the visually-leading-but-undesired-as-focus-target button, this is the cleanest fix.

### 6.3 Popover key-window behaviour

A SwiftUI `.popover` on macOS is hosted in an `NSPopover`, which is itself rendered inside a borderless transient `NSWindow` parented to the source window. For a `TextField` inside the popover to become first responder, that child window has to be both *visible* and *key*. SwiftUI calls `makeKeyAndOrderFront(_:)` on the popover's window when the popover is shown, but if:

- the source button is inside a sheet that has open child sheets, or
- the parent window's `.searchable` toolbar field is currently first responder, or
- the popover's behaviour is `.transient` (the SwiftUI default) and the user invoked it via keyboard while another window was key,

the popover may be visible without being key. AppKit silently ignores `makeFirstResponder(_:)` calls on a non-key window, so any `@FocusState` write you do is dropped on the floor.

**Diagnostic.** In the popover's `.task`, log `NSApp.keyWindow` and `NSApp.mainWindow`. If the popover's window is not key, you're in this situation.

**Fix.** Two options that both work in production:

1. **Declarative + reorder + exclude.** Reorder the popover's view tree so the search field is structurally first, mark the Cancel button `.focusable(false)`, and seed with `.defaultFocus($focusedField, .search, priority: .userInitiated)`. SwiftUI takes the popover's window key automatically and the seed lands. This is the correct fix for our reproducer.
2. **Imperative kick after the runloop settles.** If you cannot restructure the tree (vendor view, etc.), add this at the popover root:

   ```swift
   .task {
       // Yield twice: once for SwiftUI to install the view,
       // once for AppKit to make the popover's NSWindow key.
       await Task.yield()
       await Task.yield()
       focusedField = .search
   }
   ```

   This works because each `await Task.yield()` returns control to the run loop and AppKit's pending `becomeKeyWindow` notification completes between yields. It is more fragile than option 1 — Apple has never documented this ordering guarantee — but it is the pattern in widespread community use (Apple Developer Forums #681962). Prefer option 1 when possible.

   `DispatchQueue.main.asyncAfter(deadline: .now() + 0.5)` is the older form of this workaround. Avoid it: it leaks a Task-shaped responsibility into GCD, the 0.5s is a guess that will eventually bite you on slow hardware, and it produces visible focus jitter.

### 6.4 Sheets vs popovers

`.sheet` on macOS hosts a child window with `styleMask = [.titled]` plus its own first responder; AppKit reliably makes the sheet key when it appears. A `defaultFocus` on the sheet's root works without ceremony. This is why `defaultFocus` on `EditAccountView` and `CreateAccountView` (both sheets) "just works" in this codebase, but the same idiom fails inside `InstrumentPickerSheet` when it's presented as a popover on macOS.

### 6.5 Inspector and split views

`NavigationSplitView`'s sidebar, content, and detail are separate focus sections. Tab cycles within the section that has focus. `.inspector(...)` is also a separate section attached to the trailing edge. When you set focus programmatically on a field that lives in the inspector, you don't need to first move focus to the inspector — the assignment moves both the section and the field.

---

## 7. iOS specifics

### 7.1 Hardware keyboards

Since iOS 17, `Tab` from a hardware keyboard cycles focusables in any view hierarchy without extra setup. `.focusable(interactions: .activate)` makes a custom view a tab stop. The focus ring SwiftUI draws on iOS is more subtle than macOS — typically a tinted background. Test with both a paired keyboard and Stage Manager.

### 7.2 Soft keyboard and `Bool`-bound focus

For a single-field sheet (a quick "rename" prompt, an inline editor), the Bool form of `@FocusState` is the most reliable way to get the keyboard to appear immediately:

```swift
@FocusState private var nameFocused: Bool

TextField("Name", text: $name).focused($nameFocused)
    .task { nameFocused = true }
```

`.task` fires after the view is in the window and AppKit-equivalent on iOS has had its layout pass — focus assignment from there is stable and doesn't need a yield. (It does on macOS popovers; see 6.3.)

### 7.3 `.searchable` and focus

Use `.searchFocused(_:)` (iOS 17+, macOS 14+) for the `Bool` form or `.searchFocused(_:equals:)` for the Hashable form. These are the *only* way to programmatically focus or blur a `.searchable` field. A normal `.focused(...)` on the search field's underlying control does nothing.

```swift
@FocusState private var isSearchFocused: Bool

NavigationStack { ... }
    .searchable(text: $query)
    .searchFocused($isSearchFocused)
    .onAppear { isSearchFocused = true }
```

### 7.4 Sheet detents

Detent transitions do not change focus. If you assign focus while the user is dragging between detents, SwiftUI honours the assignment but the focus ring may flicker as the sheet re-lays out. Defer programmatic focus until `.presentationDetentSelection` settles if you see jitter.

---

## 8. Reliable patterns

These are the patterns to copy/paste. They are validated against the codebase and against the cited sources.

### 8.1 Set initial focus when a view appears

```swift
// macOS — sheet or window root
struct EditAccountSheet: View {
    enum Field: Hashable { case name, balance }
    @FocusState private var focusedField: Field?
    @Binding var account: Account

    var body: some View {
        Form {
            TextField("Name", text: $account.name)
                .focused($focusedField, equals: .name)
            TextField("Opening balance", value: $account.balance, format: .currency(code: "USD"))
                .focused($focusedField, equals: .balance)
        }
        .defaultFocus($focusedField, .name)            // sheet root, .automatic priority is fine
    }
}

// macOS — popover root (where automatic priority loses to a sibling button)
struct InstrumentPickerSheet: View {
    enum Field: Hashable { case search }
    @FocusState private var focusedField: Field?

    var body: some View {
        VStack(spacing: 0) {
            searchField                                 // structurally first
            Divider()
            header                                      // Cancel button, marked .focusable(false)
            Divider()
            list
        }
        .defaultFocus($focusedField, .search, priority: .userInitiated)
    }
}

// iOS — single-field sheet using Bool form
struct RenameSheet: View {
    @FocusState private var nameFocused: Bool
    @State private var name = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name).focused($nameFocused)
            }
            .task { nameFocused = true }                 // safe on iOS sheets
        }
    }
}
```

### 8.2 Move focus between siblings on Return / Tab / arrows

Tab is handled for free. Return (Enter on iOS) is `.onSubmit`. Arrow keys require `.onKeyPress` (iOS 17+/macOS 14+).

```swift
TextField("Payee", text: $payee).focused($field, equals: .payee)
    .onSubmit { field = .amount }                       // Return advances
TextField("Amount", text: $amount).focused($field, equals: .amount)
    .onSubmit { field = .notes }
TextField("Notes", text: $notes).focused($field, equals: .notes)
    .onSubmit { field = nil }                           // Return commits

// Arrow-key navigation in a search field over a list:
TextField("Search", text: $query)
    .focused($field, equals: .search)
    .onKeyPress(.downArrow) { highlighted = next(highlighted); return .handled }
    .onKeyPress(.upArrow)   { highlighted = prev(highlighted); return .handled }
```

For a coarser-grained `.onSubmit` over a whole form, use the form-scoped variant:

```swift
Form { ... }
    .onSubmit(of: .text) { advance(focusedField) }
```

### 8.3 Programmatically focus in response to a state change

```swift
.onChange(of: validationError) { _, error in
    if let field = error?.field { focusedField = field }
}
```

`@FocusState` writes are observed and applied on the next runloop turn. If the destination field doesn't exist yet (e.g. the form just expanded a new section), wrap the assignment in a small `Task { @MainActor in ... }` to defer until SwiftUI has reconciled.

### 8.4 Restore focus after a sheet dismisses

SwiftUI does not restore focus across modal containers automatically. Capture the focused field before presenting and re-apply on dismiss:

```swift
@FocusState private var focusedField: Field?
@State private var savedFocus: Field?

Button("Edit details") {
    savedFocus = focusedField
    showSheet = true
}
.sheet(isPresented: $showSheet, onDismiss: {
    focusedField = savedFocus
}) {
    EditDetailsSheet(...)
}
```

### 8.5 Skip a focusable view (Cancel button case)

Three escalating options:

```swift
// 1. Best when the button has another activation path (Escape, click-outside).
Button("Cancel") { dismiss() }
    .focusable(false)

// 2. Available when (1) isn't acceptable but you want default focus elsewhere.
Form { ... }
    .defaultFocus($focusedField, .payee, priority: .userInitiated)

// 3. Last resort: structurally reorder so the undesired focusable is later in tab order.
VStack {
    desiredField   // first in reading order
    cancelButton
}
```

`focusable(false)` on a `Button` does **not** make the button non-clickable — it just removes it from the focus-eligible set. Pointer activation still works.

### 8.6 Push the keyboard down on iOS

```swift
focusedField = nil                                      // single-line / form
// or, for a `TextEditor` in a scroll view:
.scrollDismissesKeyboard(.interactively)
```

### 8.7 Inspect current focus for debugging

```swift
.onChange(of: focusedField) { old, new in
    print("focus: \(String(describing: old)) -> \(String(describing: new))")
}
```

For deeper diagnostics on macOS, you can read AppKit responder state:

```swift
.onAppear {
    print("keyWindow:  \(NSApp.keyWindow as Any)")
    print("firstResp:  \(NSApp.keyWindow?.firstResponder as Any)")
}
```

---

## 9. Anti-patterns

Avoid these. Each one is annotated with the source that explains why.

### 9.1 Multiple parallel `@FocusState<Bool>` properties for separate fields

```swift
// WRONG
@FocusState private var nameFocused: Bool
@FocusState private var amountFocused: Bool
@FocusState private var notesFocused: Bool
```

There is no mutual-exclusion link between them. Setting `nameFocused = true` does not clear `amountFocused`. Use one optional-Hashable enum. Source: Swift with Majid, "Mastering FocusState property wrapper in SwiftUI" (2021-08-24).

### 9.2 `.focusable()` on a built-in input

```swift
// WRONG — produces double focus ring on macOS
TextField("Name", text: $name).focusable()
```

`TextField` is already focusable. The extra modifier wraps an additional focus-eligible AppKit container around the text field. SwiftUI then draws a ring around the wrapper, AppKit draws another inside it, Tab requires two presses to leave the field. Source: Khoa Pham, "How to make TextField focus in SwiftUI for macOS" (2020).

### 9.3 `DispatchQueue.main.asyncAfter` to delay focus

```swift
// WRONG
.onAppear {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        focusedField = .search
    }
}
```

The delay is a guess that papers over the real problem (the focus container isn't key yet). On a slow CI machine the 0.5s isn't enough; on a fast new Mac the user sees a visible focus jump 0.5s after presentation. Use `defaultFocus` with `.userInitiated`, or — when you really must imperative — `Task.yield()` twice, which waits for an event rather than a wall-clock duration. Source: Apple Developer Forums #681962, summary by paulrolfe.

### 9.4 Relying on Space to activate `.buttonStyle(.plain)`

It doesn't work and Apple has acknowledged it as missing parity with `NSButton`. If you need keyboard activation on a custom-styled button, give it `.keyboardShortcut(.defaultAction)` or add a parallel `.onKeyPress(.return)` on a focusable container. Source: Apple Developer Forums #683157, Apple Frameworks Engineer reply (October 2022).

### 9.5 Putting `.defaultFocus` on a view that isn't a focus region root

```swift
// MISLEADING — defaultFocus is at the wrong scope
TextField("Search", text: $query)
    .focused($field, equals: .search)
    .defaultFocus($field, .search)
```

Apply `.defaultFocus` to the **container** (Form, sheet root, popover root). Putting it on the leaf field works for trivial cases but breaks when the field is conditionally rendered or moved.

### 9.6 Using `@FocusState` from a background task

```swift
// WRONG — runtime crash or undefined behaviour
Task.detached {
    field = .search                                     // not on main actor
}
```

`@FocusState` writes are `@MainActor`-isolated. If you start a `Task.detached`, hop back to `@MainActor` before assigning. This becomes harder to spot under Swift 6's strict concurrency — pay attention to compiler warnings.

### 9.7 Trying to programmatically focus a `.searchable` toolbar field with `.focused`

```swift
// WRONG — does nothing; .searchable doesn't expose its inner TextField to FocusState
NavigationStack { ... }
    .searchable(text: $query)
    .focused($field, equals: .search)                   // ignored
```

Use `.searchFocused(_:)` or `.searchFocused(_:equals:)` (iOS 17+, macOS 14+).

### 9.8 Setting initial focus inside `init` or the first `body` evaluation

```swift
// WRONG
init() {
    _focusedField = FocusState<Field?>(wrappedValue: .search)   // doesn't compile
}
var body: some View {
    let _ = (focusedField = .search)                            // silently ignored
    ...
}
```

`@FocusState` cannot be seeded from `init`. A write inside `body` is processed but the destination view does not yet exist in the responder chain on first body evaluation; the assignment is dropped. Use `.defaultFocus`.

### 9.9 Assigning `defaultFocus` to a `Bool` `@FocusState` with the wrong literal

```swift
// WRONG — 'true' here is not the value you bind .focused to.
@FocusState private var isSearchFocused: Bool
TextField(...).focused($isSearchFocused)
    ...
.defaultFocus($isSearchFocused, true, priority: .userInitiated)
```

Actually correct in iOS 17+/macOS 14+, but easy to confuse with the Hashable form. If you're using `Bool`, prefer the Hashable form with a one-case enum — it documents intent ("the search field is the default") rather than a bare `true`.

### 9.10 Hiding or removing a focused view without first clearing focus

```swift
// WRONG — if the active field disappears, SwiftUI may try to refocus a sibling
if showSection {
    TextField("Notes", text: $notes).focused($field, equals: .notes)
}
```

If `showSection` flips from `true` to `false` while `field == .notes`, SwiftUI's behaviour is: clear focus, then look for a fallback. On macOS that fallback is sometimes the next focusable in reading order, which is rarely what you want. Mitigation: clear focus first.

```swift
.onChange(of: showSection) { _, visible in
    if !visible && field == .notes { field = nil }
}
```

---

## 10. The reproducer, with the canonical fix

The view in question, summarised:

```swift
// Caller
Button { isPresented = true } label: { ... }
    .popover(isPresented: $isPresented, arrowEdge: .leading) {
        InstrumentPickerSheet(...)
    }

// Sheet
struct InstrumentPickerSheet: View {
    enum Field: Hashable { case search }
    @FocusState private var focusedField: Field?

    var body: some View {
        VStack(spacing: 0) {
            Header                                       // Button("Cancel").buttonStyle(.plain)
            Divider()
            TextField("Search", text: $query)
                .textFieldStyle(.plain)
                .focused($focusedField, equals: .search)
            Divider()
            List { ... }
        }
        .defaultFocus($focusedField, .search, priority: .userInitiated)
    }
}
```

### 10.1 Root cause

There are **two** problems compounding:

1. **The Cancel button is structurally first in the popover's view tree and is `.buttonStyle(.plain)`.** That button is focusable for tab-order purposes (Section 6.2), and it sits before the search field in reading order. When SwiftUI's focus engine evaluates the popover's region for the first time, both `.search` (via `defaultFocus`) and the Cancel button (via natural reading order) are candidates. With `.userInitiated`, `.search` should win — but it doesn't, because of (2).
2. **The popover's window is not yet key when SwiftUI evaluates focus.** On macOS, `.popover` triggers `NSPopover.show(...)` which posts a `becomeKeyWindow` notification, but SwiftUI's first focus pass for the popover's region runs synchronously off the same body evaluation that produced the popover content. At that moment AppKit hasn't promoted the popover's child window to key yet. Because no window is key for the popover region, SwiftUI walks up to the *parent* window — which still has its own first responder (the parent dialog's TextField, or the sidebar list, etc.) — and concludes the popover region has no business taking focus right now. `defaultFocus` is filed away and never re-evaluated. Then, a moment later, when AppKit makes the popover key, AppKit's own first-responder-resolution kicks in and picks the structurally-first focusable view it can find: the Cancel button.

(1) without (2) is annoying but `defaultFocus(..., priority: .userInitiated)` would handle it. (2) is what makes the seed silently no-op.

### 10.2 The fix

Apply both halves:

```swift
struct InstrumentPickerSheet: View {
    enum Field: Hashable { case search }
    @FocusState private var focusedField: Field?

    var body: some View {
        VStack(spacing: 0) {
            // 1. Search field FIRST in the view tree so reading-order tab
            //    walks into it before the Cancel button. Cancel stays
            //    visually at the top; SwiftUI's focus engine works on the
            //    declarative tree, not the rendered layout.
            macOSSearchField

            Divider()

            macOSHeader                                  // contains Cancel

            Divider()
            listContent
        }
        .defaultFocus($focusedField, .search, priority: .userInitiated)
    }

    private var macOSHeader: some View {
        HStack {
            Text("Choose currency").font(.headline)
            Spacer()
            Button("Cancel") { isPresented = false }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                // 2. Remove Cancel from the focus-eligible set so it
                //    cannot intercept default focus or Tab. It remains
                //    pointer-clickable, and Escape still dismisses via
                //    .onKeyPress in the search field.
                .focusable(false)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var macOSSearchField: some View {
        TextField("Search", text: $query)
            .textFieldStyle(.plain)
            .focused($focusedField, equals: .search)
            .onKeyPress(.escape) { isPresented = false; return .handled }
    }
}
```

What changes:

- The TextField is structurally first. AppKit's "first responder when key is granted" walk picks the search field, not the Cancel button.
- `.focusable(false)` on Cancel makes it ineligible for that walk regardless of tree order — defence in depth, and means that future contributors can re-order the view without re-introducing the bug.
- `defaultFocus(..., priority: .userInitiated)` remains as documentation of intent and as the seed for any iOS code path that adapts the popover to a sheet. On macOS it is now redundant in the happy path but harmless.
- The `.task { focusedField = .search }` and `.task { await Task.yield(); focusedField = .search }` workarounds are not needed and should not be added. Both are imperative escape hatches that mask the real problem; with the structural fix the popover's window claims first responder on the search field naturally.

### 10.3 If you cannot reorder the tree

If you maintain a vendor view or are otherwise locked out of structural changes, the imperative fallback is:

```swift
.task {
    await Task.yield()                                  // let SwiftUI install
    await Task.yield()                                  // let AppKit make popover key
    focusedField = .search
}
```

Two yields, not one — the first lets SwiftUI complete the body that produced the popover content, the second lets AppKit's `becomeKeyWindow` notification be processed. This is brittle (Apple has never documented this run-loop ordering), but is the pattern in widespread use on the Apple Developer Forums for the same symptom. Treat it as last-resort.

---

## 11. Quick reference

| Task | Use |
|---|---|
| Make a `TextField` the initial focus on a sheet/window appear | `.defaultFocus($field, .target)` on the sheet root |
| Make a `TextField` the initial focus on a macOS popover | Reorder tree + `.focusable(false)` on competing buttons + `.defaultFocus($field, .target, priority: .userInitiated)`; see Section 10 |
| Move focus on Return | `.onSubmit { field = .next }` per field, or `.onSubmit(of: .text) { ... }` on the form |
| Move focus on arrow keys | `.onKeyPress(.downArrow) { ...; return .handled }` (iOS 17+/macOS 14+) |
| Programmatically focus in response to state | Assign `field = .target` from `.onChange` on `@MainActor` |
| Dismiss the soft keyboard (iOS) | `field = nil` |
| Restore focus after a sheet dismisses | Snapshot before present, reapply in `.sheet(onDismiss:)` |
| Skip a focusable view in tab order | `.focusable(false)` on it |
| Group focusables so Tab walks columns | `.focusSection()` (macOS 13+/iOS 17+) on each column |
| Custom focusable view | `.focusable(true, interactions: .activate)`; read `@Environment(\.isFocused)` |
| Suppress the default focus ring | `.focusEffectDisabled()` |
| Focus the `.searchable` field | `.searchFocused($bool)` or `.searchFocused($value, equals:)` (iOS 17+/macOS 14+) |
| Re-evaluate `defaultFocus` mid-life | `@Environment(\.resetFocus)` + a `@Namespace` |
| Wire a focused selection to a menu command | `.focusedSceneValue(\.key, value)` + `@FocusedValue(\.key)` in `Commands` |
| Limit `prefersDefaultFocus` to a subtree | `.focusScope(namespace)` (rarely needed on macOS/iOS 14+) |
| Diagnose "focus didn't go where I expected" on macOS | `print(NSApp.keyWindow?.firstResponder)` from `.onAppear` |

---

## 12. Sources

Primary (Apple):

- WWDC23 #10162 — "The SwiftUI cookbook for focus." The single best summary; covers focusable, FocusState, focus sections, focused values, and the Hashable-optional pattern. https://developer.apple.com/videos/play/wwdc2023/10162/
- WWDC21 #10023 — "Direct and reflect focus in SwiftUI." The original FocusState/focused() introduction. https://developer.apple.com/videos/play/wwdc2021/10023/
- Apple Developer Documentation — `FocusState`, `defaultFocus(_:_:priority:)`, `DefaultFocusEvaluationPriority`, `prefersDefaultFocus(_:in:)`, `focusable(_:interactions:)`, `focusScope(_:)`, `focusSection()`, `searchFocused(_:)`, `searchFocused(_:equals:)`, `popover(isPresented:attachmentAnchor:arrowEdge:content:)`, `presentationCompactAdaptation(horizontal:vertical:)`. https://developer.apple.com/documentation/swiftui/
- Apple Developer Forums #683157 — "Activating SwiftUI buttons with a keyboard." Apple Frameworks Engineer reply confirming `.buttonStyle(.plain)` does not respond to Space. https://developer.apple.com/forums/thread/683157
- Apple Developer Forums #681962 — "SwiftUI default focus on TextField." The community thread documenting the popover/sheet timing problem and the `Task`/delay workarounds. https://developer.apple.com/forums/thread/681962
- Apple Developer Forums #726209 — "Help with SwiftUI macOS focus (keyboard navigation)." Documents `NavigationSplitView` Tab behaviour with `AsyncImage`. https://developer.apple.com/forums/thread/726209
- AppKit `NSPopover` documentation — behaviour types `.transient`/`.semitransient`/`.applicationDefined`. https://developer.apple.com/documentation/appkit/nspopover
- AppKit `NSWindow.canBecomeKey` documentation — why a popover's child window must answer `true` for embedded text fields to take first responder. https://developer.apple.com/documentation/appkit/nswindow/1419543-canbecomekey

Community (cited where Apple's docs are silent):

- Brent Simmons — NetNewsWire (https://github.com/Ranchero-Software/NetNewsWire) is treated as the gold-standard Mac Swift exemplar in this codebase. Its Mac sources show the consistent pattern of one focus enum per form, default focus seeded on the form root, and explicit `.onSubmit` advancement.
- Swift with Majid — "Focus management in SwiftUI" (2020-12-02) and "Mastering @FocusState property wrapper in SwiftUI" (2021-08-24). https://swiftwithmajid.com/2020/12/02/focus-management-in-swiftui/, https://swiftwithmajid.com/2021/08/24/mastering-focusstate-property-wrapper-in-swiftui/
- Khoa Pham — "How to make TextField focus in SwiftUI for macOS" (https://github.com/onmyway133/blog/issues/620), the canonical reference for `NSWindow.canBecomeKey` overrides when wrapping SwiftUI in a custom window.
- Frank Rausch — Swift port of Wil Shipley's NSPopover/NSTextField first-responder fix (https://gist.github.com/frankrausch/d4b5c6d5f86e5c3c9fcec9bcf0ccef37). Useful background on why popovers historically struggle with text input focus.
- Fatbobman — "SwiftUI TextField Advanced — Events, Focus, and Keyboard." Detailed `@FocusState` patterns including `searchFocused`. https://fatbobman.com/en/posts/textfield-event-focus-keyboard/
- Hacking with Swift — "How to make a TextField or TextEditor have default focus." Paul Hudson's introduction to the problem space. https://www.hackingwithswift.com/quick-start/swiftui/how-to-make-a-textfield-or-texteditor-have-default-focus
- Apple Developer Forums #129602 — Custom `ButtonStyle` and the focus ring; clarifies that `.focusEffectDisabled` (or a custom style) is required to suppress the default ring. https://developer.apple.com/forums/thread/129602
- Hacking with Swift Forums — ".searchable and managing focus" (https://www.hackingwithswift.com/forums/swiftui/searchable-and-managing-focus/23160) — confirms `.focused` does not bind to a `.searchable` field; you need `.searchFocused`.

---

## Version History

- **1.0** (2026-04-26): Initial focus guide. Mental model; focus model (focusable views, container, region, scope, section); `@FocusState` semantics; `.focused` (Bool vs Hashable); `.defaultFocus` including `DefaultFocusEvaluationPriority` cases and known no-op cases; the rest of the focus modifier family; macOS specifics (Full Keyboard Access, plain button style, popover key-window behaviour, sheets vs popovers, split views/inspector); iOS specifics (hardware keyboard, soft keyboard, `.searchable`, sheet detents); reliable patterns; anti-patterns; full root-cause and canonical fix for the `InstrumentPickerSheet` popover reproducer; quick reference table; sources.
