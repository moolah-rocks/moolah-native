// MARK: - expandedItems
//
// Documented here for discoverability; the implementation lives in
// `OutlineView.swift` (modifier + state), `OutlineViewController.swift`
// (the `applyExpandedItems` reconciliation + `setExpansionChanged`
// callback installer) and `OutlineViewDelegate.swift` (the
// `outlineViewItemDidExpand` / `outlineViewItemDidCollapse` dispatch
// that drives the callback). Search for `// moolah:` comments to find
// the call sites.
//
// `outlineViewExpandedItems(_:)` binds the open / closed state of every
// expandable row to a `Set<Element.ID>` the caller owns. The
// `OutlineViewController` reconciles `NSOutlineView`'s current state
// against the bound set on every SwiftUI `update` pass, and writes
// element IDs into / out of the set when the user toggles a disclosure
// triangle.
//
// During reconciliation the callback is temporarily suppressed so the
// programmatic expand / collapse calls do not feed back into the
// binding that triggered them.
//
// Usage:
//
// ```swift
// @State private var expandedItemIDs: Set<Item.ID> = []
//
// OutlineView(items, children: \.children, selection: $selection) { item in
//     buildCell(for: item)
// }
// .outlineViewExpandedItems($expandedItemIDs)
// ```
