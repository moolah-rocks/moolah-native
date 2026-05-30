import UIKit

/// Principal view controller registered as `NSExtensionPrincipalClass` in
/// `Info.plist`. The real flow — running the page-side parser, presenting the
/// confirmation sheet, and dispatching the payload to the inbox — lands in a
/// later task; this placeholder simply lets the action extension load.
final class ImportExtensionPrincipal: UIViewController {
}
