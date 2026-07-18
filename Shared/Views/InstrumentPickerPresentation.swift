import Foundation

/// Owns the picker store for one presentation so SwiftUI never observes a
/// presented picker backed by the previous presentation's store.
@MainActor
struct InstrumentPickerPresentation: Identifiable {
  let id = UUID()
  let store: InstrumentPickerStore

  init(session: ProfileSession?, kinds: Set<Instrument.Kind>) {
    self.store = InstrumentPickerStore(
      searchService: session?.instrumentSearchService,
      registry: session?.instrumentRegistry,
      resolutionClient: session?.tokenResolutionClient,
      canonicalResolver: session?.canonicalResolver,
      kinds: kinds
    )
  }
}
