# OutlineView (vendored)

This directory contains a vendored copy of
[Sameesunkaria/OutlineView](https://github.com/Sameesunkaria/OutlineView)
at tag `2.0.0`, licensed MIT (see `LICENSE.txt`).

We vendored rather than depended via SPM because the upstream's public
API surface didn't expose three hooks we needed:

- `isGroupItem` closure on the cell builder, for native source-list
  group-header rows.
- `expandedItems` binding on the initialiser, for two-way expansion
  state with our own persistence store (`GroupUIStateStore`).
- An `NSTableCellView` factory helper (per the upstream README's
  recommendation that `NSTableCellView` is the preferred cell base
  class for selected-row text-colour treatment).

Our additions live in `Extensions/` so the verbatim upstream source
stays diffable against upstream. Where we had to modify upstream source
directly (e.g., `OutlineView.swift` to thread the new modifier
parameters through to the controller, `OutlineViewController.swift` to
react to the new bindings, and `OutlineViewDelegate.swift` to dispatch
the group-row + expansion delegate methods), each modification is
marked with `// moolah:` comments.

If a future upstream release adds these features, we should evaluate
returning to the SPM dependency.
