# Moolah Swift Code Guide

**Version:** 1.0
**Platform targets:** macOS 26+ (primary), iOS 26+ (secondary)
**Status:** Mandatory. All Swift code in this repository must follow this guide.

This guide covers general Swift code style. It is a peer to the existing specialised guides:

- `guides/CONCURRENCY_GUIDE.md` — actors, `Sendable`, `Task` hygiene, async patterns.
- `guides/UI_GUIDE.md` — SwiftUI layout, colours, typography, HIG.
- `guides/TEST_GUIDE.md` / `guides/UI_TEST_GUIDE.md` — test structure, fixtures, drivers.
- `guides/SYNC_GUIDE.md` — CKSyncEngine, change tracking.
- `guides/INSTRUMENT_CONVERSION_GUIDE.md` — currency conversion correctness.
- `guides/BENCHMARKING_GUIDE.md` — signpost and benchmark patterns.

Where another guide owns a topic, this one defers rather than duplicates.

---

## 1. Philosophy

Simplicity beats cleverness. Readable code that a future maintainer can follow in one pass is worth more than a clever abstraction that saves a few lines today.

[Apple's Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/) are the canonical reference for naming and API shape — when this guide and Apple's disagree, Apple wins and this guide is the bug. NetNewsWire's [CodingGuidelines.md](https://github.com/Ranchero-Software/NetNewsWire/blob/main/Technotes/CodingGuidelines.md) is our stylistic exemplar:

> "Solve the problem. Not less than the problem, but not more than the problem — don't over-generalize."
> — [NetNewsWire CodingGuidelines.md](https://github.com/Ranchero-Software/NetNewsWire/blob/main/Technotes/CodingGuidelines.md)

This guide is a rule set, not a tutorial. When a topic is richer than a rule — protocol-oriented programming, value-type design, concurrency — follow the citation to the primary source.

---

## 2. File Organization

- **One primary type per file.** Filename matches the primary type exactly (`AccountStore.swift` contains `AccountStore`). SwiftLint's [`file_name`](https://realm.github.io/SwiftLint/file_name.html) rule enforces this.
- **Exceptions:**
  - DTO families — closely-related `Codable` request/response structs may share a file when they exist only to serialise a single endpoint.
  - Delegate protocols — a single-consumer delegate protocol lives with its delegator.
- **Delegate ordering.** When a delegate protocol is co-located with its delegator, the **protocol is declared before the delegator**. Reading top-to-bottom, the protocol is established before any code that references it. See [NetNewsWire CodingGuidelines.md](https://github.com/Ranchero-Software/NetNewsWire/blob/main/Technotes/CodingGuidelines.md) §Delegates.
- **Conformance lives in an extension. One protocol per extension — for non-trivial conformances.** A conformance is *trivial* when it is satisfied entirely by the compiler-synthesised implementation and adds no members: `Sendable`, `Codable`, `Equatable`, `Hashable`, and `Identifiable` *when `id` is an existing stored property* (no hand-written `id`, `==`, `hash(into:)`, `encode`/`init(from:)`, or `CodingKeys`). Trivial conformances **may** be declared inline on the primary declaration of a small value type (`struct Foo: Codable, Sendable, Hashable`) — this matches the established `Domain/Models/` norm (e.g. `Category`) and keeps tiny data types readable. Any **non-trivial** conformance (one that requires a real implementation, computed members, or a custom `CodingKeys`) lives in its **own** `extension`, one protocol per extension, never combined. A type that has *any* non-trivial conformance puts *all* of its conformances in separate extensions (don't mix inline + extension on one type). `*Row`/backend and reference types follow the separate-extension form regardless, since their conformances are rarely trivial.
- **Trailing `private extension Self`** for file-private helpers — groups helpers at the end of the file rather than scattering `private func` throughout the type.
- **`// MARK: - Section Name`** for sections in files longer than 300 lines. Below that threshold, headings add noise without orientation value.

```swift
// Good: primary type, then one extension per conformance, then private helpers.
final class AccountStore {
    // stored properties, initializer, primary API
}

extension AccountStore: Identifiable { /* ... */ }
extension AccountStore: CustomStringConvertible { /* ... */ }

private extension AccountStore {
    func normalise(_ name: String) -> String { /* ... */ }
}
```

```swift
// Bad: inline non-trivial conformances + combined extension.
final class AccountStore: Identifiable, CustomStringConvertible { /* ... */ }
extension AccountStore: Equatable, Hashable { /* ... */ }
```

```swift
// OK: trivially-synthesised conformances are declared inline...
struct TransferSuggestion: Sendable, Identifiable, Hashable {
    let id: UUID
    let transactionIds: Set<UUID>
    let suggestedAt: Date
}

// ...while a non-trivial conformance (custom CodingKeys / init(from:)
// — here `id` is content-addressed and excluded from the wire form)
// lives in its own extension.
extension TransferSuggestion: Codable { /* custom CodingKeys + init(from:) */ }
```

---

## 3. File Size Thresholds

Thresholds below are [SwiftLint](https://realm.github.io/SwiftLint/rule-directory.html) defaults; they reflect community consensus and are enforced by CI.

| Metric                  | Warn   | Error  | Rule                                                                            |
| ----------------------- | ------ | ------ | ------------------------------------------------------------------------------- |
| File length             | 400    | 1000   | [`file_length`](https://realm.github.io/SwiftLint/file_length.html)             |
| Type body length        | 250    | 350    | [`type_body_length`](https://realm.github.io/SwiftLint/type_body_length.html)   |
| Function body length    | 50     | 100    | [`function_body_length`](https://realm.github.io/SwiftLint/function_body_length.html) |
| Cyclomatic complexity   | 10     | 20     | [`cyclomatic_complexity`](https://realm.github.io/SwiftLint/cyclomatic_complexity.html) |
| Nesting (type)          | 1      | —      | [`nesting`](https://realm.github.io/SwiftLint/nesting.html)                     |
| Nesting (function)      | 2      | —      | [`nesting`](https://realm.github.io/SwiftLint/nesting.html)                     |
| Line length             | —      | 100    | `swift-format` (authoritative)                                                  |
| Identifier length       | 3–40   | 2–60   | [`identifier_name`](https://realm.github.io/SwiftLint/identifier_name.html)     |
| Large-tuple elements    | 2      | 3      | [`large_tuple`](https://realm.github.io/SwiftLint/large_tuple.html)             |

**Exemptions:**

- Tests (`MoolahTests/**`, `MoolahUITests_macOS/**`) are exempt from file-length and function-length limits. Test readability benefits from longer, linear scenarios.
- A production file that legitimately exceeds a threshold (e.g. an exhaustive switch over a closed protocol) may opt out with a per-rule annotation explaining why:

```swift
// swiftlint:disable:this file_length
// Exhaustive dispatch over Transaction.Kind — splitting would fragment a single decision surface.
```

Prefer refactoring over suppression. Suppressions need a reason comment; anonymous suppressions will be rejected in review.

The reason MUST live on its own line (as above). Do not append it to the disable directive with an em-dash or other separator:

```swift
// swiftlint:disable:next force_try — fallback cannot fail in a tmp dir
```

SwiftLint parses every whitespace-separated token after the directive as a rule identifier, so words in an inline reason (`in`, `a`, `tmp`, `fallback`, etc.) produce a cascade of [`superfluous_disable_command`](https://realm.github.io/SwiftLint/superfluous_disable_command.html) violations. Put the directive on one line and the reason on the line above or below.

---

## 4. Naming

Apple's [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/) are the canonical reference. The rules below are a working subset; when in doubt consult the source.

- **Clarity at use site.** Every word in a name should convey salient information at the point the API is called. Read your call sites before committing.
- **Omit needless words.** If the type makes the word redundant, drop it.

  ```swift
  allViews.remove(cancelButton)   // Not: allViews.removeElement(cancelButton)
  ```

- **Name per role, not type.** Variable names describe what a value is, not what Swift type holds it.

  ```swift
  var greeting = "Hello"   // Not: var string = "Hello"
  ```

- **Preposition labels for phrases.** Argument labels turn the call site into a readable phrase.

  ```swift
  x.removeBoxes(havingLength: 12)
  a.moveTo(x: 10, y: 20)
  ```

- **Side-effect grammar.** Functions without side effects read as noun phrases; mutating functions read as imperative verbs.

  ```swift
  // No side effects — noun phrase, the -ed/-ing pair
  let sorted = list.sorted()
  let distance = x.distance(to: y)

  // Side effects — imperative verb
  list.sort()
  list.append(item)
  ```

  Pair naming: use `-ed` when grammatical (`sort` / `sorted`), `-ing` when the verb takes a direct object (`strip(_:)` / `stripping(_:)`).

- **Boolean assertions.** Boolean properties and methods read as assertions.

  ```swift
  if list.isEmpty { /* ... */ }
  if line1.intersects(line2) { /* ... */ }
  // Not: list.checkEmpty(), line1.getIntersection(with: line2) as a Bool
  ```

- **Factory methods start with `make`.**

  ```swift
  let iterator = collection.makeIterator()
  ```

- **Uniform acronym casing.** Acronyms are uniformly upper- or lowercase depending on position.

  ```swift
  final class URLFinder { /* ... */ }
  var htmlBodyContent: String
  var profileID: UUID
  ```

- **Avoid type-suffix in properties.** Let the containing type carry the context.

  ```swift
  user.name        // Not: user.userName
  account.balance  // Not: account.accountBalance
  ```

- **Type names are UpperCamelCase, 3–40 characters.** Classes, structs, enums, protocols, actors, and type aliases use UpperCamelCase with no underscores or digits used as separators, and fit inside the 3-character minimum / 40-character warning range. SwiftLint's [`type_name`](https://realm.github.io/SwiftLint/type_name.html) rule enforces this — if a name wants to go longer, the type is almost always doing too much and should be split. Test types are not exempt: a test suite named `TransactionIsSimpleCrossCurrencyTransferTests` is a signal that the scenario wants its own helper fixture or a more focused `…Tests` file, not a longer identifier.

- **Nest types at most one level deep.** SwiftLint's [`nesting`](https://realm.github.io/SwiftLint/nesting.html) rule caps type nesting at 1 level (and function nesting at 2). A single namespacing enum like `UITestIdentifiers.Sidebar` is the intended use — a second layer (`UITestIdentifiers.Detail.Leg`) is the signal to promote the inner type to a peer or to a top-level type in its own file. Prefer a flat namespace with descriptive compound names (`DetailLegIdentifiers`) or a sibling enum under the same parent over stacking enums to get a shorter call-site name. If a grouping truly needs two levels, that almost always means the parent is doing two jobs and wants to split.

### 4.1 Project suffix conventions

- **OK as needed:** `Controller`, `ViewController`, `Delegate`, `Store` (the `@Observable` owner of UI-bound state).
- **Use sparingly:** `Manager`. NetNewsWire has 7 of these across ~92k lines — that's a useful ceiling. Most types called `Manager` are really `Store`, `Service`, or a noun specific to the domain.
- **Avoid as a container name:** `Helper`, `Utility`, `Factory`. If a type has no stronger identity than "utility," its functions probably belong as extensions on the domain type they operate on, or as free functions in `Shared/`.

---

## 5. Types — value vs reference

Apple's [Choosing Between Structures and Classes](https://developer.apple.com/documentation/swift/choosing-between-structures-and-classes) is the canonical decision guide.

- **`struct` is the default for data.** Value semantics eliminate shared-mutable-state bugs and make types trivially `Sendable`.
- **Prefer a named `struct` over a tuple with three or more elements.** Two-element tuples (e.g. `(Date, Amount)`) are fine locally; once a third field appears, field names at the call site stop being optional and a `struct` makes that explicit. Enforced by [`large_tuple`](https://realm.github.io/SwiftLint/large_tuple.html) (warn at 2, error at 3) — see §3. Scope the struct as narrowly as the use site allows (file-private helpers for single-file aggregations; sibling types when several files share the shape).
- **`class` only for:**
  - Identity-driven state (two equal values are not interchangeable).
  - Shared mutable state with deliberately controlled access.
  - Objective-C interop.
- **`final class` always.** Inheritance costs more than it delivers for most app code. NetNewsWire shows 253 `final class` vs 12 bare `class` across 92k lines ([CodingGuidelines.md](https://github.com/Ranchero-Software/NetNewsWire/blob/main/Technotes/CodingGuidelines.md)). Non-`final` is the exception and needs a justification in review.
- **`enum` for closed sets of cases.** Exhaustive `switch` catches missed cases at compile time.
- **`indirect enum` for recursive types** (expression trees, linked structures).
- **Case-less `enum` for pure namespaces.** A type that only groups static members (or nested types, as in our `@Suite` contract-test aggregators) should be a case-less `enum`, not a `struct` / `class` / `final class`. The `enum` has no cases, so it can't be instantiated — the compiler enforces the "namespace only" intent that a `struct` would merely document. Enforced by [`convenience_type`](https://realm.github.io/SwiftLint/convenience_type.html).

  ```swift
  enum CurrencyFormat {                          // Good
    static let maxFractionDigits = 2
    static func parseCents(from text: String) -> Int? { … }
  }

  struct CurrencyFormat {                        // Bad — use a case-less enum
    static let maxFractionDigits = 2
    static func parseCents(from text: String) -> Int? { … }
  }
  ```

- **`actor`** — defer to `guides/CONCURRENCY_GUIDE.md`. Actors exist for concurrency isolation, not for general "reference-type-with-extras" needs.

---

## 6. Protocol Design

- **Small, focused protocols.** A protocol describes an "is-a" or "can-do." If it bundles many abilities, split it — callers can conform to what they need.
- **Conformance via `extension`** (cross-ref §2). One protocol per extension.
- **Prefer primary-associated-type protocols + generics** when the call site wants static dispatch and the concrete type matters.

  ```swift
  protocol Repository<Entity> {
      associatedtype Entity: Identifiable & Sendable
      func fetchAll() async throws -> [Entity]
  }

  func loadAndDisplay<R: Repository>(_ repository: R) async { /* ... */ }
  ```

- **`any P` is mandatory spelling** in Swift 6 — see [SE-0335](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0335-existential-any.md). Reserve `any P` for:
  - Heterogeneous storage — `[any Animal]`.
  - True type erasure where callers genuinely don't know or care about the concrete type.
- **Prefer `some P`** for return types that don't need to be heterogeneous. It opts into opaque-result-type optimisations and keeps the call site generic.

---

## 7. Access Control

- **Language default is `internal`.** Don't write `internal` explicitly — it's noise.
- **Prefer `private`** for members. Smaller surface area = fewer coupling paths.
- **`fileprivate` only when the compiler requires it.** The project's `.swift-format` `fileScopedDeclarationPrivacy` rule handles the common case of file-scoped declarations automatically; reach for `fileprivate` manually only when an extension in the same file needs access that `private` blocks. SwiftLint's `strict_fileprivate` rule enforces this — if an extension of the same type sits in the same file, the member should be `private`, not `fileprivate` (Swift's `private` already reaches same-file same-type extensions). Use `internal` (the language default, written by omitting the keyword) when a sibling extension in a different file needs access.
- **`public` only at module boundaries.** This project has effectively one module boundary today: `Domain/`. Inside the app target, everything is `internal` or tighter; writing `public` anywhere else is almost certainly wrong.

---

## 8. Error Handling

- **Prefer `throws` over `Result`.** `async throws` composes with structured concurrency; `Result` fights it. See `guides/CONCURRENCY_GUIDE.md` for async throw patterns.
- **Do not reach for typed throws `throws(E)` as a default.** [SE-0413](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0413-typed-throws.md) is explicit:

  > "The existing (untyped) `throws` remains the better default error-handling mechanism for most Swift code."
  > — [SE-0413](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0413-typed-throws.md)

  Typed throws is reserved for:
  - Module-internal code where every call site handles every case.
  - Generic rethrowing plumbing (`Task`, `Result.map`).
  - Embedded Swift.

- **No silent `try?`.** Either handle the error, log it, or let it bubble up. Swallowing errors hides bugs.
- **Stores catch and surface, repositories throw.** The project's store pattern (see `CLAUDE.md` "Thin Views, Testable Stores") catches repository errors, formats them for display, and restores prior state on failure. Views don't do `try?`.
- **Rollback on failure.** When a store mutates optimistic state, it must save prior state and restore it if the repository call fails. See `guides/CONCURRENCY_GUIDE.md` §5 for the pattern.

---

## 9. Optionals

- **Use shorthand `if let x`, `guard let x`.**

  ```swift
  if let user { render(user) }
  guard let account else { return }
  ```

- **`??` for defaults.**

  ```swift
  let name = user.displayName ?? "Guest"
  ```

- **No force-unwrap, force-try, or `as!` in production.** SwiftLint enforces [`force_unwrapping`](https://realm.github.io/SwiftLint/force_unwrapping.html), [`force_try`](https://realm.github.io/SwiftLint/force_try.html), [`force_cast`](https://realm.github.io/SwiftLint/force_cast.html) as warnings in production paths.
- **Replace `as!` with `guard let … as?` + an explicit failure.** The fix is not to swap the trap for a different trap — it's to surface *why* the cast is expected to succeed. For benchmarks and integration harnesses the right escape hatch is `guard let typed = value as? TargetType else { fatalError("context: got \(type(of: value))") }`; the type name in the message is what makes a future backend swap debuggable instead of cryptic. For tests, extract the value and unwrap via `#require` (Swift Testing) or `XCTUnwrap` (XCTest) so the shape mismatch reads as a test failure rather than a crash. SwiftLint's [`force_cast`](https://realm.github.io/SwiftLint/force_cast.html) rule catches the raw `as!` form; the preferred replacements above both pass the rule and produce better failure output.
- **In tests:** force operations are allowed but prefer `#require` / `XCTUnwrap` and explicit `try` — they produce better failure messages and fail the test cleanly instead of crashing the suite.
- **No implicitly unwrapped optionals** outside the rare IBOutlet case. This is a SwiftUI-only codebase; the exception effectively never applies.

---

## 10. Initializers

- **Use the synthesized memberwise init** for data types. Don't hand-write an init that matches the synthesized one.
- **Custom init only to maintain invariants** — validation, derived fields, normalisation.

  ```swift
  struct Username {
      let value: String

      init?(_ raw: String) {
          let trimmed = raw.trimmingCharacters(in: .whitespaces)
          guard !trimmed.isEmpty else { return nil }
          self.value = trimmed
      }
  }
  ```

- **Complex construction → `static func make(…) -> Self` factories.** Keeps the primary init simple and names the construction pattern explicitly.

---

## 11. Extensions

- **One extension per protocol conformance.**

  ```swift
  extension Foo: Bar { /* ... */ }
  extension Foo: Baz { /* ... */ }
  // Not: extension Foo: Bar, Baz { ... }
  ```

- **Trailing `private extension Self`** for file-private helpers (cross-ref §2).
- **Avoid extending Foundation / standard-library types in feature code.** Extensions leak across the module — a `String` extension in `Features/Transactions/` is visible everywhere. If an extension is genuinely useful across the repo and is generic (`Collection`, `Sequence`), put it in `Shared/` with a test.

---

## 12. Generics & Opaque Types

- **Prefer `some P` for returns** where ergonomics allow — lets the compiler optimise and avoids existentials.
- **Reach for generics** when the call site cares about the concrete type (so the compiler can specialise).
- **Type erasure (`AnyFoo`) only when necessary.** Heterogeneous collection storage is the common legitimate case. Otherwise, generics and `some P` are cheaper.

---

## 13. Closures

- **Trailing closure for the last closure argument.**

  ```swift
  items.first { $0.isActive }
  ```

- **`[weak self]` only when capturing a reference type with a plausible retain cycle.** SwiftUI views are value types — they don't need `[weak self]`. A `Task { }` inside a `@MainActor` store method capturing the store itself does need it when the store's lifetime is shorter than the task.
- **Explicit `[self]` captures when semantics matter.** Swift 5.8 requires `self.` inside escaping closures only for non-`@Sendable` contexts; be explicit when the capture list communicates intent, even when the compiler doesn't demand it.
- **Closure parameter list stays on the opening-brace line.** Enforced by [`closure_parameter_position`](https://realm.github.io/SwiftLint/closure_parameter_position.html). swift-format will happily wrap a long call-site before the trailing `{`, so if the invocation pushes the `{ params in` past the column limit the fix is to shorten the call (extract an arg to a local, rename a verbose identifier), not to drop the params onto their own line.

  ```swift
  // Good
  coordinator.addObserver(for: profileId) { [weak self] changedTypes in
    self?.scheduleReloadFromSync(changedTypes: changedTypes)
  }

  // Bad — params wrapped onto the next line
  coordinator.addObserver(for: profileId) {
    [weak self] changedTypes in
    self?.scheduleReloadFromSync(changedTypes: changedTypes)
  }
  ```

---

## 14. Collection Idioms

SwiftLint enforces most of these via opt-in rules; follow them by habit.

- **`first(where:)` over `filter { }.first`** — avoids allocating an intermediate array.

  ```swift
  let payment = transactions.first { $0.kind == .payment }   // Good
  let payment = transactions.filter { $0.kind == .payment }.first   // Bad
  ```

- **`contains(where:)` over iterating.**

  ```swift
  if transactions.contains(where: { $0.isPending }) { /* ... */ }
  ```

- **`isEmpty` over `count == 0` / `count != 0`** — works in O(1) for collections where `count` is O(n) (e.g. lazy sequences).
- **`reduce(into:)` over `reduce`** for accumulation into a mutable result — avoids copying the accumulator on each step.

  ```swift
  let byKind = transactions.reduce(into: [Transaction.Kind: Int]()) { counts, tx in
      counts[tx.kind, default: 0] += 1
  }
  ```

- **`for … in` over `forEach`** for side effects. `forEach` hides control flow — you can't `break`, `continue`, or `return` from the enclosing function. Use `forEach` only for pure-call chains where control flow isn't relevant.
- **Don't reach for `.enumerated()` unless you need the index.** SwiftLint's [`unused_enumerated`](https://realm.github.io/SwiftLint/unused_enumerated.html) rule flags `for (_, element) in sequence.enumerated()` — drop the `.enumerated()` and iterate the sequence directly. If you only need the offset for a SwiftUI `ForEach`'s `id:`, prefer giving the element a stable identity (conform to `Identifiable` or key by a domain-unique property) over `Array(…​.enumerated())` + `\.offset`, which re-orders animations on insertion and hides the real identity of the row.

  ```swift
  for leg in transaction.legs { … }                     // Good
  for (_, leg) in transaction.legs.enumerated() { … }   // Bad — use the sequence directly
  for (index, leg) in transaction.legs.enumerated() { … }   // OK — index is used
  ```

- **`isMultiple(of:)` over `% == 0` for divisibility checks.** `BinaryInteger.isMultiple(of:)` reads as the intent ("is `i` a multiple of `N`") and survives a `0` divisor (`x.isMultiple(of: 0)` is `true` only when `x == 0`, not a trap). Keep `%` for actual remainder arithmetic (e.g. `i % earmarkIds.count` as an index wrap). Enforced by [`legacy_multiple`](https://realm.github.io/SwiftLint/legacy_multiple.html).

  ```swift
  if index.isMultiple(of: 100) { /* Good */ }
  if index % 100 == 0 { /* Bad */ }
  ```

- **`Array(sequence)` over `sequence.map { $0 }` to materialize a sequence.** The identity-closure `map` is a disguised conversion that allocates and iterates without communicating intent; the `Array` initializer names exactly what's happening. Enforced by [`array_init`](https://realm.github.io/SwiftLint/array_init.html).

  ```swift
  let ids = Array(transaction.legs.lazy.map(\.id))   // Good — `map` is doing real work
  let legs = Array(transaction.legs)                 // Good — just materializing
  let legs = transaction.legs.map { $0 }             // Bad — use `Array(…)`
  ```

- **`min()` / `max()` over `sorted().first` / `sorted().last`.** Sorting to pick a single extreme value is O(n log n) and allocates; `min()` / `max()` do it in O(n) without the intermediate array. Use the closure-taking overloads (`min(by:)`, `max(by:)`) when the ordering key is non-default. Enforced by [`sorted_first_last`](https://realm.github.io/SwiftLint/sorted_first_last.html).

  ```swift
  let earliest = transactions.min(by: { $0.date < $1.date })   // Good
  let latest = prices.max()                                    // Good
  let earliest = transactions.sorted { $0.date < $1.date }.first   // Bad — use `min(by:)`
  ```

- **`isEmpty` over `== []` / `== [:]` literal comparison.** Comparing a collection to an empty literal forces `Equatable` element-wise equality on an empty shape and reads as a value test; `isEmpty` names the intent and is O(1) on every standard collection. Applies to arrays, dictionaries, sets, and strings (`== ""`). Enforced by [`empty_collection_literal`](https://realm.github.io/SwiftLint/empty_collection_literal.html).

  ```swift
  if transactions.isEmpty { /* Good */ }
  if lookup.isEmpty { /* Good */ }
  if transactions == [] { /* Bad — use `isEmpty` */ }
  if lookup == [:] { /* Bad — use `isEmpty` */ }
  ```

---

## 15. Control Flow

- **`switch` for closed sets.** Exhaustive switches catch new cases at compile time; `if/else` chains don't.
- **`guard` for early exit** when the happy path is the long branch. Inverted conditions in an `if` with a long body are harder to read.

  ```swift
  guard let account = accounts[id] else { return }
  // happy path continues at top level
  ```

- **More than 3 levels of nesting → extract a function.** SwiftLint's [`nesting`](https://realm.github.io/SwiftLint/nesting.html) rule warns past function-level 2, but readability degrades well before the warning. Extract early.
- **Use `for … where` instead of `for … { if … }`** when the whole loop body is guarded by a single condition. Enforced by [`for_where`](https://realm.github.io/SwiftLint/for_where.html). The `where` clause reads as part of the iteration contract ("for every X that matches P …") and drops one level of nesting from the body.

  ```swift
  // Good
  for cachedDate in sortedDates where cachedDate <= dateString {
    return cache.prices[cachedDate]
  }

  // Bad — the inner `if` wraps the entire body
  for cachedDate in sortedDates {
    if cachedDate <= dateString {
      return cache.prices[cachedDate]
    }
  }
  ```

  Only applies when the `if` wraps the entire loop body. A loop that does meaningful work before or after a conditional branch should keep the `if` — moving a partial guard into `where` would change the loop's shape.

---

## 16. Currency & Sign Convention

Cross-references — these rules are normative and live in `CLAUDE.md`:

- **`Int` cents are the canonical representation.** All monetary values are stored as integer cents. See `CLAUDE.md` "Currency" section.
- **Preserve the sign** of monetary amounts. Expenses are typically negative, but a refund is an expense with a positive value — any transaction type may carry the opposite sign to its norm. **Do not use `abs()`** or otherwise discard the sign. Display logic must handle both signs correctly. See `CLAUDE.md` "Monetary Sign Convention."
- **Parse via `MonetaryAmount.parseCents(from:)`.** Never duplicate `parseCurrency` in views or reimplement cent parsing anywhere else.
- **Conversion correctness** — all multi-currency aggregation rules live in `guides/INSTRUMENT_CONVERSION_GUIDE.md`.

---

## 17. Dependency Injection

- **`@Environment(BackendProvider.self)` is the DI root** for repositories. Features talk to repository protocols exclusively through `BackendProvider`. Do not import `Backends/` and do not reference `Remote*` types from feature code.
- **No singletons.** `UserDefaults.standard`, `FileManager.default`, and friends are singletons when used directly. Wrap them in a type injected through the environment or the initializer.
- **`Date()` only at boundaries.** Production code at the edge may read the system clock; anything deeper takes a `Date` parameter (or a `() -> Date` clock function). Tests inject a fixed `Date` rather than racing the real clock.

---

## 18. SwiftUI-Swift Idioms

These rules concern Swift-language patterns in SwiftUI code. Layout, colour, and HIG rules live in `guides/UI_GUIDE.md`.

- **Stores are `@MainActor @Observable`.** See `guides/CONCURRENCY_GUIDE.md` §2 for the full contract.
- **Views are thin.** Business logic lives in stores, model extensions, or shared utilities — never in private view methods. See `CLAUDE.md` "Thin Views, Testable Stores" for the canonical split.
- **Services via `EnvironmentValues`, not singletons.** `@Environment(\.keyPath)` for cross-cutting services; initializer injection for store-owned dependencies.
- **`@State` only for local UI state.** Selection, sheet visibility, search text, focus state. Anything that would need to round-trip through a store does not belong in `@State`.
- **`@Binding` pass-through chains ≤ 1 level deep.** If a binding threads through more than one intermediate view, the state belongs in a `@Bindable` store, not `@Binding` plumbing.

---

## 19. Documentation

- **`///` for public and `Domain/` API.** Internal helpers can be self-documenting through names.
- **Describe WHY, not WHAT.** Names describe what; docstrings provide intent, preconditions, invariants, and context a reader can't infer.

  ```swift
  /// Applies a scheduled payment and advances the schedule's next occurrence.
  ///
  /// This is the only path that mutates both `Transaction` and `ScheduledPayment`
  /// atomically. Views call this instead of composing the two writes themselves;
  /// a partial failure rolls back both.
  func payScheduledTransaction(_ scheduled: ScheduledPayment) async throws -> PayResult
  ```

- **DocC-compatible sections.** Use `- Parameters:`, `- Returns:`, `- Throws:` per [apple/swift DocumentationComments.md](https://github.com/apple/swift/blob/main/docs/DocumentationComments.md).
- **Attach doc comments directly to the declaration they describe.** SwiftLint's [`orphaned_doc_comment`](https://realm.github.io/SwiftLint/orphaned_doc_comment.html) rule flags `///` blocks separated from the next declaration by a blank line or an intervening `//` comment — the compiler treats those as orphans and drops them from DocC / Xcode Quick Help. If a doc comment isn't documenting the declaration that immediately follows, demote it to `//` (it's narrative, not API docs) or move it adjacent to the declaration it's actually describing. Never leave a blank line between `///` and the `func` / `var` / `let` / `class` it documents.
- **No block comments** (`/* */`). SwiftLint's `NoBlockComments` rule enforces this.
- **No commented-out code.** Delete it — `git log` has the history. Commented-out code rots, lies about intent, and triggers false-positive diffs.
- **Succinct.** A comment earns its place by saying something the code can't. Cut filler that restates the next line (`// increment i`, `// return the result`). Tighten prose to the minimum that conveys the rationale.
- **Present tense — describe the situation as it is now, never how it changed.** A comment is read by someone looking at today's code, not the diff that produced it. Strip time-travel framing (`no longer`, `previously`, `used to be`, `formerly`, `now that we`, `renamed from`) and state the current fact. Keep the explanatory value — *why* the code does or doesn't do something a reader would expect — without narrating the transition.

  ```swift
  // Avoid: The per-profile `instrument` table no longer exists post-v10,
  //        so fiat is resolved via the shared registry.
  // Prefer: There is no per-profile `instrument` table; fiat resolves
  //         via the shared registry.
  ```

- **No PR or plan archaeology.** Don't reference PR numbers as history, plan slice numbers, or "as part of the X rollout/cutover". `git blame` carries that. Tracked-issue references (`See issue #865`, `TODO(#N)` per §20) are the exception and stay.
- **Split-out file headers state purpose, not surgery.** A file carved off a larger one for §3 size reasons documents what it now holds, not the extraction or the threshold. `// Budget CRUD extracted from EarmarkStore so it stays under type_body_length` → `// Budget CRUD for \`EarmarkStore\`.`
- **`// MARK:` for sections** inside files longer than 300 lines (cross-ref §2).

---

## 20. TODOs and FIXMEs

Every `TODO` or `FIXME` **must reference a tracked GitHub issue**. Bare `TODO:` or `FIXME:` without a reference is **disallowed**.

- **Short form** (acceptable on one line):

  ```swift
  // TODO(#123): drop legacy import path once sync v2 ships
  ```

- **Long form** (with URL for skimmability in PRs):

  ```swift
  // TODO(#123): drop legacy import path once sync v2 ships
  //             — https://github.com/ajsutton/moolah-native/issues/123
  ```

Enforcement is automated:

- **Pre-merge** — `just validate-todos` runs in CI on every push and same-repo PR (fork PRs get a format-only variant that doesn't hit the API). Fails if any TODO is bare, or if any `TODO(#N)` reference points at a closed or non-existent issue.
- **Daily watchdog** — `.github/workflows/todo-issue-watchdog.yml` reconciles the `has-todos` label and reopens any issue that got closed while live references still exist.
- **Xcode** — SwiftLint's `todo_issue_reference` custom rule flags bare `TODO:` / `FIXME:` inline as you type, so you catch them before CI does.

See `plans/2026-04-23-todo-reference-enforcement-design.md` for the full design.

---

## 21. Imports

- **Ordering is automatic.** `swift-format`'s [`OrderedImports`](https://github.com/apple/swift-format/blob/main/Documentation/Configuration.md) rule handles grouping and sort order. Don't hand-edit import order.
- **Purpose rule.** Imports announce architectural boundaries:
  - `Domain/` files import **nothing** from `SwiftUI`, `SwiftData`, `URLSession`, or `Backends/`. The domain layer is pure.
  - `Features/` files **never** import backend-specific modules or reference `Remote*` / `CloudKit*` types directly — they go through `BackendProvider`.
- **Unused imports get flagged.** SwiftLint's [`unused_import`](https://realm.github.io/SwiftLint/unused_import.html) rule catches this; prune stale imports on review.

---

## 22. Cross-References

Topics owned by other guides — this guide defers, it does not duplicate.

- **Concurrency, `Sendable`, actor isolation, `Task` hygiene** → `guides/CONCURRENCY_GUIDE.md`.
- **Test structure, fixtures, seeds** → `guides/TEST_GUIDE.md`, `guides/UI_TEST_GUIDE.md`.
- **CKSyncEngine, change tracking, record mapping** → `guides/SYNC_GUIDE.md`.
- **Currency conversion correctness** → `guides/INSTRUMENT_CONVERSION_GUIDE.md`.
- **SwiftUI layout, colours, typography, HIG** → `guides/UI_GUIDE.md`.
- **Signpost instrumentation, benchmark patterns** → `guides/BENCHMARKING_GUIDE.md`.
- **App Store metadata, entitlements, icons** → `@appstore-review` agent + `scripts/validate-appstore.sh`.

---

## 23. Further Reading

| Source | Link |
| --- | --- |
| Apple Swift API Design Guidelines | https://www.swift.org/documentation/api-design-guidelines/ |
| Apple: Choosing Between Structures and Classes | https://developer.apple.com/documentation/swift/choosing-between-structures-and-classes |
| SE-0413 Typed Throws | https://github.com/swiftlang/swift-evolution/blob/main/proposals/0413-typed-throws.md |
| SE-0335 Introduce existential any | https://github.com/swiftlang/swift-evolution/blob/main/proposals/0335-existential-any.md |
| WWDC 2015 Session 408 (Protocol-Oriented Programming) | https://developer.apple.com/videos/play/wwdc2015/408/ |
| WWDC 2015 Session 414 (Value Types) | https://developer.apple.com/videos/play/wwdc2015/414/ |
| Apple swift-format Configuration | https://github.com/apple/swift-format/blob/main/Documentation/Configuration.md |
| apple/swift DocumentationComments.md | https://github.com/apple/swift/blob/main/docs/DocumentationComments.md |
| SwiftLint Rule Directory | https://realm.github.io/SwiftLint/rule-directory.html |
| NetNewsWire CodingGuidelines.md | https://github.com/Ranchero-Software/NetNewsWire/blob/main/Technotes/CodingGuidelines.md |
| Google Swift Style Guide | https://google.github.io/swift/ |
| Airbnb Swift Style Guide | https://github.com/airbnb/swift |
| Kodeco Swift Style Guide | https://github.com/kodecocodes/swift-style-guide |
| LinkedIn Swift Style Guide | https://github.com/linkedin/swift-style-guide |
| SonarSource Cognitive Complexity | https://www.sonarsource.com/blog/cognitive-complexity-because-testability-understandability/ |
| Brent Simmons — How NetNewsWire Handles Threading | https://inessential.com/2021/03/20/how_netnewswire_handles_threading.html |

---

## Version History

- **1.0** (2026-04-22): Initial Swift code style guide.
