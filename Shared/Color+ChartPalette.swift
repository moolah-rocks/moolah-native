import SwiftUI

#if canImport(AppKit)
  import AppKit
#endif
#if canImport(UIKit)
  import UIKit
#endif

extension Color {
  /// Cross-platform light/dark `Color` factory. The system normally
  /// resolves the semantic colours (`.green`, `.red`, …) at draw time
  /// using the trait collection / appearance, but Apple's dark-mode
  /// variants are deliberately chroma-boosted to keep contrast against
  /// dark backgrounds — which reads as fluorescent inside chart areas
  /// where there's no surrounding text to anchor expectations. This
  /// initialiser lets us hand-pick a softer dark variant while keeping
  /// the familiar light-mode look.
  private init(light: Color, dark: Color) {
    #if canImport(UIKit)
      self.init(
        uiColor: UIColor { traits in
          traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
    #elseif canImport(AppKit)
      self.init(
        nsColor: NSColor(name: nil) { appearance in
          appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(dark) : NSColor(light)
        })
    #endif
  }
}

/// Chart series palette. In **light** mode each colour equals the
/// matching system semantic (`.green`, `.blue`, …) so chart marks stay
/// in family with the rest of the UI. In **dark** mode the variant is
/// slightly less luminous and less chroma-boosted than Apple's default
/// systemColor dark variant, so chart marks read as a colour against a
/// dark surface rather than as a glowing light source.
///
/// This is a documented exception to UI_GUIDE §5's "system semantic
/// colours only" rule (see also the focused-sidebar selected-row
/// override in `AccountSidebarRow`). Charts are the only context in
/// the app where multiple saturated colours sit side-by-side on a dark
/// surface; in regular UI the surrounding `.background` / `.secondary`
/// chrome moderates how saturated a `.green` looks, but inside a chart
/// area the marks ARE the surface, so the standard treatment over-fires.
///
/// All call sites for chart series colour MUST resolve through this
/// palette rather than using the system semantic colour directly, so a
/// future tuning pass is one file.
extension Color {
  /// Used for positive / available-funds / gain series.
  static let chartGreen = Color(
    light: .green,
    dark: Color(red: 0.34, green: 0.71, blue: 0.41)
  )

  /// Used for net worth / value / primary line series.
  static let chartBlue = Color(
    light: .blue,
    dark: Color(red: 0.30, green: 0.55, blue: 0.90)
  )

  /// Used for current-funds / P/L series.
  static let chartOrange = Color(
    light: .orange,
    dark: Color(red: 0.90, green: 0.60, blue: 0.18)
  )

  /// Used for invested-amount series.
  static let chartPurple = Color(
    light: .purple,
    dark: Color(red: 0.67, green: 0.45, blue: 0.80)
  )

  /// Used for investment-value series.
  static let chartIndigo = Color(
    light: .indigo,
    dark: Color(red: 0.45, green: 0.45, blue: 0.82)
  )

  /// Used for loss / negative / expense series.
  static let chartRed = Color(
    light: .red,
    dark: Color(red: 0.87, green: 0.36, blue: 0.34)
  )

  /// Used for stacked-category rotation.
  static let chartTeal = Color(
    light: .teal,
    dark: Color(red: 0.36, green: 0.72, blue: 0.84)
  )

  /// Used for stacked-category rotation.
  static let chartPink = Color(
    light: .pink,
    dark: Color(red: 0.87, green: 0.36, blue: 0.50)
  )

  /// Used for stacked-category rotation.
  static let chartMint = Color(
    light: .mint,
    dark: Color(red: 0.40, green: 0.75, blue: 0.71)
  )

  /// Used for stacked-category rotation.
  static let chartCyan = Color(
    light: .cyan,
    dark: Color(red: 0.36, green: 0.71, blue: 0.84)
  )

  /// Used for stacked-category rotation.
  static let chartBrown = Color(
    light: .brown,
    dark: Color(red: 0.65, green: 0.55, blue: 0.42)
  )

  /// Used for stacked-category rotation.
  static let chartYellow = Color(
    light: .yellow,
    dark: Color(red: 0.88, green: 0.74, blue: 0.18)
  )
}
