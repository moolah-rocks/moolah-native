// Backends/GRDB/ProfileSchema+PurgeIntradayCaches.swift

import Foundation
import GRDB

// MARK: - v7 migration body
//
// Empties all six rate-cache tables — `exchange_rate`,
// `exchange_rate_meta`, `stock_price`, `stock_ticker_meta`,
// `crypto_price`, `crypto_token_meta`.
//
// Why a one-shot purge: earlier builds wrote partial intraday bars to
// the cache as if they were finalised closes, then froze them
// (cache-hits never re-fetched). Once a row was poisoned, every
// subsequent read returned a stale tick — most visibly as VGS.AX
// reporting an intraday print after the session settled. The fix in
// `Shared/PriceCacheCap.swift` caps every request at the prior
// local-calendar day and re-fetches the latest cached date on every
// forward extension, but the rule only governs *future* writes. Any
// pre-fix poisoned row sits
// in the cache as actual-yesterday once today rolls over, and there's
// no way for the service to tell a finalised close from a frozen
// intraday tick. Wiping the lot is the cheapest way to guarantee a
// clean baseline.
//
// Cost: every cached date is re-fetched on demand from Yahoo /
// Frankfurter / CoinGecko the next time someone asks for that range.
// `guides/DATABASE_SCHEMA_GUIDE.md` §9's "rate caches kept forever"
// retention rule is unaffected — we're not changing the policy, just
// resetting state once.
//
// `v1_initial` is shipped, so editing its body in place to seed the
// new schema differently is forbidden by §6.

extension ProfileSchema {
  static func purgeIntradayCachedPrices(_ database: Database) throws {
    try database.execute(
      sql: """
        DELETE FROM exchange_rate;
        DELETE FROM exchange_rate_meta;
        DELETE FROM stock_price;
        DELETE FROM stock_ticker_meta;
        DELETE FROM crypto_price;
        DELETE FROM crypto_token_meta;
        """)
  }
}
