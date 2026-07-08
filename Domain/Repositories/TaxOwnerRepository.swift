// Domain/Repositories/TaxOwnerRepository.swift

import Foundation

protocol TaxOwnerRepository: Sendable {
  func fetchAll() async throws -> [TaxOwner]
  func observeAll() -> AsyncStream<[TaxOwner]>
  func observeErrors() -> AsyncStream<any Error>
  func create(_ owner: TaxOwner) async throws -> TaxOwner
  func update(_ owner: TaxOwner) async throws -> TaxOwner
  func delete(id: UUID) async throws
}
