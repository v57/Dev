//
//  TranslateRunProgress.swift
//  Dev
//
//  Created by Dmitry on 08.09.26.
//

import Foundation
import Observation

// MARK: - TranslateStage

/// The phase a Translate run is in. UI (C-4) renders the footer from this;
/// the orchestrator advances it between stages and ticks per record.
enum TranslateStage: String, CaseIterable, Sendable {
  /// Preparing the run's scope: the plural-form skeleton (see
  /// `Reconcile.ensurePluralForms`). Runs BEFORE the pipeline, off the main
  /// actor, and is reported through the same progress surface.
  case pluralForms
  case stage0Learn
  case tmResolve
  case dbResolve
  /// The one AI stage: Muse (OpenCode Go) translates every remaining record.
  case translate
  case done

  /// Human-readable label for logs and the progress footer.
  var label: String {
    switch self {
    case .pluralForms:
      return "Plural forms"
    case .stage0Learn:
      return "Learn (Stage 0)"
    case .tmResolve:
      return "Translation memory"
    case .dbResolve:
      return "Imported DB"
    case .translate:
      return "Translate"
    case .done:
      return "Done"
    }
  }
}

// MARK: - TranslateRunProgress

/// Per-run progress + cancellation surface, one instance per Translate run.
/// Lives on the main actor (the module default): the orchestrator updates it
/// between records and the UI reads it from a SwiftUI observation point.
@Observable
final class TranslateRunProgress {
  /// Current phase.
  private(set) var stage: TranslateStage = .stage0Learn
  /// Records queued for the current phase.
  private(set) var total = 0
  /// Records finished in the current phase.
  private(set) var completed = 0
  /// Records that failed in the current phase.
  private(set) var failed = 0
  /// Record currently being processed ("ru.someKey").
  private(set) var currentKey: String?
  /// Rolling log of stage notes and per-record failures (UI-safe text).
  private(set) var log: [String] = []
  /// Set by the UI's Cancel button; checked between records/chunks.
  var isCancelled = false

  // MARK: stage transitions

  func begin(_ stage: TranslateStage, total: Int = 0, note: String? = nil) {
    self.stage = stage
    self.total = total
    completed = 0
    failed = 0
    currentKey = nil
    if let note {
      appendLog(note)
    }
  }

  /// One record finished successfully.
  func tick(key: String?) {
    currentKey = key
    completed += 1
  }

  /// Absolute progress for work that reports in batches from off the main
  /// actor (the plural-skeleton scan): the background pass yields
  /// completed/total pairs instead of ticking once per record.
  func report(completed: Int, key: String?) {
    self.completed = completed
    currentKey = key
  }

  /// One record finished with an error. `message` must be UI-safe
  /// (BackendError.errorDescription never carries secrets).
  func fail(key: String?, message: String) {
    currentKey = key
    failed += 1
    appendLog("\(stage.label): \(key.map { "\($0) — " } ?? "")\(message)")
  }

  /// Free-form stage note (not a failure).
  func note(_ message: String) {
    appendLog(message)
  }

  func cancel() {
    isCancelled = true
    appendLog("Cancelled by user")
  }

  /// Clears a previous run's cancellation. `begin` deliberately does NOT touch
  /// this — a cancel that arrives while a stage is winding down must stick —
  /// so whoever starts a NEW unit of work clears it explicitly.
  func resetCancellation() {
    isCancelled = false
  }

  // MARK: helpers

  private func appendLog(_ line: String) {
    log.append(line)
    if log.count > 200 {
      log.removeFirst(log.count - 200)
    }
  }
}

// MARK: - PipelineRunSummary

/// Machine-readable result of one Translate run. The UI (C-4) can show a
/// compact summary line ("3 learned, 12 TM hits, 41 translated, 2 failed").
nonisolated struct PipelineRunSummary: Sendable {
  // Stage 0 learn
  var learnedFolds = 0        // context docs actually changed (audit + version bump)
  var learnedCovered = 0      // lesson already in the doc / no change needed
  var contextBumps = 0        // == learnedFolds (version bumps)
  // TM resolve
  var tmResolvedGold = 0      // reviewed TM entry copied -> record reviewed
  var tmResolvedHints = 0     // machine-only TM entry copied -> needs_review hint
  // Imported-DB resolve (Phase D)
  var dbFilled = 0            // empty slot filled from the imported DB
  var dbUpgraded = 0          // machine value replaced/promoted by a DB hit
  // Translate — the only AI stage (model router: Muse on OpenCode Go)
  var translatedFilled = 0    // empty slot got a model translation
  var translatedRewritten = 0 // existing machine value replaced by the model
  /// Values the paid verification gate corrected.
  var translatedGateFixes = 0
  // Common
  var failures: [String] = []
  var cancelled = false

  /// Every record whose value/provider/state the run wrote.
  var recordsTouched: Int {
    tmResolvedGold + tmResolvedHints + dbFilled + dbUpgraded
      + translatedFilled + translatedRewritten
  }
}
