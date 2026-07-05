import SwiftUI

#if os(macOS)
  import AppKit
  import QuartzCore

  /// A vertical split (panes stacked, divider horizontal) backed by
  /// `NSSplitView` so the divider position can be autosaved in
  /// `UserDefaults`. SwiftUI's `VSplitView` has no binding for the
  /// divider position and doesn't persist it — hence the AppKit wrap.
  ///
  /// Keyboard accessibility: wrapping `NSSplitView` inside
  /// `NSViewRepresentable` means the AppKit keyboard shortcut for
  /// focusing a split-view divider (Option+F6) typically won't reach
  /// this view through the SwiftUI responder chain. Users rely on the
  /// pointer (or the autosaved size) to adjust the split.
  ///
  /// - Parameters:
  ///   - autosaveName: Key under which `NSSplitView` persists the
  ///     divider position. One shared name across all call sites means
  ///     the user's preferred size applies everywhere.
  ///   - initialTopHeight: Height used for the top pane on the very
  ///     first display, before any autosaved frame exists.
  ///   - minTopHeight: Minimum height of the top pane when dragging.
  ///   - minBottomHeight: Minimum height of the bottom pane.
  ///   - collapsed: When `true`, programmatically collapses the top pane to
  ///     zero, preserving the user's divider position for restoration on
  ///     expand. The transition animates (~0.28s); if the divider is
  ///     already at the target the change applies instantly.
  ///   - reduceMotion: When `true`, the collapse/expand is applied
  ///     instantly with no animation (honours the system Reduce Motion
  ///     accessibility setting).
  ///   - defaults: `UserDefaults` instance probed for an existing
  ///     autosaved divider position. Defaults to `.moolahShared`; tests can
  ///     inject an isolated suite to avoid leaking saved frames between
  ///     runs.
  ///   - top: The top pane content.
  ///   - bottom: The bottom pane content.
  struct ResizableVSplit<Top: View, Bottom: View>: NSViewRepresentable {
    let autosaveName: String
    let initialTopHeight: CGFloat
    let minTopHeight: CGFloat
    let minBottomHeight: CGFloat
    let collapsed: Bool
    let reduceMotion: Bool
    let defaults: UserDefaults
    let top: () -> Top
    let bottom: () -> Bottom

    init(
      autosaveName: String,
      initialTopHeight: CGFloat,
      minTopHeight: CGFloat = 80,
      minBottomHeight: CGFloat = 200,
      collapsed: Bool = false,
      reduceMotion: Bool = false,
      defaults: UserDefaults = .moolahShared,
      @ViewBuilder top: @escaping () -> Top,
      @ViewBuilder bottom: @escaping () -> Bottom
    ) {
      self.autosaveName = autosaveName
      self.initialTopHeight = initialTopHeight
      self.minTopHeight = minTopHeight
      self.minBottomHeight = minBottomHeight
      self.collapsed = collapsed
      self.reduceMotion = reduceMotion
      self.defaults = defaults
      self.top = top
      self.bottom = bottom
    }

    func makeCoordinator() -> Coordinator {
      Coordinator(
        autosaveName: autosaveName,
        initialTopHeight: initialTopHeight,
        minTopHeight: minTopHeight,
        minBottomHeight: minBottomHeight
      )
    }

    func makeNSView(context: Context) -> NSSplitView {
      let split = NSSplitView()
      split.isVertical = false
      split.dividerStyle = .thin

      let topHost = NSHostingView(rootView: top())
      let bottomHost = NSHostingView(rootView: bottom())
      topHost.translatesAutoresizingMaskIntoConstraints = false
      bottomHost.translatesAutoresizingMaskIntoConstraints = false
      // Each pane's height is governed entirely by the divider position, so
      // the hosting views must lay their SwiftUI content out to fill the
      // frame the split view assigns — never at the content's intrinsic
      // size. With the default sizing options an `NSHostingView` whose
      // content is *taller* than its frame lays the content out at its ideal
      // height and centres it, so the overflow spills equally off the top and
      // bottom of the pane. For the bottom pane this pushes the pinned
      // `[Transactions | Chart]` picker (the first child) above the divider
      // and behind the top positions pane, leaving it invisible and
      // unreachable when the chart content is taller than the pane. Clearing
      // `sizingOptions`
      // makes each host propose its actual bounds to SwiftUI, so the content
      // top-anchors and compresses to fit and the picker stays pinned and
      // clickable at any window height.
      topHost.sizingOptions = []
      bottomHost.sizingOptions = []

      split.addArrangedSubview(topHost)
      split.addArrangedSubview(bottomHost)

      context.coordinator.topHost = topHost
      context.coordinator.bottomHost = bottomHost
      context.coordinator.splitView = split
      // Set splitView before the delegate so no delegate callback can
      // fire with a nil splitView.
      split.delegate = context.coordinator

      // Order matters: autosaveName triggers a restore attempt, so we
      // only apply the initial height when no saved frame exists yet.
      let hasSavedFrames =
        defaults.object(
          forKey: "NSSplitView Subview Frames \(autosaveName)") != nil
      split.autosaveName = autosaveName

      if !hasSavedFrames {
        let height = initialTopHeight
        Task { [weak split] in
          split?.setPosition(height, ofDividerAt: 0)
        }
      }

      context.coordinator.appliedCollapsed = false
      return split
    }

    func updateNSView(_ nsView: NSSplitView, context: Context) {
      context.coordinator.topHost?.rootView = top()
      context.coordinator.bottomHost?.rootView = bottom()
      context.coordinator.setCollapsed(collapsed, animated: !reduceMotion)
    }

    static func dismantleNSView(
      _ nsView: NSSplitView, coordinator: Coordinator
    ) {
      coordinator.cancelAnimation()
    }

    // `Coordinator` is nested in the generic `ResizableVSplit`, and Swift
    // forbids conforming a class from a generic context to an `@objc`
    // protocol (`NSSplitViewDelegate`) in an extension. The conformance
    // must stay on the class declaration; the delegate methods are grouped
    // under the `// MARK: - NSSplitViewDelegate` section below.
    @MainActor
    final class Coordinator: NSObject, NSSplitViewDelegate {
      var topHost: NSHostingView<Top>?
      var bottomHost: NSHostingView<Bottom>?
      weak var splitView: NSSplitView?
      let autosaveName: String
      let initialTopHeight: CGFloat
      let minTopHeight: CGFloat
      let minBottomHeight: CGFloat

      /// True while a programmatic collapse is in effect. Lets the
      /// divider travel below `minTopHeight` (that floor only
      /// constrains user drags, not the scroll-driven collapse).
      /// Intentionally not reset on premature teardown: the coordinator
      /// is discarded (a fresh one comes from `makeCoordinator()`) and
      /// `dismantleNSView` invalidates the link.
      var isCollapsing = false
      /// The divider position to restore when expanding. Captured at collapse
      /// time so the user's dragged / autosaved size returns. Not updated
      /// while collapsed: the zero-height top pane offers no draggable surface.
      var savedDividerPosition: CGFloat?
      /// Last value handed to `setCollapsed` so a no-op `updateNSView`
      /// doesn't re-trigger the transition.
      var appliedCollapsed = false
      /// Drives the eased divider animation. `NSSplitView` only honours
      /// `setPosition(_:ofDividerAt:)`, so the divider is stepped each
      /// display frame rather than via an (ignored) constraint/implicit
      /// animation. A new animation invalidates the previous link, so a
      /// mid-flight reversal simply restarts from the current position.
      private var displayLink: CADisplayLink?
      private weak var animatingSplit: NSSplitView?
      private var animationStartPosition: CGFloat = 0
      private var animationEndPosition: CGFloat = 0
      private var animationStartTime: CFTimeInterval = 0
      private let animationDuration: CFTimeInterval = 0.28
      private var animationFinalize: (@MainActor () -> Void)?

      init(
        autosaveName: String,
        initialTopHeight: CGFloat,
        minTopHeight: CGFloat,
        minBottomHeight: CGFloat
      ) {
        self.autosaveName = autosaveName
        self.initialTopHeight = initialTopHeight
        self.minTopHeight = minTopHeight
        self.minBottomHeight = minBottomHeight
      }

      func setCollapsed(_ collapsed: Bool, animated: Bool) {
        guard collapsed != appliedCollapsed else { return }
        appliedCollapsed = collapsed
        if collapsed {
          applyCollapse(animated: animated)
        } else {
          applyExpand(animated: animated)
        }
      }

      private func applyCollapse(animated: Bool) {
        guard let split = splitView else { return }
        // Divider 0's position is the bottom edge of the top pane,
        // i.e. the top arranged subview's current height. That's the
        // reciprocal of `setPosition(_:ofDividerAt:)`.
        // Only snapshot when no animation is in flight; otherwise
        // `frame.height` is a mid-transition value and would corrupt the
        // size we restore on expand. The position saved before the first
        // collapse (the user's resting size) stays valid.
        if displayLink == nil {
          savedDividerPosition = split.arrangedSubviews.first?.frame.height
        }
        // Clear the autosave name before moving the divider so the
        // transient 0 position is never persisted. NSSplitView applies
        // an autosaveName assignment synchronously, so persistence is
        // off before the divider moves.
        split.autosaveName = ""
        isCollapsing = true
        // `finalize` is also the entire effect of the instant /
        // Reduce-Motion path (when `animate` returns early), so it must
        // pin the final position even though the stepped path ends at it.
        animate(in: split, to: 0, animated: animated) { [weak self, weak split] in
          split?.setPosition(0, ofDividerAt: 0)
          // Collapsed pane is zero-height but still in the view tree;
          // hide it so VoiceOver can't strand focus in invisible content.
          self?.topHost?.isHidden = true
        }
      }

      private func applyExpand(animated: Bool) {
        // Clear even if the split is gone so the coordinator can't
        // linger with `constrainMinCoordinate` pinned to 0. When a
        // split exists the flag stays true *during* the expand
        // animation so the divider can travel up from 0; it is cleared
        // in the finalize closure below.
        guard let split = splitView else {
          isCollapsing = false
          return
        }
        let target = savedDividerPosition ?? initialTopHeight
        // Restore the pane to the a11y tree before it animates back in.
        topHost?.isHidden = false
        let name = autosaveName
        animate(in: split, to: target, animated: animated) { [weak self, weak split] in
          self?.isCollapsing = false
          split?.setPosition(target, ofDividerAt: 0)
          split?.autosaveName = name
        }
      }

      // MARK: - Animation

      /// Animate the `NSSplitView` divider from its current position to
      /// `target` over `animationDuration` with an ease-in-out curve.
      /// `setPosition(_:ofDividerAt:)` is the only divider API
      /// `NSSplitView` honours and it is not implicitly animatable, so
      /// it is stepped every display frame via `CADisplayLink`. Each
      /// call invalidates any in-flight link, so an interrupting
      /// collapse/expand restarts smoothly from the current position.
      /// `finalize` runs once at the end to pin the exact final state
      /// (and, on expand, clear `isCollapsing` / restore autosave).
      private func animate(
        in split: NSSplitView,
        to target: CGFloat,
        animated: Bool,
        finalize: @escaping @MainActor () -> Void
      ) {
        displayLink?.invalidate()
        displayLink = nil

        let start = split.arrangedSubviews.first?.frame.height ?? target
        guard animated, abs(start - target) > 0.5 else {
          finalize()
          return
        }

        animatingSplit = split
        animationStartPosition = start
        animationEndPosition = target
        animationStartTime = CACurrentMediaTime()
        animationFinalize = finalize

        let link = split.displayLink(
          target: self, selector: #selector(stepAnimation(_:)))
        link.add(to: .current, forMode: .common)
        displayLink = link
      }

      @objc
      private func stepAnimation(_ link: CADisplayLink) {
        MainActor.assertIsolated(
          """
          CADisplayLink fires on the run loop it was added to. \
          `animate(in:to:animated:finalize:)` is @MainActor-isolated, \
          so `.current` at add time is always the main run loop.
          """)
        guard link === displayLink, let split = animatingSplit else {
          link.invalidate()
          return
        }
        let elapsed = CACurrentMediaTime() - animationStartTime
        let raw = min(1, max(0, elapsed / animationDuration))
        // ease-in-out quad
        let eased =
          raw < 0.5
          ? 2 * raw * raw
          : 1 - pow(-2 * raw + 2, 2) / 2
        let position =
          animationStartPosition
          + (animationEndPosition - animationStartPosition) * CGFloat(eased)
        split.setPosition(position, ofDividerAt: 0)

        guard raw >= 1 else { return }
        link.invalidate()
        displayLink = nil
        animatingSplit = nil
        let finalize = animationFinalize
        animationFinalize = nil
        finalize?()
      }

      /// Invalidate the display link so the run loop releases its strong
      /// reference to this coordinator. Called from `dismantleNSView`
      /// when SwiftUI removes the representable mid-animation; without
      /// this the link can outlive the view and pin the coordinator.
      func cancelAnimation() {
        displayLink?.invalidate()
        displayLink = nil
        animatingSplit = nil
        animationFinalize = nil
      }

      // MARK: - NSSplitViewDelegate

      func splitView(
        _ splitView: NSSplitView,
        constrainMinCoordinate proposedMinimumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
      ) -> CGFloat {
        // While collapsing, allow the top pane to reach 0. Otherwise
        // enforce the user-drag floor.
        isCollapsing ? 0 : max(proposedMinimumPosition, minTopHeight)
      }

      func splitView(
        _ splitView: NSSplitView,
        constrainMaxCoordinate proposedMaximumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
      ) -> CGFloat {
        min(proposedMaximumPosition, splitView.bounds.height - minBottomHeight)
      }
    }
  }

  #Preview("Split") {
    ResizableVSplit(
      autosaveName: "preview-resizable-vsplit",
      initialTopHeight: 180
    ) {
      Color.blue.opacity(0.2).overlay(Text("Top"))
    } bottom: {
      Color.green.opacity(0.2).overlay(Text("Bottom"))
    }
    .frame(width: 480, height: 480)
  }
#endif
