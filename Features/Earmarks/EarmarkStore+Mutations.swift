import Foundation

// Mutation surface for `EarmarkStore`.
//
// Mutations are pass-through under the reactive design: every method
// calls the repository, the GRDB write commits, and
// `repository.observeAll()` delivers the authoritative state via the
// observation task spawned in `EarmarkStore.init`. There is no
// optimistic insert / rollback path — the reactive emission IS the
// state update.
extension EarmarkStore {
  /// Pass-through create. The reactive observation delivers the new
  /// earmark via `observeAll()` shortly after the GRDB write commits;
  /// no optimistic insert is needed and there is nothing to roll back
  /// because no local state was mutated. Errors surface on `self.error`
  /// and the method returns `nil` for the caller — preserves the
  /// pre-reactive contract.
  func create(_ earmark: Earmark) async -> Earmark? {
    setError(nil)
    do {
      let created = try await repository.create(earmark)
      logger.debug("Created earmark: \(created.name)")
      return created
    } catch {
      logger.error("Failed to create earmark: \(error.localizedDescription)")
      setError(error)
      return nil
    }
  }

  /// Pass-through update. See `create(_:)` for the rationale; the
  /// reactive observation delivers the updated earmark and any
  /// follow-on conversion recompute (e.g. when the instrument changed).
  func update(_ earmark: Earmark) async -> Earmark? {
    setError(nil)
    do {
      let updated = try await repository.update(earmark)
      logger.debug("Updated earmark: \(updated.name)")
      return updated
    } catch {
      logger.error("Failed to update earmark: \(error.localizedDescription)")
      setError(error)
      return nil
    }
  }

  /// Prevents spurious repository writes when the user clears or leaves
  /// unchanged the inline-rename field. Whitespace is trimmed before
  /// comparison; empty/whitespace-only and same-name inputs are treated
  /// as no-ops and return the current earmark without touching the
  /// repository. Errors from `update(_:)` surface on `self.error`.
  @discardableResult
  func rename(id: UUID, to newName: String) async -> Earmark? {
    let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let earmark = earmarks.by(id: id) else { return nil }
    guard !trimmed.isEmpty, trimmed != earmark.name else { return earmark }
    var updated = earmark
    updated.name = trimmed
    return await update(updated)
  }

  /// Marks an earmark as hidden so it no longer appears in default
  /// lists. Pass-through to `update(_:)`.
  @discardableResult
  func hide(_ earmark: Earmark) async -> Earmark? {
    var hidden = earmark
    hidden.isHidden = true
    return await update(hidden)
  }

  /// Persists a new ordering. Each underlying `update` is awaited
  /// sequentially; the first error is captured and surfaced. The
  /// reactive observation delivers the authoritative ordering once the
  /// writes commit, so no optimistic mutation is performed here.
  /// Hidden earmarks keep their existing positions.
  func reorderEarmarks(from source: IndexSet, to destination: Int) async {
    setError(nil)

    var visible = visibleEarmarks
    visible.move(fromOffsets: source, toOffset: destination)
    for index in visible.indices {
      visible[index].position = index
    }

    var firstError: (any Error)?
    for earmark in visible {
      do {
        _ = try await repository.update(earmark)
      } catch {
        logger.error("Failed to persist earmark reorder for \(earmark.id): \(error)")
        if firstError == nil { firstError = error }
      }
    }

    if let firstError {
      setError(firstError)
    }
  }
}
