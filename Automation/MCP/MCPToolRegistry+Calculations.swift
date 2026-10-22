import Foundation
import MoolahMCP

extension MCPToolRegistry {
  func balances(
    input: MCPToolArguments,
    context: MCPAuthorizationContext,
    profileID: UUID,
    timeZone: TimeZone
  ) async throws -> MCPToolResult {
    // Historical balances are deliberately unsupported; never return a current value labelled as historical.
    if input.values["as_of"] != nil { throw MCPAccessFailure.unsupported }
    let page = try await service.valuedBalances(
      profileID: profileID,
      accountIDs: input.ids("account_ids"),
      reportingInstrument: reportingInstrument(input),
      timeZone: timeZone
    )
    return try await encode(page: page, context: context)
  }

  func summary(
    input: MCPToolArguments,
    context: MCPAuthorizationContext,
    profileID: UUID,
    timeZone: TimeZone
  ) async throws -> MCPToolResult {
    let group = try input.string("group_by") ?? "none"
    guard ["none", "category"].contains(group) else { throw MCPAccessFailure.unsupported }
    let page = try await service.summary(
      profileID: profileID,
      range: input.dateRange(timeZone: timeZone),
      reportingInstrument: reportingInstrument(input),
      groupByCategory: group == "category",
      includeNetWorth: input.bool("include_net_worth")
    )
    return try await encode(page: page, context: context)
  }

  private func reportingInstrument(_ input: MCPToolArguments) throws -> Instrument? {
    guard let id = try input.string("reporting_instrument", maximumBytes: 80) else { return nil }
    guard Locale.commonISOCurrencyCodes.contains(id) else { throw MCPAccessFailure.unsupported }
    return .fiat(code: id)
  }
}
