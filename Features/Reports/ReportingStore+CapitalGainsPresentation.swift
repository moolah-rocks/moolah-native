import Foundation

extension ReportingStore {
  static func capitalGainsResult(
    _ result: CapitalGainsResult,
    excluding excludedInstrumentIds: Set<String>
  ) -> CapitalGainsResult {
    let unavailableInstrumentIds = result.unavailableInstrumentIds.subtracting(
      excludedInstrumentIds)
    return CapitalGainsResult(
      events: result.events.filter { !excludedInstrumentIds.contains($0.instrument.id) },
      openLots: result.openLots.filter { !excludedInstrumentIds.contains($0.instrument.id) },
      hasUnavailableData: !unavailableInstrumentIds.isEmpty,
      unavailableInstrumentIds: unavailableInstrumentIds,
      unavailableInstruments: result.unavailableInstruments.filter {
        !excludedInstrumentIds.contains($0.id)
      })
  }

  static func sortedInstruments(_ instruments: Set<Instrument>) -> [Instrument] {
    instruments.sorted {
      if $0.displayLabel != $1.displayLabel {
        return $0.displayLabel < $1.displayLabel
      }
      return $0.id < $1.id
    }
  }

  static func capitalGainsSummary(
    from events: [CapitalGainEvent]
  ) -> CapitalGainsSummary {
    let reportableEvents = events.filter(\.isReportableSale)
    let saleCount = TaxReportPresentation.saleRows(from: reportableEvents).count
    let shortTermEvents = reportableEvents.filter { !$0.isLongTerm }
    let longTermEvents = reportableEvents.filter(\.isLongTerm)
    return CapitalGainsSummary(
      shortTermGain: shortTermEvents.reduce(Decimal(0)) { $0 + $1.gain },
      longTermGain: longTermEvents.reduce(Decimal(0)) { $0 + $1.gain },
      totalGain: reportableEvents.reduce(Decimal(0)) { $0 + $1.gain },
      eventCount: saleCount,
      shortTermCapitalGains: shortTermEvents.reduce(Decimal(0)) {
        $0 + max(0, $1.gain)
      },
      longTermCapitalGains: longTermEvents.reduce(Decimal(0)) {
        $0 + max(0, $1.gain)
      },
      capitalLosses: -reportableEvents.reduce(Decimal(0)) { $0 + min(0, $1.gain) })
  }
}
