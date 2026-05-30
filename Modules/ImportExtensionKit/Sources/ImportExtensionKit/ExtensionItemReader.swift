import Foundation

public enum ExtensionItemReaderError: Error, Equatable {
  case noPlugin
  case schemaMismatch
  case malformed
}

public enum ExtensionItemReader {
  public static func decode(jsResult: [String: Any]) throws -> ImportPayload {
    if let error = jsResult["error"] as? String, error == "no-plugin" {
      throw ExtensionItemReaderError.noPlugin
    }
    let data: Data
    do {
      data = try JSONSerialization.data(withJSONObject: jsResult)
    } catch {
      throw ExtensionItemReaderError.malformed
    }
    do {
      return try JSONDecoder.importPayload.decode(ImportPayload.self, from: data)
    } catch ImportPayloadDecodingError.unsupportedSchemaVersion {
      throw ExtensionItemReaderError.schemaMismatch
    } catch {
      throw ExtensionItemReaderError.malformed
    }
  }
}
