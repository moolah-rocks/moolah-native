// MARK: - isGroupItem
//
// Documented here for discoverability; the implementation lives in
// `OutlineView.swift` (modifier + state), `OutlineViewController.swift`
// (plumbing) and `OutlineViewDelegate.swift` (the
// `outlineView(_:isGroupItem:)` and `outlineView(_:shouldSelectItem:)`
// dispatch). Search for `// moolah:` comments to find the call sites.
//
// Returning `true` from this closure for a given item makes
// `NSOutlineView` render that row with the source-list group-header
// chrome (capitalised label, secondary text colour, no disclosure
// triangle for the header itself, item is not selectable). This is the
// `isGroupItem` data-source contract that the upstream package
// hard-codes (by omission) to `false`.
//
// Usage:
//
// ```swift
// OutlineView(items, children: \.children, selection: $selection) { item in
//     buildCell(for: item)
// }
// .outlineViewIsGroupItem { $0.isGroup }
// ```
