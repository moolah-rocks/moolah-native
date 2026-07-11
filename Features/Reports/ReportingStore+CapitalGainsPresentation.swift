import Foundation

extension ReportingStore {
  nonisolated static func capitalGainsResult(
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

  nonisolated static func sortedInstruments(_ instruments: Set<Instrument>) -> [Instrument] {
    instruments.sorted {
      if $0.displayLabel != $1.displayLabel {
        return $0.displayLabel < $1.displayLabel
      }
      return $0.id < $1.id
    }
  }

  nonisolated static func capitalGainsSummary(
    from events: [CapitalGainEvent]
  ) -> CapitalGainsSummary {
    let summaries = capitalGainsSummariesByOwner(from: events)
    guard summaries.count > 1 else {
      return summaries.values.first ?? capitalGainsSummaryForSingleOwner(from: events)
    }
    return rollUpCapitalGainsSummaries(Array(summaries.values))
  }

  nonisolated static func selectedCapitalGainEvents(
    from events: [CapitalGainEvent],
    selectedOwnerId: UUID?,
    defaultTaxOwnerId: UUID
  ) -> [CapitalGainEvent] {
    guard let selectedOwnerId else { return events }
    return events.filter { ($0.taxOwnerId ?? defaultTaxOwnerId) == selectedOwnerId }
  }

  nonisolated static func selectedCapitalGainsSummary(
    from events: [CapitalGainEvent],
    selectedOwnerId: UUID?,
    defaultTaxOwnerId: UUID,
    allOwnerSummary: CapitalGainsSummary?
  ) -> CapitalGainsSummary? {
    guard let selectedOwnerId else { return allOwnerSummary }
    return capitalGainsSummariesByOwner(
      from: events,
      defaultTaxOwnerId: defaultTaxOwnerId)[selectedOwnerId]
  }

  nonisolated static func capitalGainsSummariesByOwner(
    from events: [CapitalGainEvent],
    defaultTaxOwnerId: UUID
  ) -> [UUID: CapitalGainsSummary] {
    Dictionary(
      grouping: events.filter(\.isReportableSale),
      by: { $0.taxOwnerId ?? defaultTaxOwnerId }
    )
    .mapValues(capitalGainsSummaryForSingleOwner(from:))
  }

  nonisolated static func capitalGainsSummariesByOwner(
    from events: [CapitalGainEvent]
  ) -> [UUID?: CapitalGainsSummary] {
    Dictionary(grouping: events.filter(\.isReportableSale), by: \.taxOwnerId)
      .mapValues(capitalGainsSummaryForSingleOwner(from:))
  }

  nonisolated private static func capitalGainsSummaryForSingleOwner(
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

  nonisolated private static func rollUpCapitalGainsSummaries(
    _ summaries: [CapitalGainsSummary]
  ) -> CapitalGainsSummary {
    CapitalGainsSummary(
      shortTermGain: summaries.reduce(Decimal(0)) { $0 + $1.shortTermGain },
      longTermGain: summaries.reduce(Decimal(0)) { $0 + $1.longTermGain },
      totalGain: summaries.reduce(Decimal(0)) { $0 + $1.totalGain },
      eventCount: summaries.reduce(0) { $0 + $1.eventCount },
      shortTermCapitalGains: summaries.reduce(Decimal(0)) { $0 + $1.shortTermCapitalGains },
      longTermCapitalGains: summaries.reduce(Decimal(0)) { $0 + $1.longTermCapitalGains },
      capitalLosses: summaries.reduce(Decimal(0)) { $0 + $1.capitalLosses },
      netCapitalGain: summaries.reduce(Decimal(0)) { $0 + $1.netCapitalGain })
  }
}
