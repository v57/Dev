//
//  TranslationTrace.swift
//  Dev
//

import Foundation
import Observation

// MARK: - TranslationTrace

/// Diagnostic record of ONE single-row test: which model did what, what the
/// deterministic stages decided, and — for a reviewed row — what the learning
/// fold changed in which ContextDoc.
///
/// Owned by `LocalizationStore` and driven by the row inspector. A trace is
/// attached to `TranslationRouter` only while an inspection runs, so normal
/// runs pay nothing for it.
@MainActor
@Observable
final class TranslationTrace {
  /// What a step represents.
  enum Kind: String, Sendable {
    case candidate  // a model was selected
    case skip       // a candidate refused / cooled down
    case translate  // a batch or single translation call
    case gate       // the paid verification pass
    case learn      // a Stage-0 fold
    case memory     // TM / imported-DB resolution
    case write      // a value written to a record
    case note       // anything else worth showing

    var label: String {
      switch self {
      case .candidate: return "Model"
      case .skip: return "Skipped"
      case .translate: return "Translate"
      case .gate: return "Gate"
      case .learn: return "Learned"
      case .memory: return "Memory"
      case .write: return "Write"
      case .note: return "Note"
      }
    }

    var symbol: String {
      switch self {
      case .candidate: return "cpu"
      case .skip: return "hand.raised"
      case .translate: return "translate"
      case .gate: return "checkmark.seal"
      case .learn: return "graduationcap"
      case .memory: return "internaldrive"
      case .write: return "square.and.pencil"
      case .note: return "info.circle"
      }
    }
  }

  /// Which inspection was requested.
  enum Mode: String, Sendable {
    /// Untranslated / needs-review row: run the whole pipeline for this key.
    case fullRun = "Full run"
    /// Reviewed row: run only the learning fold and show the doc delta.
    case learning = "Learning"
    /// Mixed row: learn the reviewed slots, then translate the rest.
    case mixed = "Learn + run"
  }

  /// One timeline entry.
  struct Step: Identifiable, Sendable {
    let id = UUID()
    var kind: Kind
    var title: String
    /// Model label when a model was involved.
    var model: String?
    var provider: String?
    var isPaid: Bool?
    /// What went in (prompt context summary, lesson, memory hit…).
    var input: String?
    /// What came out.
    var output: String?
    /// ContextDoc content before the step (learning only).
    var before: String?
    /// ContextDoc content after the step (learning only).
    var after: String?
    var isFailure = false

    /// True when this step carries a doc delta worth showing.
    var hasDocumentDelta: Bool { before != nil || after != nil }
  }

  private(set) var key = ""
  private(set) var mode: Mode = .fullRun
  private(set) var steps: [Step] = []
  private(set) var isRunning = false
  private(set) var startedAt: Date?
  private(set) var finishedAt: Date?

  /// Models that actually served a call during this trace, in order.
  var modelsUsed: [String] {
    var seen: [String] = []
    for step in steps {
      guard let model = step.model, !seen.contains(model) else { continue }
      seen.append(model)
    }
    return seen
  }

  var failureCount: Int { steps.filter(\.isFailure).count }

  var duration: TimeInterval? {
    guard let startedAt, let finishedAt else { return nil }
    return finishedAt.timeIntervalSince(startedAt)
  }

  /// True once the run is over and every step succeeded.
  var isClean: Bool { !isRunning && failureCount == 0 }

  // MARK: lifecycle

  func begin(key: String, mode: Mode) {
    self.key = key
    self.mode = mode
    steps = []
    startedAt = .now
    finishedAt = nil
    isRunning = true
  }

  func add(_ step: Step) {
    steps.append(step)
  }

  func note(_ title: String, detail: String? = nil, isFailure: Bool = false) {
    add(Step(kind: .note, title: title, output: detail, isFailure: isFailure))
  }

  func finish() {
    isRunning = false
    finishedAt = .now
  }

  func reset() {
    key = ""
    steps = []
    startedAt = nil
    finishedAt = nil
    isRunning = false
  }

  /// Lines present on only one side, in file order. A line-based comparison is
  /// enough here: a Stage-0 fold appends lesson lines or rewrites one of them,
  /// it does not reflow the document. Pure, so it stays callable off-actor.
  nonisolated static func lineDiff(before: String, after: String) -> (added: [String], removed: [String]) {
    let beforeLines = before.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let afterLines = after.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let beforeSet = Set(beforeLines)
    let afterSet = Set(afterLines)
    return (
      added: afterLines.filter { !beforeSet.contains($0) },
      removed: beforeLines.filter { !afterSet.contains($0) })
  }
}
