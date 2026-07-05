#if os(macOS)
  import AppKit
  import Foundation
  import OSLog

  private let logger = Logger(
    subsystem: "com.moolah.app", category: "RegisterInstrumentCommand")

  /// Handles: `register instrument of profile "P" chain N contract "0x…"
  /// symbol "STRK" name "Starknet" decimals 18 coingecko "starknet"`
  ///
  /// Registers (or upserts) a crypto token + its price-provider mapping (see
  /// `AutomationService.registerCryptoInstrument`) so a subsequent
  /// `add leg … instrument "<chain>:<contract>"` can resolve and value it.
  /// Returns the registered instrument id.
  class RegisterInstrumentCommand: AppLevelScriptCommand {
    override func performDefaultImplementation() -> Any? {
      guard let profileName = resolveProfileName() else {
        return fail("Missing profile specifier")
      }
      guard let args = evaluatedArguments,
        let chain = args["chain"] as? Int,
        let symbol = args["symbol"] as? String, !symbol.isEmpty,
        let name = args["name"] as? String, !name.isEmpty,
        let decimals = args["decimals"] as? Int
      else {
        return fail("Missing required parameters: chain, symbol, name, decimals")
      }
      let contract = args["contract"] as? String
      let coingecko = args["coingecko"] as? String
      let binance = args["binance"] as? String

      let result: String? = runBlockingWithError { @MainActor () async throws -> String in
        guard let service = ScriptingContext.automationService else {
          throw AutomationError.operationFailed("Scripting not configured")
        }
        let instrument = try await service.registerCryptoInstrument(
          profileIdentifier: profileName,
          spec: CryptoInstrumentSpec(
            chainId: chain,
            contractAddress: contract,
            symbol: symbol,
            name: name,
            decimals: decimals,
            coingeckoId: coingecko,
            binanceSymbol: binance))
        return instrument.id
      }
      return result as NSString?
    }

    private func fail(_ message: String) -> Any? {
      scriptErrorNumber = -10000
      scriptErrorString = message
      return nil
    }
  }
#endif
