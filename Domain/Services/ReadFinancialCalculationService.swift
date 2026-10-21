import Foundation
import os

/// Uses the same discriminated conversion service as app reports; unavailable prices never become zero.
struct ReadFinancialCalculationService: Sendable {
  private static let logger = Logger(subsystem: "rocks.moolah", category: "MCPReadValuation")

  let conversion: any InstrumentConversionService

  func value(_ amounts: [ReadDatedAmount], target: Instrument) async throws -> [ReadValuation] {
    var values: [ReadValuation?] = Array(repeating: nil, count: amounts.count)
    var indexes: [Int] = []
    var requests: [BatchConversionRequest] = []
    for (index, item) in amounts.enumerated() {
      try Task.checkCancellation()
      if item.amount.instrument == target || item.amount.isZero {
        values[index] = ReadValuation(
          amount: InstrumentAmount(quantity: item.amount.quantity, instrument: target),
          reportingInstrument: target,
          status: "native",
          requestedAt: item.date,
          oldestPriceAt: nil,
          provenance: "no_external_price_required",
          errorCode: nil
        )
      } else {
        indexes.append(index)
        requests.append(
          BatchConversionRequest(amount: item.amount, target: target, date: item.date)
        )
      }
    }
    let outcomes: [BatchConversionOutcome]
    if requests.isEmpty {
      outcomes = []
    } else {
      outcomes = try await conversion.convertResultBatch(requests)
    }
    guard outcomes.count == requests.count else {
      Self.logger.error("Conversion batch violated its cardinality contract")
      throw ReadCalculationError.invalidResult
    }
    for (index, outcome) in zip(indexes, outcomes) {
      try Task.checkCancellation()
      values[index] = try await valuation(outcome, request: amounts[index], target: target)
    }
    let missingPrices = values.contains { $0?.status == "price_unavailable" }
    let missingProvenance = values.contains { $0?.status == "priced" && $0?.oldestPriceAt == nil }
    if missingPrices {
      Self.logger.notice("Recognized conversion failures; some valuations unavailable")
    }
    if missingProvenance { Self.logger.notice("Price provenance unavailable; freshness unknown") }
    return try values.map {
      guard let value = $0 else { throw ReadCalculationError.invalidResult }
      return value
    }
  }

  private func valuation(
    _ outcome: BatchConversionOutcome,
    request: ReadDatedAmount,
    target: Instrument
  ) async throws -> ReadValuation {
    switch outcome {
    case .failure(let error):
      if error is CancellationError { throw CancellationError() }
      guard ConversionFailureClassifier.canRepresentAsUnavailableData(error) else {
        Self.logger.error("Unexpected conversion failure; query rejected")
        throw error
      }
      return unavailable(on: request.date, target: target)
    case .knownZero(let instrument):
      guard instrument == target else {
        Self.logger.error("Known-zero conversion returned an unexpected instrument")
        throw ReadCalculationError.invalidResult
      }
      return ReadValuation(
        amount: InstrumentAmount.zero(instrument: target),
        reportingInstrument: target,
        status: "known_zero_by_policy",
        requestedAt: request.date,
        oldestPriceAt: nil,
        provenance: "moolah_pricing_policy",
        errorCode: nil
      )
    case .value(let amount):
      guard amount.instrument == target, !amount.quantity.isNaN else {
        Self.logger.error("Conversion returned an invalid quantity or instrument")
        throw ReadCalculationError.invalidResult
      }
      let priceDate: Date?
      do {
        priceDate = try await conversion.oldestPriceDate(
          for: request.amount,
          to: target,
          on: request.date
        )
      } catch is CancellationError { throw CancellationError() } catch {
        priceDate = nil
      }
      return ReadValuation(
        amount: amount,
        reportingInstrument: target,
        status: "priced",
        requestedAt: request.date,
        oldestPriceAt: priceDate,
        provenance: "moolah_conversion_service;external_provider_unknown",
        errorCode: nil
      )
    }
  }

  func total(
    _ values: [ReadValuation],
    target: Instrument,
    on date: Date?
  ) -> ReadValuation {
    guard values.allSatisfy({ $0.amount?.instrument == target }) else {
      return unavailable(on: date, target: target)
    }
    let sum = values.compactMap(\.amount).reduce(Decimal.zero) { $0 + $1.quantity }
    guard !sum.isNaN else { return unavailable(on: date, target: target) }
    let hasUnknownPriceDate = values.contains { $0.status == "priced" && $0.oldestPriceAt == nil }
    return ReadValuation(
      amount: InstrumentAmount(quantity: sum, instrument: target),
      reportingInstrument: target,
      status: "complete",
      requestedAt: date,
      oldestPriceAt: hasUnknownPriceDate ? nil : values.compactMap(\.oldestPriceAt).min(),
      provenance: values.isEmpty ? "empty_input" : "aggregate_of_explicit_valuations",
      errorCode: nil
    )
  }

  func warnings(_ values: [ReadValuation]) -> [String] {
    var result: [String] = []
    if values.contains(where: { $0.amount == nil }) {
      result.append(
        "Some prices are unavailable, so related reporting totals are unavailable. Amounts in their original currencies or assets remain complete."
      )
    }
    if values.contains(where: { $0.status == "known_zero_by_policy" }) {
      result.append(
        "Moolah’s pricing rules assign some assets a reporting value of zero. Their original amounts remain in the results."
      )
    }
    if values.contains(where: { $0.status == "priced" }) {
      result.append(
        "Conversions use external price data. Provider names aren’t available. Price dates appear when available."
      )
    }
    return result
  }

  private func unavailable(on date: Date?, target: Instrument) -> ReadValuation {
    ReadValuation(
      amount: nil,
      reportingInstrument: target,
      status: "price_unavailable",
      requestedAt: date,
      oldestPriceAt: nil,
      provenance: "unavailable",
      errorCode: "PRICE_UNAVAILABLE"
    )
  }
}

/// A historical reporting flow converts at its own day; current positions use the query instant.
struct ReadDatedAmount: Sendable {
  let amount: InstrumentAmount
  let date: Date
}

/// Internal pricing contract violations are query failures, never profile availability failures.
enum ReadCalculationError: Error { case invalidResult }
