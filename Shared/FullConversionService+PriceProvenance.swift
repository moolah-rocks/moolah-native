import Foundation

extension FullConversionService {
  func oldestPriceDate(
    for amount: InstrumentAmount,
    to target: Instrument,
    on date: Date
  ) async throws -> Date? {
    let source = amount.instrument
    guard source != target else { return nil }
    let effectiveDate = min(date, now())

    if source.kind == .fiatCurrency, target.kind == .fiatCurrency {
      return try await exchangeRates.effectiveRateDate(
        from: source, to: target, on: effectiveDate)
    }

    guard target.kind != .stock else {
      throw ConversionError.unsupportedConversion(from: source.id, to: target.id)
    }
    let common: Instrument =
      target.kind == .fiatCurrency
      ? target
      : source.kind == .fiatCurrency ? source : .USD
    async let sourceDates = priceDates(
      for: source, quotedIn: common, on: effectiveDate)
    async let targetDates = priceDates(
      for: target, quotedIn: common, on: effectiveDate)
    let (sourceResult, targetResult) = try await (sourceDates, targetDates)
    return (sourceResult + targetResult).min()
  }

  private func priceDates(
    for instrument: Instrument,
    quotedIn common: Instrument,
    on date: Date
  ) async throws -> [Date] {
    if instrument == common { return [] }
    if instrument.kind == .fiatCurrency {
      return try await exchangeRates.effectiveRateDate(
        from: instrument, to: common, on: date
      ).map { [$0] } ?? []
    }

    switch instrument.kind {
    case .stock:
      return try await stockPriceDates(for: instrument, quotedIn: common, on: date)
    case .cryptoToken:
      return try await cryptoPriceDates(for: instrument, quotedIn: common, on: date)
    case .fiatCurrency:
      return []
    }
  }

  private func stockPriceDates(
    for instrument: Instrument,
    quotedIn common: Instrument,
    on date: Date
  ) async throws -> [Date] {
    guard let ticker = instrument.ticker else {
      throw ConversionError.unsupportedConversion(from: instrument.id, to: common.id)
    }
    // Resolving the effective price may populate the ticker metadata cache that
    // `instrument(for:)` reads, so these two calls intentionally remain ordered.
    let priceDate = try await stockPrices.effectivePriceDate(ticker: ticker, on: date)
    let listingCurrency = try await stockPrices.instrument(for: ticker)
    if listingCurrency == common { return [priceDate] }
    let rateDate = try await exchangeRates.effectiveRateDate(
      from: listingCurrency, to: common, on: date)
    return [priceDate] + (rateDate.map { [$0] } ?? [])
  }

  private func cryptoPriceDates(
    for instrument: Instrument,
    quotedIn common: Instrument,
    on date: Date
  ) async throws -> [Date] {
    guard let cryptoPrices else {
      throw ConversionError.noCryptoPriceService
    }
    if common == .USD {
      return [try await cryptoPrices.effectivePriceDate(for: instrument, on: date)]
    }
    async let priceDate = cryptoPrices.effectivePriceDate(for: instrument, on: date)
    async let rateDate = exchangeRates.effectiveRateDate(
      from: .USD, to: common, on: date)
    let (resolvedPriceDate, resolvedRateDate) = try await (priceDate, rateDate)
    return [resolvedPriceDate] + (resolvedRateDate.map { [$0] } ?? [])
  }
}
