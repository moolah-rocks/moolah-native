import AppKit

// moolah: marked `@retroactive` — Swift 6.x requires explicit
// acknowledgement when extending an imported type to conform to an
// imported protocol the owning module has not declared.
extension NSEdgeInsets: @retroactive Equatable {
  public static func == (lhs: NSEdgeInsets, rhs: NSEdgeInsets) -> Bool {
    NSEdgeInsetsEqual(lhs, rhs)
  }
}
