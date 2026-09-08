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
  case stage0Learn
  case tmResolve
  case stage1Apple
  case stage2Ollama
  case stage3Deepseek
  case done

  /// Human-readable label for logs and the progress footer.
  var label: String {
    switch self {
    case .stage0Learn:
      return "Learn (Stage 0)"
    case .tmResolve:
      return "Translation memory"
    case .stage1Apple:
      return "Apple (Stage 1)"
    case .stage2Ollama:
      return "Ollama (Stage 2)"
    case .stage3Deepseek:
      return "DeepSeek (Stage 3)"
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
  // Stage 1 Apple
  var stage1Filled = 0
  // Stage 2 Ollama
  var stage2Filled = 0
  var stage2Corrected = 0     // Apple value changed by Ollama (apple -> ollama edit)
  // Stage 3 DeepSeek
  var stage3Filled = 0
  var stage3Reviewed = 0      // machine value changed by DeepSeek final review
  // Common
  var failures: [String] = []
  var cancelled = false

  /// Every record whose value/provider/state the run wrote.
  var recordsTouched: Int {
    tmResolvedGold + tmResolvedHints + stage1Filled + stage2Filled
      + stage2Corrected + stage3Filled + stage3Reviewed
  }
}
