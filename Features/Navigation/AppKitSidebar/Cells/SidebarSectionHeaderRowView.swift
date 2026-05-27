import SwiftUI

/// Source-list section header used inside the macOS outline. Renders
/// the section title in the standard uppercased secondary style. The
/// toolbar carries the section add buttons (see
/// `Features/Navigation/SidebarSharedModifiers.swift`), so this header
/// is title-only.
///
/// The title color is `NSColor.headerTextColor` (rather than SwiftUI's
/// `.secondary`) so it tracks AppKit's native source-list group-row
/// color under Increase Contrast and other accessibility modes.
struct SidebarSectionHeaderRowView: View {
  let title: String

  var body: some View {
    HStack {
      Text(title)
        .font(.subheadline)
        .fontWeight(.semibold)
        .foregroundStyle(headerColor)
        .textCase(.uppercase)
      Spacer()
    }
  }

  private var headerColor: Color {
    #if os(macOS)
      Color(nsColor: .headerTextColor)
    #else
      .secondary
    #endif
  }
}

#Preview("Plain") {
  List {
    Section {
      Text("Row content")
    } header: {
      SidebarSectionHeaderRowView(title: "Current Accounts")
    }
  }
  .listStyle(.sidebar)
  .frame(width: 260)
}
