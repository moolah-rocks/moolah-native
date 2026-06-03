/// The sibling feature stores `InsightStore` reads each refresh to gather the
/// main-actor half of an `InsightInput` (the `InsightInputSnapshot`). Bundled
/// into a single struct so `InsightStore.init` stays within SwiftLint's
/// `function_parameter_count` budget (≤5); the bundle itself groups the 6
/// store references. `@MainActor` because every member is a main-actor store
/// and the snapshot is gathered on the main actor.
@MainActor
struct InsightStoreSources {
  let analysis: AnalysisStore
  let earmark: EarmarkStore
  let reporting: ReportingStore
  let account: AccountStore
  /// Optional because `ProfileSession` assigns `accountGroupStore` in
  /// `finishInit` and degraded (preview) launches may omit it.
  let accountGroup: AccountGroupStore?
  let category: CategoryStore
}
