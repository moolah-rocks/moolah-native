import ImportExtensionKit
import SwiftUI

/// In-window banner that surfaces unconsumed App Group inbox files written
/// by the Safari import extension. Shown above the main content area;
/// renders `EmptyView` when nothing is pending so it has zero visual cost
/// on every other launch.
///
/// `ContentView` owns the refresh side: it runs `model.refresh()` from a
/// `.task` and re-runs on scene-phase active. The banner itself does no
/// refreshing — multiple `.task` drivers would race the inbox read for
/// no benefit.
struct PendingImportsBanner: View {
  @State private var model: PendingImportsBannerModel

  init(model: PendingImportsBannerModel) {
    _model = State(initialValue: model)
  }

  var body: some View {
    switch model.state {
    case .none:
      EmptyView()
    case .one(let host):
      banner(
        text: "1 pending import from \(host)",
        reviewActionLabel: "Review import from \(host)")
    case .many(let count):
      banner(
        text: "\(count) pending imports",
        reviewActionLabel: "Review pending imports")
    }
  }

  private func banner(text: String, reviewActionLabel: String) -> some View {
    HStack {
      Text(text)
        .font(.callout)
        .accessibilityIdentifier(UITestIdentifiers.PendingImportsBanner.label)
      Spacer()
      reviewButton
        .accessibilityLabel(reviewActionLabel)
        .accessibilityIdentifier(UITestIdentifiers.PendingImportsBanner.reviewButton)
    }
    .padding(.horizontal)
    .padding(.vertical, 8)
    .background(.thinMaterial)
  }

  // The `.borderedProminent` style fights the `.thinMaterial` banner
  // background on macOS (the colored chip vibrates against translucency);
  // iOS keeps the prominent style which lines up with HIG for an alert-
  // style banner action.
  private var reviewButton: some View {
    #if os(macOS)
      Button("Review", action: model.reviewTapped).buttonStyle(.bordered)
    #else
      Button("Review", action: model.reviewTapped).buttonStyle(.borderedProminent)
    #endif
  }
}

#if DEBUG
  #Preview("none — renders EmptyView") {
    PendingImportsBanner(
      model: PendingImportsBannerModel(
        writer: InboxWriter(rootDirectory: FileManager.default.temporaryDirectory))
    )
    .padding()
    .frame(width: 400)
  }

  #Preview("one host") {
    let model = PendingImportsBannerModel(
      writer: InboxWriter(rootDirectory: FileManager.default.temporaryDirectory))
    model.previewSeed(.one(host: "chase.com"))
    return PendingImportsBanner(model: model)
      .padding()
      .frame(width: 400)
  }

  #Preview("many") {
    let model = PendingImportsBannerModel(
      writer: InboxWriter(rootDirectory: FileManager.default.temporaryDirectory))
    model.previewSeed(.many(count: 5))
    return PendingImportsBanner(model: model)
      .padding()
      .frame(width: 400)
  }
#endif
