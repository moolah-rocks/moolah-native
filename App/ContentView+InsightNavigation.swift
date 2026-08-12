import SwiftUI

struct ContentNavigationState: Hashable {
  let selection: SidebarSelection
  let allTransactionsFilter: TransactionFilter
}

// MARK: - Navigation History

extension ContentView {
  private static let historyLimit = 50

  var currentNavigationState: ContentNavigationState? {
    selection.map {
      ContentNavigationState(
        selection: $0,
        allTransactionsFilter: $0 == .allTransactions ? allTransactionsFilter : TransactionFilter())
    }
  }

  func recordHistory(previous: SidebarSelection?, new: SidebarSelection?) {
    if let token = historyDrivenSelection, token.selection == new {
      historyDrivenSelection = nil
      return
    }
    guard let previous else { return }
    backStack.append(
      ContentNavigationState(
        selection: previous,
        allTransactionsFilter:
          previous == .allTransactions ? allTransactionsFilter : TransactionFilter()))
    Self.trimToHistoryLimit(&backStack)
    forwardStack.removeAll()
  }

  func goBack() {
    guard let previous = backStack.popLast() else { return }
    if let current = currentNavigationState {
      forwardStack.append(current)
      Self.trimToHistoryLimit(&forwardStack)
    }
    applyHistory(previous)
  }

  func goForward() {
    guard let next = forwardStack.popLast() else { return }
    if let current = currentNavigationState {
      backStack.append(current)
      Self.trimToHistoryLimit(&backStack)
    }
    applyHistory(next)
  }

  private func applyHistory(_ state: ContentNavigationState) {
    historyDrivenSelection = state
    allTransactionsFilter = state.allTransactionsFilter
    selection = state.selection
  }

  private static func trimToHistoryLimit(_ stack: inout [ContentNavigationState]) {
    if stack.count > historyLimit {
      stack.removeFirst(stack.count - historyLimit)
    }
  }
}

// MARK: - Insight Navigation

extension ContentView {
  var sidebarSelection: Binding<SidebarSelection?> {
    Binding(
      get: { selection },
      set: { newSelection in
        if newSelection == .allTransactions {
          allTransactionsFilter = TransactionFilter()
        }
        selection = newSelection
      })
  }

  func navigateToInsight(_ target: InsightNavigationTarget) {
    switch target {
    case .sidebar(let destination):
      selection = destination
    case .transactions(let filter):
      allTransactionsFilter = filter
      selection = .allTransactions
    }
  }
}
