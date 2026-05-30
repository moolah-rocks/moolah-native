import Foundation

public enum PlistEmitter {
  /// Emits the complete `Info.plist` for an `MoolahImportExtension_<platform>` action
  /// extension. The static CFBundle/NSExtension keys live alongside the generated
  /// `NSExtensionActivationRule`, so the file produced here is the extension's
  /// `INFOPLIST_FILE` directly — no merge step is needed.
  public static func emit(manifests: [Manifest]) -> String {
    let predicate = activationRule(manifests: manifests)
    return """
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0">
      <dict>
        <key>CFBundleDevelopmentRegion</key>
        <string>$(DEVELOPMENT_LANGUAGE)</string>
        <key>CFBundleDisplayName</key>
        <string>Import to Moolah</string>
        <key>CFBundleExecutable</key>
        <string>$(EXECUTABLE_NAME)</string>
        <key>CFBundleIdentifier</key>
        <string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
        <key>CFBundleInfoDictionaryVersion</key>
        <string>6.0</string>
        <key>CFBundleName</key>
        <string>$(PRODUCT_NAME)</string>
        <key>CFBundlePackageType</key>
        <string>$(PRODUCT_BUNDLE_PACKAGE_TYPE)</string>
        <key>CFBundleShortVersionString</key>
        <string>$(MARKETING_VERSION)</string>
        <key>CFBundleVersion</key>
        <string>$(CURRENT_PROJECT_VERSION)</string>
        <key>NSExtension</key>
        <dict>
          <key>NSExtensionAttributes</key>
          <dict>
            <key>NSExtensionActivationRule</key>
            <string>\(predicate)</string>
            <key>NSExtensionJavaScriptPreprocessingFile</key>
            <string>extension-entry.bundle</string>
          </dict>
          <key>NSExtensionPointIdentifier</key>
          <string>com.apple.ui-services</string>
          <key>NSExtensionPrincipalClass</key>
          <string>$(PRODUCT_MODULE_NAME).ImportExtensionPrincipal</string>
        </dict>
      </dict>
      </plist>
      """
  }

  /// Emits just the `NSExtensionActivationRule` predicate string. Surfaced for
  /// tests that want to inspect the predicate without parsing the surrounding
  /// plist.
  static func activationRule(manifests: [Manifest]) -> String {
    if manifests.isEmpty {
      return "FALSEPREDICATE"
    }
    let clauses = manifests.map { m in
      #"(($att.URL.host == "\#(m.host)" OR $att.URL.host ENDSWITH ".\#(m.host)") AND $att.URL.path BEGINSWITH "\#(m.pathPrefix)")"#
    }.joined(separator: " OR ")
    return """
      SUBQUERY(extensionItems, $item,
        SUBQUERY($item.attachments, $att,
          ANY $att.registeredTypeIdentifiers UTI-CONFORMS-TO "public.url"
          AND (\(clauses))
        ).@count > 0
      ).@count > 0
      """
  }
}
