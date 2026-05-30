import SwiftUI

/// In-window banner that surfaces unconsumed App Group inbox files written
/// by the Safari import extension. Shown above the main content area;
/// renders `EmptyView` when nothing is pending so it has zero visual cost
/// on every other launch.
///
/// The banner refreshes inside `.task`, which SwiftUI runs on appear and
/// cancels on disappear — there is no polling. Capturing a new payload
/// while the window is already on screen relies on `model.refresh()`
/// being called from the same code path that opens the window again
/// (scene phase active, deep-link arrival).
public struct PendingImportsBanner: View {
  @State private var model: PendingImportsBannerModel

  public init(model: PendingImportsBannerModel) {
    _model = State(initialValue: model)
  }

  public var body: some View {
    switch model.state {
    case .none:
      EmptyView()
    case .one(let host):
      banner(text: "1 pending import from \(host)")
    case .many(let count):
      banner(text: "\(count) pending imports")
    }
  }

  private func banner(text: String) -> some View {
    HStack {
      Text(text)
        .font(.callout)
        .accessibilityIdentifier(UITestIdentifiers.PendingImportsBanner.label)
      Spacer()
      Button("Review", action: model.reviewTapped)
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier(UITestIdentifiers.PendingImportsBanner.reviewButton)
    }
    .padding(.horizontal)
    .padding(.vertical, 8)
    .background(.thinMaterial)
    .task { await model.refresh() }
  }
}
