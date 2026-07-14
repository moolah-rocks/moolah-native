import SwiftUI

extension TransactionListView {
  @ViewBuilder var loadMoreFooter: some View {
    if transactionStore.isLoading {
      HStack {
        Spacer()
        if let total = transactionStore.totalCount, total > 0 {
          VStack(spacing: 4) {
            ProgressView(value: Double(transactionStore.loadedCount), total: Double(total))
              .frame(maxWidth: 200)
            Text("Loading \(transactionStore.loadedCount) of \(total)")
              .font(.caption)
              .foregroundStyle(.secondary)
              .monospacedDigit()
          }
        } else {
          ProgressView()
        }
        Spacer()
      }
    }
  }

  /// Empty-state overlay, differentiated by context:
  /// - Active search with no matches → system search empty state.
  /// - Loaded transactions exist but none match the current (filter + search) → hint to
  ///   clear filters/search.
  /// - No transactions loaded at all with an active filter → filter excludes everything.
  /// - `.scheduledStatus` grouping with nothing to show → scheduled-specific copy.
  /// - Otherwise (new / empty account) → encourage adding the first transaction.
  @ViewBuilder var emptyStateOverlay: some View {
    if transactionStore.isLoading {
      EmptyView()
    } else if isEmptyForCurrentGrouping {
      let hasSearch = !searchText.isEmpty
      let hasFilter = activeFilter != baseFilter
      let hasAnyLoaded = !displayedTransactions.isEmpty

      if hasSearch && hasAnyLoaded {
        // Some transactions are loaded; the search is narrowing them to zero.
        ContentUnavailableView.search(text: searchText)
      } else if hasFilter {
        ContentUnavailableView {
          Label("No Matches", systemImage: "line.3.horizontal.decrease.circle")
        } description: {
          Text("No transactions match the current filter.")
        } actions: {
          Button("Clear Filter") {
            activeFilter = baseFilter
          }
        }
      } else if hasSearch {
        // No transactions are loaded at all, but a search term is present.
        ContentUnavailableView.search(text: searchText)
      } else if case .scheduledStatus = grouping {
        ContentUnavailableView(
          "No Scheduled Transactions",
          systemImage: "calendar",
          description: Text(
            PlatformActionVerb.emptyStatePrompt(
              buttonLabel: "+",
              suffix: "to add a recurring transaction."
            )
          )
        )
      } else if let emptyState {
        ContentUnavailableView(
          emptyState.title,
          systemImage: emptyState.systemImage,
          description: Text(emptyState.description))
      } else {
        ContentUnavailableView(
          "No Transactions",
          systemImage: "tray",
          description: Text(
            PlatformActionVerb.emptyStatePrompt(
              buttonLabel: "+",
              suffix: "to add your first transaction."
            )
          )
        )
      }
    }
  }

  /// True when the list has nothing to render under the current grouping.
  /// `.scheduledStatus` reads from the store's pre-computed scheduled
  /// paths; everything else falls back to `filteredTransactions`.
  var isEmptyForCurrentGrouping: Bool {
    switch grouping {
    case .flat:
      return filteredTransactions.isEmpty
    case .scheduledStatus:
      return transactionStore.scheduledOverdueTransactions.isEmpty
        && transactionStore.scheduledUpcomingTransactions.isEmpty
    }
  }
}
