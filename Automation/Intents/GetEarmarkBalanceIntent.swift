import AppIntents
import Foundation

struct GetEarmarkBalanceIntent: AppIntent {
  static let title: LocalizedStringResource = "Get Earmark Balance"
  static let description = IntentDescription(
    "Returns the balance of a specific earmark.")

  @Parameter(title: "Profile") var profile: ProfileEntity

  @Parameter(title: "Earmark") var earmark: EarmarkEntity

  @MainActor
  func perform() async throws -> some IntentResult & ReturnsValue<String> {
    guard let service = AutomationServiceLocator.shared.service else {
      throw AutomationError.operationFailed("App not ready")
    }
    let resolved = try await service.resolveEarmark(
      named: earmark.name, profileIdentifier: profile.id.uuidString)
    return .result(value: InstrumentAmount.zero(instrument: resolved.instrument).formatted)
  }
}
