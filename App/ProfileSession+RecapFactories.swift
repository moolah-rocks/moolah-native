import Foundation

extension ProfileSession {

  // MARK: - WeeklyRecapStore construction

  /// Builds a `WeeklyRecapStore` for the profile, wiring the shared narrator
  /// and availability plus the per-profile last-shown persistence. Under
  /// `--ui-testing`, seeds that request a fresh "never shown" store or a
  /// forced opt-in receive those overrides via `UITestSeedInsightOverrides`.
  @MainActor
  static func makeWeeklyRecapStore(
    insightStore: InsightStore,
    narrator: any InsightNarrating,
    availability: any ModelAvailabilityProviding,
    profileId: UUID
  ) -> WeeklyRecapStore {
    #if DEBUG
      let lastShownStore: any RecapLastShownStoring =
        uiTestingRecapLastShownStore() ?? UserDefaultsRecapLastShownStore()
      let isOptedIn = makeRecapOptedInClosure()
    #else
      let lastShownStore: any RecapLastShownStoring = UserDefaultsRecapLastShownStore()
      let isOptedIn: @Sendable () -> Bool = {
        UserDefaults.moolahShared.bool(forKey: UserDefaults.weeklyRecapEnabledKey)
      }
    #endif
    return WeeklyRecapStore(
      insightStore: insightStore,
      narrator: narrator,
      availability: availability,
      lastShownStore: lastShownStore,
      profileId: profileId,
      isOptedIn: isOptedIn)
  }

  // MARK: - UI-test recap overrides

  #if DEBUG
    /// Returns an `InMemoryRecapLastShownStore` for seeds that need a
    /// "never shown" initial state, or `nil` for production launches (or seeds
    /// that use the real `UserDefaultsRecapLastShownStore`). `@MainActor`
    /// because `UITestSeedInsightOverrides` is a `@MainActor` type.
    @MainActor
    static func uiTestingRecapLastShownStore() -> InMemoryRecapLastShownStore? {
      guard let seed = currentUITestSeed() else { return nil }
      return UITestSeedInsightOverrides.recapLastShownStore(for: seed)
    }

    /// Builds the `isOptedIn` closure for `WeeklyRecapStore`. Returns `{ true }`
    /// for seeds that force opt-in on; otherwise returns the production
    /// `UserDefaults` read. Extracted so the `if/else` does not inflate
    /// `makeWeeklyRecapStore` beyond SwiftLint's function-body limit.
    @MainActor
    private static func makeRecapOptedInClosure() -> @Sendable () -> Bool {
      guard let seed = currentUITestSeed(),
        UITestSeedInsightOverrides.recapOptedIn(for: seed)
      else {
        return { UserDefaults.moolahShared.bool(forKey: UserDefaults.weeklyRecapEnabledKey) }
      }
      return { true }
    }
  #endif
}
