import Observation
import SwiftUI

struct TaxOwnerManagementSection: View {
  let store: TaxOwnerStore

  @State private var showAddOwner = false
  @State private var ownerToRename: TaxOwner?
  @State private var ownerToDelete: TaxOwner?
  @State private var defaultOwnerToDelete: TaxOwner?
  @State private var replacementDefaultOwnerId: UUID?

  var body: some View {
    Section {
      if store.owners.isEmpty {
        Text("Loading tax owners…")
          .foregroundStyle(.secondary)
      } else {
        ForEach(store.owners) { owner in
          taxOwnerRow(owner)
        }
      }

      Button {
        showAddOwner = true
      } label: {
        Label("Add Tax Owner", systemImage: "plus")
      }
      .accessibilityIdentifier(UITestIdentifiers.TaxOwnerSettings.addButton)
    } header: {
      Text("Tax Owners")
    } footer: {
      Text(
        "Tax reports use the default owner unless an account or category is assigned to another owner."
      )
    }
    .sheet(isPresented: $showAddOwner) {
      TaxOwnerEditSheet(
        title: "Add Tax Owner",
        name: "",
        kind: .individual,
        confirmationTitle: "Add"
      ) { name, kind in
        _ = try await store.addOwner(named: name, kind: kind)
      }
    }
    .sheet(item: $ownerToRename) { owner in
      TaxOwnerEditSheet(
        title: "Rename Tax Owner",
        name: owner.name,
        kind: owner.kind,
        confirmationTitle: "Save",
        showsKindPicker: false
      ) { name, _ in
        try await store.renameOwner(id: owner.id, to: name)
      }
    }
    .sheet(item: $defaultOwnerToDelete) { owner in
      DeleteDefaultTaxOwnerSheet(
        owner: owner,
        replacements: store.replacementOwners(for: owner),
        selectedReplacementId: replacementDefaultOwnerId
      ) { replacementId in
        try await store.deleteOwner(id: owner.id, replacementDefaultOwnerId: replacementId)
      }
    }
    .confirmationDialog(
      "Delete Tax Owner?",
      isPresented: Binding(
        get: { ownerToDelete != nil },
        set: { if !$0 { ownerToDelete = nil } }
      ),
      titleVisibility: .visible,
      presenting: ownerToDelete
    ) { owner in
      Button("Delete \(owner.name)", role: .destructive) {
        runStoreAction {
          try await store.deleteOwner(id: owner.id)
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: { owner in
      Text(
        "This deletes \(owner.name) as a tax owner and clears any account or category assignments that reference them."
      )
    }
    .alert(
      "Couldn’t update tax owners",
      isPresented: Binding(
        get: { store.errorMessage != nil },
        set: { if !$0 { store.clearError() } }
      )
    ) {
      Button("OK") { store.clearError() }
    } message: {
      if let errorMessage = store.errorMessage {
        Text(errorMessage)
      }
    }
  }

  private func taxOwnerRow(_ owner: TaxOwner) -> some View {
    HStack(spacing: 12) {
      ownerSummary(owner)
      Spacer()
      ownerActionsMenu(owner)
    }
  }

  private func ownerSummary(_ owner: TaxOwner) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 6) {
        Text(owner.name)
        if owner.id == store.profile.defaultTaxOwnerId {
          Text("Default")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .accessibilityLabel(
              UITestIdentifiers.TaxOwnerSettings.defaultBadgeLabel(ownerName: owner.name))
        }
      }
      Text(label(for: owner.kind))
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private func ownerActionsMenu(_ owner: TaxOwner) -> some View {
    Menu {
      Button("Set as Default") {
        runStoreAction {
          try await store.setDefaultOwner(id: owner.id)
        }
      }
      .disabled(owner.id == store.profile.defaultTaxOwnerId)

      Button("Rename…") {
        ownerToRename = owner
      }

      Button("Delete…", role: .destructive) {
        prepareDelete(owner)
      }
      .disabled(store.owners.count <= 1)
    } label: {
      Image(systemName: "ellipsis.circle")
        .accessibilityLabel(
          UITestIdentifiers.TaxOwnerSettings.actionsButtonLabel(ownerName: owner.name)
        )
        .accessibilityIdentifier(
          UITestIdentifiers.TaxOwnerSettings.actionsButton(ownerName: owner.name))
    }
  }

  private func prepareDelete(_ owner: TaxOwner) {
    if owner.id == store.profile.defaultTaxOwnerId {
      let replacements = store.replacementOwners(for: owner)
      replacementDefaultOwnerId = replacements.first?.id
      defaultOwnerToDelete = owner
    } else {
      ownerToDelete = owner
    }
  }

  private func runStoreAction(_ action: @escaping @MainActor () async throws -> Void) {
    Task {
      do {
        try await action()
      } catch {
        store.present(error)
      }
    }
  }

  private func label(for kind: TaxOwnerKind) -> String {
    switch kind {
    case .individual: "Individual"
    case .trust: "Trust"
    }
  }
}

private struct TaxOwnerEditSheet: View {
  @Environment(\.dismiss) private var dismiss

  let title: String
  let confirmationTitle: String
  let showsKindPicker: Bool
  let save: @MainActor (String, TaxOwnerKind) async throws -> Void
  @State private var name: String
  @State private var kind: TaxOwnerKind
  @State private var submission = TaxOwnerEditSubmissionStore()

  init(
    title: String,
    name: String,
    kind: TaxOwnerKind,
    confirmationTitle: String,
    showsKindPicker: Bool = true,
    save: @escaping @MainActor (String, TaxOwnerKind) async throws -> Void
  ) {
    self.title = title
    self.confirmationTitle = confirmationTitle
    self.showsKindPicker = showsKindPicker
    self.save = save
    _name = State(initialValue: name)
    _kind = State(initialValue: kind)
  }

  var body: some View {
    NavigationStack {
      editForm
        .navigationTitle(title)
        #if os(macOS)
          .frame(minWidth: 400, minHeight: 260)
        #endif
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { dismiss() }
              .disabled(submission.isSubmitting)
              .keyboardShortcut(.escape)
          }
          ToolbarItem(placement: .confirmationAction) {
            Button(confirmationTitle) {
              Task {
                await submission.submit(name: name, kind: kind, save: save) {
                  dismiss()
                }
              }
            }
            .disabled(
              submission.isSubmitting
                || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
            .accessibilityIdentifier(UITestIdentifiers.TaxOwnerSettings.editConfirmButton)
          }
        }
    }
    .interactiveDismissDisabled(submission.isSubmitting)
  }

  private var editForm: some View {
    Form {
      Section("Details") {
        TextField("Name", text: $name, prompt: Text("e.g. Alex"))
          .accessibilityIdentifier(UITestIdentifiers.TaxOwnerSettings.editNameField)
        if showsKindPicker {
          Picker("Type", selection: $kind) {
            Text("Individual").tag(TaxOwnerKind.individual)
            Text("Trust").tag(TaxOwnerKind.trust)
          }
        }
      }
      errorSection
    }
    .disabled(submission.isSubmitting)
    .formStyle(.grouped)
  }

  private var errorSection: some View {
    Group {
      if let errorMessage = submission.errorMessage {
        Section {
          Text(errorMessage)
            .foregroundStyle(.red)
        }
      }
    }
  }
}

private struct DeleteDefaultTaxOwnerSheet: View {
  @Environment(\.dismiss) private var dismiss

