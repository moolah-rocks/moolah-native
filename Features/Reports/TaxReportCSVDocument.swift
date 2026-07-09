import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct TaxReportCSVDocument: FileDocument {
  static var readableContentTypes: [UTType] { [.commaSeparatedText] }

  var csv: String

  init(csv: String) {
    self.csv = csv
  }

  init(configuration _: ReadConfiguration) throws {
    csv = ""
  }

  func fileWrapper(configuration _: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: Data(csv.utf8))
  }
}
