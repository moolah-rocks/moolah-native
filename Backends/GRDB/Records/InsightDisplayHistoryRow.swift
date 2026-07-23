import Foundation
import GRDB

struct InsightDisplayHistoryRow: Codable, Sendable, FetchableRecord, PersistableRecord {
  static let databaseTableName = "insight_display_history"

  enum CodingKeys: String, CodingKey {
    case presentationKey = "presentation_key"
    case lastShownAt = "last_shown_at"
  }

  enum Columns: String, ColumnExpression {
    case presentationKey = "presentation_key"
    case lastShownAt = "last_shown_at"
  }

  let presentationKey: String
  let lastShownAt: Date
}
