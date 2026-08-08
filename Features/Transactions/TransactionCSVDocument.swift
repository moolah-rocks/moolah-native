import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct TransactionCSVDocument {
  let csv: String
}

extension TransactionCSVDocument: FileDocument {
  static var readableContentTypes: [UTType] { [.commaSeparatedText] }

  init(configuration _: ReadConfiguration) throws {
    csv = ""
  }

  func fileWrapper(configuration _: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: Data(csv.utf8))
  }
}
