// MoolahTests/Features/Sync/SyncedAccountHeaderSyncButtonTests.swift
import Foundation
import Testing

@testable import Moolah

/// Pure-logic tests for the sync-button facet of `SyncedAccountHeaderLogic`:
/// the `WalletSyncProgress` → `SyncButtonProgress` mapper that decides
/// between the determinate bar, the indeterminate spinner, and the idle
/// label, plus the tooltip and the split VoiceOver label / value the view
/// renders from that state. Kept in its own `@Suite` file so the primary
/// `SyncedAccountHeaderLogicTests` struct stays under the type-body-length
/// ceiling.
@Suite("SyncedAccountHeaderLogic sync button")
struct SyncedAccountHeaderSyncButtonTests {
  // MARK: - Sync button progress (determinate/indeterminate mapping)

  @Test("Not syncing yields .none regardless of a stale progress value")
  func syncButtonProgressNoneWhenNotSyncing() {
    #expect(
      SyncedAccountHeaderLogic.syncButtonProgress(isSyncing: false, progress: nil) == .none)
    #expect(
      SyncedAccountHeaderLogic.syncButtonProgress(
        isSyncing: false, progress: .scanning(fraction: 0.5)) == .none)
  }

  @Test("Syncing with a scanning fraction yields determinate with that fraction")
  func syncButtonProgressDeterminateWhenScanning() {
    #expect(
      SyncedAccountHeaderLogic.syncButtonProgress(
        isSyncing: true, progress: .scanning(fraction: 0.42)) == .determinate(0.42))
  }

  @Test("Syncing with .indeterminate progress yields indeterminate")
  func syncButtonProgressIndeterminateWhenExplicit() {
    #expect(
      SyncedAccountHeaderLogic.syncButtonProgress(isSyncing: true, progress: .indeterminate)
        == .indeterminate)
  }

  @Test("Syncing with no progress value yet yields indeterminate")
  func syncButtonProgressIndeterminateWhenNilProgress() {
    #expect(
      SyncedAccountHeaderLogic.syncButtonProgress(isSyncing: true, progress: nil)
        == .indeterminate)
  }

  // MARK: - Sync button tooltip (.help)

  @Test("In-flight sync tooltip says the sync is in progress, not an action")
  func helpWhileSyncing() {
    // Highest precedence: even with a credential and Option held, an
    // in-flight sync reports its state rather than a tap-able action.
    #expect(
      SyncedAccountHeaderLogic.syncButtonHelp(
        isSyncing: true, hasCredential: true, optionHeld: true, missingCredentialHint: "Add a key")
        == "Sync in progress…")
  }

  @Test("Idle tooltip mirrors the sync/resync action per the Option key")
  func helpWhenIdleWithCredential() {
    #expect(
      SyncedAccountHeaderLogic.syncButtonHelp(
        isSyncing: false, hasCredential: true, optionHeld: false, missingCredentialHint: nil)
        == "Sync account now")
    #expect(
      SyncedAccountHeaderLogic.syncButtonHelp(
        isSyncing: false, hasCredential: true, optionHeld: true, missingCredentialHint: nil)
        == "Resync full history now")
  }

  @Test("Missing-credential tooltip prefers the hint, else a configure fallback")
  func helpWhenMissingCredential() {
    #expect(
      SyncedAccountHeaderLogic.syncButtonHelp(
        isSyncing: false, hasCredential: false, optionHeld: false,
        missingCredentialHint: "Add an Alchemy API key to enable sync.")
        == "Add an Alchemy API key to enable sync.")
    #expect(
      SyncedAccountHeaderLogic.syncButtonHelp(
        isSyncing: false, hasCredential: false, optionHeld: false, missingCredentialHint: nil)
        == "Configure this account to enable sync")
  }

  // MARK: - Sync button accessibility label (stable identity)

  @Test("Both in-progress states keep the stable 'Syncing in progress' label")
  func accessibilityLabelWhileSyncingIsStable() {
    // The changing percentage rides on the value, not the label, so the
    // label must not churn as an indeterminate scan resolves to a
    // determinate one — both report the same wording.
    #expect(
      SyncedAccountHeaderLogic.syncButtonAccessibilityLabel(.indeterminate, optionHeld: false)
        == "Syncing in progress")
    #expect(
      SyncedAccountHeaderLogic.syncButtonAccessibilityLabel(.determinate(0.42), optionHeld: false)
        == "Syncing in progress")
    // Option-key state is irrelevant while syncing.
    #expect(
      SyncedAccountHeaderLogic.syncButtonAccessibilityLabel(.determinate(0.42), optionHeld: true)
        == "Syncing in progress")
  }

  @Test("Idle label mirrors the sync/resync action per the Option key")
  func accessibilityLabelNoneMirrorsAction() {
    #expect(
      SyncedAccountHeaderLogic.syncButtonAccessibilityLabel(.none, optionHeld: false)
        == "Sync account now")
    #expect(
      SyncedAccountHeaderLogic.syncButtonAccessibilityLabel(.none, optionHeld: true)
        == "Resync full history now")
  }

  // MARK: - Sync button accessibility value (frequently-updating percent)

  @Test("Determinate progress exposes a whole-percent VoiceOver value")
  func accessibilityValueDeterminateReadsPercent() {
    let value = SyncedAccountHeaderLogic.syncButtonAccessibilityValue(for: .determinate(0.42))
    // Locale formats the percent symbol/grouping; pin only the digits and
    // that a percent representation is present, not a locale-specific glyph.
    #expect(value?.contains("42") == true)
    #expect(value == 0.42.formatted(.percent.precision(.fractionLength(0))))
  }

  @Test("Determinate value is whole-number precision (no fractional percent)")
  func accessibilityValueDeterminateIsWholeNumber() {
    let value = SyncedAccountHeaderLogic.syncButtonAccessibilityValue(for: .determinate(0.426))
    #expect(value == 0.426.formatted(.percent.precision(.fractionLength(0))))
    // Full and empty extremes round-trip through the same formatter.
    #expect(
      SyncedAccountHeaderLogic.syncButtonAccessibilityValue(for: .determinate(1.0))
        == 1.0.formatted(.percent.precision(.fractionLength(0))))
    #expect(
      SyncedAccountHeaderLogic.syncButtonAccessibilityValue(for: .determinate(0.0))
        == 0.0.formatted(.percent.precision(.fractionLength(0))))
  }

  @Test("Non-determinate states have no accessibility value")
  func accessibilityValueAbsentWhenNotDeterminate() {
    #expect(SyncedAccountHeaderLogic.syncButtonAccessibilityValue(for: .indeterminate) == nil)
    #expect(SyncedAccountHeaderLogic.syncButtonAccessibilityValue(for: .none) == nil)
  }
}
