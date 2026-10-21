//
//  TranslationStoreSettings.swift
//  Dev
//

import ComponentKit
import SwiftUI

// MARK: - Settings ▸ Advanced: Translation Store

/// The one destructive control the app has outside a project: it empties the
/// translation store for every project at once. It lives in Settings ▸ Advanced,
/// away from the everyday surfaces, and reaches the open window's stores through
/// `AppContext`.
///
/// DISABLED, not stopping anything, while a writer is in flight (see
/// `storeClearBlocker`): stopping a run is not a thing that happens instantly,
/// so a clear that stopped one could still race the write-back it had in flight.
struct ClearTranslationStoreSection: View {
  @State private var prompt: StoreClearPrompt?
  /// Re-read when the section appears; the stores live in the main window.
  @State private var blocker: String?

  var body: some View {
    let context = AppContext.shared
    FormRow(
      "Everything Dev learned from your reviews",
      help: context.localization == nil
        ? "Open the main window to clear the store."
        : "Clearing deletes the edit journal, context documents, translation memory and saved run positions for every project. Your project list and every .xcstrings file stay.",
      systemImage: "brain", hue: .purple, error: blocker
    ) {
      Button("Clear…", role: .destructive) { prompt = .confirm }
        .buttonStyle(.kit)
        .disabled(blocker != nil || context.localization == nil)
        .help("Clear Translation Store…")
    }
    .onAppear { refreshBlocker() }
    .alert(
      prompt?.title ?? "",
      isPresented: Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } })
    ) {
      if prompt == .confirm {
        Button("Cancel", role: .cancel) { prompt = nil }
        Button("Clear Store", role: .destructive) { clear() }
      } else {
        Button("OK") { prompt = nil }
      }
    } message: {
      Text(prompt?.message ?? "")
    }
  }

  private func refreshBlocker() {
    let context = AppContext.shared
    guard let localization = context.localization, let shell = context.shell else {
      blocker = nil
      return
    }
    blocker = storeClearBlocker(localization: localization, shell: shell)
  }

  /// Runs the clear, refreshes the sidebar's badges (they are record counts) and
  /// shows what the clear did.
  private func clear() {
    let context = AppContext.shared
    guard let localization = context.localization, let shell = context.shell else { return }
    Task {
      let outcome = await clearTranslationStore(localization: localization, shell: shell)
      context.sidebar?.refresh()
      prompt = .result(outcome)
      refreshBlocker()
    }
  }
}

/// What the Clear Translation Store control is showing: the confirmation, or the report.
enum StoreClearPrompt: Equatable {
  case confirm
  case result(StoreClearOutcome)

  var title: String {
    switch self {
    case .confirm: "Clear the translation store?"
    case .result(.cleared): "Translation store cleared"
    case .result(.alreadyEmpty): "Nothing to clear"
    case .result(.refused): "A writer is in flight"
    case .result(.failed): "Couldn't clear the translation store"
    }
  }

  var message: String {
    switch self {
    case .confirm:
      """
      This deletes every slot value, the journal of edits, the context documents, \
      the translation memory and the saved run positions — the app-side session, \
      for every project at once.

      It stays: the project list, and every .xcstrings file. A catalog keeps the \
      strings and the translations already written into it.

      What a re-scan cannot rebuild: the context documents and the translation \
      memory are what the app LEARNED from your corrections, and this deletes \
      them. Edits a window is still holding — anything not yet written to a file — \
      go with the session.

      Open catalogs re-read their files afterwards and read as untranslated work. \
      The rows go in ONE pass, so even a large store is emptied in a second or two.
      """
    case .result(.cleared(let counts)):
      "Removed \(counts.summary). Every project and every .xcstrings is still here."
    case .result(.alreadyEmpty):
      "There was nothing to delete: the store held no slot records, journal rows, "
        + "context documents, memory entries or run cursors. That is not an error."
    case .result(.refused(let reason)), .result(.failed(let reason)):
      reason
    }
  }
}

// MARK: - Clearing the store (Design notes 7.5)

/// What one press of the clear did. Every branch is a state the bar reports, so
/// the button never fails silently and a second press is never an error.
enum StoreClearOutcome: Equatable {
  /// The store held rows: this is what was deleted, per model.
  case cleared(StoreClearCounts)
  /// The store was already empty — the second press, which does nothing.
  case alreadyEmpty
  /// Nothing was touched: a writer is in flight.
  case refused(String)
  /// The delete or its save failed.
  case failed(String)
}

/// Why the clear cannot run right now, or nil when it can.
///
/// A WRITER in flight is the one hard reason (7.5): a run writes records into the
/// store as it goes, and an open's mirror writes a whole catalog's slots into it
/// behind the pane — so a clear that ran under either would leave a live writer
/// writing into a store that just emptied. The button is disabled on this AND the
/// flow refuses on it, so the safety does not depend on the button being the only
/// caller.
@MainActor
func storeClearBlocker(localization: LocalizationStore, shell: Translation.Shell) -> String? {
  if localization.isLoading {
    return "A catalog is opening — clear once it has landed"
  }
  if localization.isSyncing {
    return "The store is still catching up with a catalog — clear once it has"
  }
  if localization.scan.isRunning || localization.isAddingLanguage
    || shell.isRunning {
    return "A run is in flight — finish or cancel it first"
  }
  return nil
}

/// The clear itself, in the ONE order that is safe.
///
/// Everything the app holds OVER the store lets go FIRST, in this same
/// main-actor turn: an open pane's rows carry the record objects themselves, and
/// the redesign's workspaces were built from them, so rows deleted under a live
/// cache leave this window reading values that no longer exist. Then the rows go
/// — in `TranslationData.clearTranslationState()` — and then both halves
/// rebuild what they can: the browser re-reads its open artifact (no mirror, or
/// the records would come straight back), and the redesign's workspaces are rebuilt
/// from those artifacts. What
/// cannot be rebuilt is what was deleted, and 7.5 says so on screen before the
/// press.
@MainActor
@discardableResult
func clearTranslationStore(
  localization: LocalizationStore, shell: Translation.Shell
) async -> StoreClearOutcome {
  if let blocker = storeClearBlocker(localization: localization, shell: shell) {
    return .refused(blocker)
  }
  localization.dropStoreMirror()
  shell.dropStoreCaches()
  let counts = await TranslationData.shared.clearTranslationState()
  let outcome: StoreClearOutcome = counts.isEmpty ? .alreadyEmpty : .cleared(counts)
  // The app-side halves come back over the emptied store rather than keep the
  // readings they had.
  await localization.reloadAfterStoreClear()
  shell.rebuildAfterStoreClear()
  return outcome
}
