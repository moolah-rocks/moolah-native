import XCTest

extension XCUIElement {
  /// Polls `isHittable` until it returns `true` or `timeout` elapses.
  /// Returns `true` on hittable, `false` on timeout. Use after
  /// `waitForExistence` when the element may briefly exist in the AX tree
  /// before becoming hittable — e.g. while a row re-lays-out after a
  /// data update, or while a sheet/popover animation completes (observed
  /// on GitHub macos-26 runners).
  func waitUntilHittable(timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if isHittable { return true }
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    return isHittable
  }
}