  let owner: TaxOwner
  let replacements: [TaxOwner]
  let delete: @MainActor (UUID) async throws -> Void

  @State private var selectedReplacementId: UUID?
  @State private var errorMessage: String?

  init(
    owner: TaxOwner,
    replacements: [TaxOwner],
    selectedReplacementId: UUID?,
    delete: @escaping @MainActor (UUID) async throws -> Void
  ) {
    self.owner = owner
    self.replacements = replacements
    self.delete = delete
    _selectedReplacementId = State(
      initialValue: selectedReplacementId ?? replacements.first?.id)
  }

  var body: some View {
    NavigationStack {
      deleteForm
        .navigationTitle("Delete Default Owner")
        #if os(macOS)
          .frame(minWidth: 420, minHeight: 260)
        #endif
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { dismiss() }
              .keyboardShortcut(.escape)
          }
          ToolbarItem(placement: .confirmationAction) {
            Button("Delete", role: .destructive) {
              Task { await submit() }
            }
            .disabled(selectedReplacementId == nil)
            .accessibilityIdentifier(
              UITestIdentifiers.TaxOwnerSettings.deleteDefaultConfirmButton)
          }
        }
    }
  }

  private var deleteForm: some View {
    Form {
      Section {
        Text(
          "Choose the new default tax owner before deleting \(owner.name). Accounts and categories assigned to \(owner.name) will use the new default in tax reports."
        )
        Picker("New Default", selection: $selectedReplacementId) {
          ForEach(replacements) { replacement in
            Text(replacement.name).tag(Optional(replacement.id))
          }
        }
        .accessibilityIdentifier(UITestIdentifiers.TaxOwnerSettings.replacementPicker)
      }
      errorSection
    }
    .formStyle(.grouped)
  }

  private var errorSection: some View {
    Group {
      if let errorMessage {
        Section {
          Text(errorMessage)
            .foregroundStyle(.red)
        }
      }
    }
  }

  private func submit() async {
    guard let selectedReplacementId else { return }
    do {
      try await delete(selectedReplacementId)
      dismiss()
    } catch {
      errorMessage = TaxOwnerStore.message(for: error)
    }
  }
}

/// Preview-only immutable repository. Mutating methods echo their inputs so
/// sheet buttons stay wired without needing a database in canvas.
final class PreviewTaxOwnerRepository: TaxOwnerRepository, @unchecked Sendable {
  private let owners: [TaxOwner]

  init(owners: [TaxOwner]) {
    self.owners = owners
  }

  func fetchAll() async throws -> [TaxOwner] {
    owners
  }

  func observeAll() -> AsyncStream<[TaxOwner]> {
    AsyncStream { continuation in
      continuation.yield(owners)
    }
  }

  func observeErrors() -> AsyncStream<any Error> {
    AsyncStream { _ in }
  }

  func create(_ owner: TaxOwner) async throws -> TaxOwner {
    owner
  }

  func update(_ owner: TaxOwner) async throws -> TaxOwner {
    owner
  }

  func delete(id: UUID) async throws {}
}
