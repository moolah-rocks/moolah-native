import Foundation
import Testing

@testable import Moolah

@Suite("FrankfurterClient")
struct FrankfurterClientTests {
  @Test
  func parsesRangeResponseFormat() throws {
    // Shape returned by the real Frankfurter range endpoint
    // (api.frankfurter.app/<from>..<to>?base=<code>).
    let json = """
      {
        "amount": 1.0,
        "base": "AUD",
        "start_date": "2026-04-10",
        "end_date": "2026-04-11",
        "rates": {
          "2026-04-10": {"USD": 0.629},
          "2026-04-11": {"USD": 0.632, "EUR": 0.581}
        }
      }
      """
    let data = Data(json.utf8)
    let result = try FrankfurterClient.parseResponse(data)

    #expect(result.count == 2)  // 2 dates
    #expect(result["2026-04-11"]?["USD"] == dec("0.632"))
    #expect(result["2026-04-11"]?["EUR"] == dec("0.581"))
    #expect(result["2026-04-10"]?["USD"] == dec("0.629"))
  }

  @Test
  func parsesEmptyRatesResponse() throws {
    let json = """
      {
        "amount": 1.0,
        "base": "AUD",
        "start_date": "2026-04-10",
        "end_date": "2026-04-10",
        "rates": {}
      }
      """
    let data = Data(json.utf8)
    let result = try FrankfurterClient.parseResponse(data)
    #expect(result.isEmpty)
  }
}
