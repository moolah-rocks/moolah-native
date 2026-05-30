import Foundation

public enum InboxWriterError: Error {
  /// The requested id has no file in the inbox. Distinct from
  /// `.readFailed` so `DeepLinkCoordinator` can treat a missing file
  /// (the user already drained it) as a no-op rather than a real
  /// failure to report.
  case notFound
  /// The bytes were read but JSON decoding failed. The file is
  /// quarantined to `Quarantine/<id>.json` and removed from the inbox
  /// so a corrupt payload doesn't perpetually block subsequent reads.
  case decodeFailed
  /// `Data(contentsOf:)` failed for a reason other than "no such
  /// file" — permission denied, device offline, container unavailable.
  /// Callers should log and present a transient error; the file is
  /// left in place so a retry can succeed.
  case readFailed
}

public struct InboxWriter: Sendable {
  public let rootDirectory: URL

  public init(rootDirectory: URL) { self.rootDirectory = rootDirectory }

  private var inboxDir: URL { rootDirectory.appendingPathComponent("Inbox") }
  private var quarantineDir: URL { rootDirectory.appendingPathComponent("Quarantine") }

  /// Returns the absolute on-disk URL for a given payload id inside a
  /// writer rooted at `rootDirectory`. Public so UI test drivers can
  /// poll for the same path the production writer reads/writes
  /// without duplicating the layout literal.
  public static func inboxFileURL(for id: UUID, in rootDirectory: URL) -> URL {
    rootDirectory
      .appendingPathComponent("Inbox")
      .appendingPathComponent("\(id.uuidString).json")
  }

  private func path(for id: UUID, in dir: URL) -> URL {
    dir.appendingPathComponent("\(id.uuidString).json")
  }

  /// Atomically write `payload` to the inbox under `id`. Creates the
  /// inbox directory on first use. Replaces any existing file.
  public func write(_ payload: ImportPayload, id: UUID) throws {
    try FileManager.default.createDirectory(at: inboxDir, withIntermediateDirectories: true)
    let data = try JSONEncoder.importPayload.encode(payload)
    try data.write(to: path(for: id, in: inboxDir), options: .atomic)
  }

  /// Decode the payload at `id`. Three failure shapes:
  ///   - `.notFound`: no file at this id (already drained, never
  ///     written, or removed out-of-band).
  ///   - `.readFailed`: file exists but the read raised a non-
  ///     "no-such-file" error (permission denied, container offline).
  ///     The file is left in place so a retry can succeed.
  ///   - `.decodeFailed`: bytes were read but JSON decoding failed.
  ///     The corrupt file is moved to `Quarantine/<id>.json` and
  ///     removed from the inbox so subsequent reads aren't blocked.
  public func read(id: UUID) throws -> ImportPayload {
    let url = path(for: id, in: inboxDir)
    let data: Data
    do {
      data = try Data(contentsOf: url)
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      throw InboxWriterError.notFound
    } catch let error as NSError
      where error.domain == NSCocoaErrorDomain
      && error.code == NSFileReadNoSuchFileError
    {
      throw InboxWriterError.notFound
    } catch {
      throw InboxWriterError.readFailed
    }
    do {
      return try JSONDecoder.importPayload.decode(ImportPayload.self, from: data)
    } catch {
      try? quarantine(id: id, data: data)
      try? FileManager.default.removeItem(at: url)
      throw InboxWriterError.decodeFailed
    }
  }

  /// Remove the payload at `id` from the inbox. Used by
  /// `DeepLinkCoordinator` after a successful drain.
  public func delete(id: UUID) throws {
    let url = path(for: id, in: inboxDir)
    try FileManager.default.removeItem(at: url)
  }

  /// All pending payload ids in the inbox, newest first (sorted by
  /// `contentModificationDate` descending). Returns `[]` if the inbox
  /// directory doesn't exist yet.
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
