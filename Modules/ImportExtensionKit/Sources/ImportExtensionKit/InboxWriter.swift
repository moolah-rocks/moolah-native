import Foundation

public enum InboxWriterError: Error, Equatable {
  case notFound
  case decodeFailed
}

public struct InboxWriter: Sendable {
  public let rootDirectory: URL

  public init(rootDirectory: URL) { self.rootDirectory = rootDirectory }

  private var inboxDir: URL { rootDirectory.appendingPathComponent("Inbox") }
  private var quarantineDir: URL { rootDirectory.appendingPathComponent("Quarantine") }

  private func path(for id: UUID, in dir: URL) -> URL {
    dir.appendingPathComponent("\(id.uuidString).json")
  }

  public func write(_ payload: ImportPayload, id: UUID) throws {
    try FileManager.default.createDirectory(at: inboxDir, withIntermediateDirectories: true)
    let data = try JSONEncoder.importPayload.encode(payload)
    try data.write(to: path(for: id, in: inboxDir), options: .atomic)
  }

  public func read(id: UUID) throws -> ImportPayload {
    let url = path(for: id, in: inboxDir)
    guard let data = try? Data(contentsOf: url) else { throw InboxWriterError.notFound }
    do {
      return try JSONDecoder.importPayload.decode(ImportPayload.self, from: data)
    } catch {
      try? quarantine(id: id, data: data)
      try? FileManager.default.removeItem(at: url)
      throw InboxWriterError.decodeFailed
    }
  }

  public func delete(id: UUID) throws {
    let url = path(for: id, in: inboxDir)
    try FileManager.default.removeItem(at: url)
  }

  public func list() throws -> [UUID] {
    guard
      let contents = try? FileManager.default.contentsOfDirectory(
        at: inboxDir,
        includingPropertiesForKeys: [.contentModificationDateKey],
        options: [.skipsHiddenFiles])
    else { return [] }
    let entries: [(UUID, Date)] = contents.compactMap { url in
      guard url.pathExtension == "json",
        let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
        let mtime = try? url.resourceValues(forKeys: [.contentModificationDateKey])
          .contentModificationDate
      else { return nil }
      return (id, mtime)
    }
    return entries.sorted { $0.1 > $1.1 }.map { $0.0 }
  }

  private func quarantine(id: UUID, data: Data) throws {
    try FileManager.default.createDirectory(at: quarantineDir, withIntermediateDirectories: true)
    try data.write(to: path(for: id, in: quarantineDir), options: .atomic)
  }
}
