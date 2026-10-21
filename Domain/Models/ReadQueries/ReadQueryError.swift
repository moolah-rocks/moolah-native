/// Stable, non-sensitive read failures shared by local automation transports.
enum ReadQueryError: Error, Equatable {
  case invalidFilter
  case notFound
  case profileUnavailable
  case profileIncompatible
  case cursorExpired
  case resultTooLarge
  case priceUnavailable
}
