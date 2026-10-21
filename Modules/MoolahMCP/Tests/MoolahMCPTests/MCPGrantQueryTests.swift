import Foundation
import Testing

@testable import MoolahMCP

struct MCPGrantQueryTests {
  @Test(.timeLimit(.minutes(1)))
  func revokeCancelsWorkAndWaitersCannotReturnFinancialResults() async throws {
    let store = try await MCPGrantStore.open(persistence: MCPMemorySecrets())
    let profile = UUID()
    let credential = try await store.create(label: "Cancel", profileIDs: [profile])
    let context = try #require(try await store.authenticate(header: "Bearer " + credential.token))
    let probe = MCPActiveQueryProbe()
    let task = Task {
      try await store.execute(context: context, scope: .accounts, profileID: profile) {
        try await probe.run()
      }
    }
    await probe.waitForStarts(1)
    try await store.revoke(id: credential.grant.id)
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(await probe.cancellations == 1)
    #expect(await store.activeQueries.isEmpty)
  }

  @Test(.timeLimit(.minutes(1)))
  func fourQuerySlotsAreReleasedOnlyAfterCancellationCleanup() async throws {
    let store = try await MCPGrantStore.open(persistence: MCPMemorySecrets())
    let profile = UUID()
    let credential = try await store.create(label: "Capacity", profileIDs: [profile])
    let context = try #require(try await store.authenticate(header: "Bearer " + credential.token))
    let probe = MCPActiveQueryProbe()
    let tasks = (0..<4).map { _ in
      Task {
        try await store.execute(context: context, scope: .accounts, profileID: profile) {
          try await probe.run()
        }
      }
    }
    await probe.waitForStarts(4)
    await #expect(throws: MCPAccessFailure.queryLimit) {
      try await store.execute(context: context, scope: .accounts, profileID: profile) { 0 }
    }
    await store.suspendQueries()
    #expect(await store.activeQueries.isEmpty)
    for task in tasks { _ = await task.result }
    #expect(await probe.cancellations == 4)
    #expect(await store.activeQueries.isEmpty)
    await store.resumeQueries()
    #expect(
      try await store.execute(context: context, scope: .accounts, profileID: profile) { 42 } == 42
    )
  }

  @Test(.timeLimit(.minutes(1)))
  func queryDeadlineCancelsUnderlyingWorkBeforeReturningItsStableError() async throws {
    let store = try await MCPGrantStore.open(persistence: MCPMemorySecrets())
    let profile = UUID()
    let credential = try await store.create(label: "Deadline", profileIDs: [profile])
    let context = try #require(try await store.authenticate(header: "Bearer " + credential.token))
    let probe = MCPActiveQueryProbe()
    let authorization = MCPQueryAuthorization(
      context: context,
      scope: .accounts,
      profileID: profile,
      requestID: nil,
      endpointOwner: nil
    )
    await #expect(throws: MCPAccessFailure.queryTimeout) {
      try await store.execute(
        authorization: authorization,
        waitForDeadline: { await probe.waitForStarts(1) },
        operation: { try await probe.run() }
      )
    }
    #expect(await probe.cancellations == 1)
    #expect(await store.activeQueries.isEmpty)
  }

  @Test(.timeLimit(.minutes(1)))
  func clientCancellationCannotCancelAnotherGrantWithTheSameRequestID() async throws {
    let store = try await MCPGrantStore.open(persistence: MCPMemorySecrets())
    let profile = UUID()
    let first = try await store.create(label: "First", profileIDs: [profile])
    let second = try await store.create(label: "Second", profileIDs: [profile])
    let firstContext = try #require(try await store.authenticate(header: "Bearer " + first.token))
    let secondContext = try #require(try await store.authenticate(header: "Bearer " + second.token))
    let probe = MCPActiveQueryProbe()
    let firstTask = Task {
      try await store.execute(
        context: firstContext,
        scope: .accounts,
        profileID: profile,
        requestID: .integer(1)
      ) {
        try await probe.run()
      }
    }
    let secondTask = Task {
      try await store.execute(
        context: secondContext,
        scope: .accounts,
        profileID: profile,
        requestID: .integer(1)
      ) {
        try await probe.run()
      }
    }
    await probe.waitForStarts(2)
    try await store.cancel(context: firstContext, requestID: .integer(1))
    _ = await firstTask.result
    #expect(await probe.cancellations == 1)
    try await store.cancel(context: secondContext, requestID: .integer(1))
    _ = await secondTask.result
    #expect(await probe.cancellations == 2)
  }
}

extension MCPGrantQueryTests {
  @Test
  func staleShutdownCannotSuspendANewListenerGeneration() async throws {
    let store = try await MCPGrantStore.open(persistence: MCPMemorySecrets())
    let first = try await store.beginEndpoint()
    await #expect(throws: MCPAccessFailure.unavailable) { try await store.beginEndpoint() }
    await store.endEndpoint(owner: first)
    let second = try await store.beginEndpoint()
    await store.endEndpoint(owner: first)
    #expect(await store.endpointOwner == second)
    #expect(await store.acceptingQueries)
    await store.endEndpoint(owner: second)
    #expect(await store.endpointOwner == nil)
    #expect(await store.activeQueries.isEmpty)
  }
}

extension MCPGrantQueryTests {
  @Test(.timeLimit(.minutes(1)))
  func oldQueryCannotReturnAfterItsListenerGenerationIsReplaced() async throws {
    let store = try await MCPGrantStore.open(persistence: MCPMemorySecrets())
    let profile = UUID()
    let credential = try await store.create(label: "Fixture", profileIDs: [profile])
    let context = try #require(try await store.authenticate(header: "Bearer " + credential.token))
    let first = try await store.beginEndpoint()
    let gate = MCPValidationGate()
    let authorization = MCPQueryAuthorization(
      context: context,
      scope: .accounts,
      profileID: profile,
      requestID: nil,
      endpointOwner: first
    )
    let oldQuery = Task {
      try await store.execute(
        authorization: authorization,
        waitForDeadline: { try await Task.sleep(for: .seconds(15)) },
        beforeValidation: { await gate.pause() },
        operation: { 42 }
      )
    }
    await gate.waitUntilPaused()
    #expect(await store.activeQueries.isEmpty)
    await store.endEndpoint(owner: first)
    let second = try await store.beginEndpoint()
    await gate.resume()
    await #expect(throws: MCPAccessFailure.unavailable) { try await oldQuery.value }
    let current = try await store.execute(
      context: context,
      scope: .accounts,
      profileID: profile,
      endpointOwner: second
    ) { 43 }
    #expect(current == 43)
    await store.endEndpoint(owner: second)
  }
}
