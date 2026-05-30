import Foundation

public enum PlistEmitter {
  public static func emit(manifests: [Manifest]) -> String {
    let predicate: String
    if manifests.isEmpty {
      predicate = "FALSEPREDICATE"
    } else {
      let clauses = manifests.map { m in
        #"(($att.URL.host == "\#(m.host)" OR $att.URL.host ENDSWITH ".\#(m.host)") AND $att.URL.path BEGINSWITH "\#(m.pathPrefix)")"#
      }.joined(separator: " OR ")
      predicate = """
        SUBQUERY(extensionItems, $item,
          SUBQUERY($item.attachments, $att,
            ANY $att.registeredTypeIdentifiers UTI-CONFORMS-TO "public.url"
            AND (\(clauses))
          ).@count > 0
        ).@count > 0
        """
    }
    return """
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0">
      <dict>
        <key>NSExtensionAttributes</key>
        <dict>
          <key>NSExtensionActivationRule</key>
          <string>\(predicate)</string>
          <key>NSExtensionJavaScriptPreprocessingFile</key>
          <string>extension-entry</string>
        </dict>
      </dict>
      </plist>
      """
  }
}
