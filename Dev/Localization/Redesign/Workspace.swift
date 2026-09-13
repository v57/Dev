//
//  Workspace.swift
//  Dev
//
//  Created by Dmitry on 13.09.26.
//
//  Design only: signatures with placeholder bodies that compile and change no
//  behaviour. Semantics are in "Design notes.md", section 8.
//
//  The surfaces the redesign's stages need: the rail, the language columns, the
//  run controls, and the human actions that are the ONLY producer of a verified
//  slot. A run's edits live here until Save — a run never writes the artifact.
//

import SwiftUI

extension Translation {
  /// One project's translation workspace. It owns the runner; the project owns the
  /// rows; the artifact owns the truth.
  @Observable @MainActor class Workspace {
    let project: Project
    let store: Store
    let runner: Runner

    /// Which run the rail shows. Translating is ONE button: it runs
    /// prepare -> prelearn -> learn -> translate, and the rail shows each
    /// operation's progress as a step of that run. Applying rules is a separate,
    /// explicit, paid run (prepare -> horizontal) with its own confirmation.
    var stage: Stage = .vertical
    /// Languages shown as columns. A language that is in play but hidden is STILL
    /// translated by a run: selection is a view filter, never a scope.
    var shownLanguages: [String] = []
    /// Selected catalog keys — also what a forced horizontal pass runs on.
    var selection: Set<String> = []
    /// App-side edits that are not in the artifact yet. A run makes this true.
    var isDirty: Bool = false
    /// What went wrong, for the alert.
    var error: String?

    init(project: Project, store: Store) {
      self.project = project
      self.store = store
      self.runner = Runner(project: project)
    }

    // MARK: - presentation

    /// The stage pages are a CLOSABLE OVERLAY, not a page of the app. Closing it must
    /// not stop a run — a long sweep is exactly the thing the user wants to dismiss
    /// and watch from the status bar.
    var isOverlayPresented = true
    /// What the bottom status bar shows while the overlay is closed, and where a
    /// reopen lands.
    var status = Status()
    struct Status {
      var isRunning = false
      /// The run the bar is reporting on.
      var run: Stage = .vertical
      /// The step it is on now, if any — what the overlay scrolls to on reopen.
      var step: Stage?
      var done = 0
      var total = 0
      var failures = 0
      var summary: String { "" }
    }
    func closeOverlay() {
      isOverlayPresented = false
    }
    func reopenOverlay() {
      isOverlayPresented = true
    }

    // MARK: - runs

    /// THE ONE BUTTON. Runs the main flow's whole plan in order — prepare, prelearn,
    /// learn, translate, then the row pass — instead of walking stages one at a time.
    /// The row pass is ALWAYS part of it (10.17 resolved): after the columns are
    /// translated it is what adapts machine output to anything a human has verified,
    /// so pressing this again once a verification session is over is how those
    /// corrections reach the rest of the project.
    ///
    /// It is impossible to start twice: a run already in flight is resumed, not
    /// stacked.
    func start() async throws {

    }

    /// Loads the rows, the language documents and the last cursor, then applies
    /// the imported-database resolve. Workspace open is the one place a project's
    /// rows are read.
    func open() async throws {

    }

    // MARK: - runs

    /// Runs a stage's plan: `vertical` is prepare -> prelearn -> learn -> translate
    /// -> the row pass (prelearn, learn and the row pass are operations OF that run,
    /// not controls of their own), and `horizontal` alone re-runs just the sweep.
    /// A run needs a usable provider before it starts, so an unconfigured app fails at
    /// the button instead of per batch.
    func run(_ stage: Stage) async throws {

    }
    func pause() {

    }
    func resume() async throws {

    }
    func cancel() {

    }
    /// How many slots the horizontal pass would touch, for the confirmation that
    /// names the cost before it is paid.
    var horizontalCandidateCount: Int { 0 }

    // MARK: - review

    /// The human actions. `confirm` is the only writer of `.verified`; nothing else
    /// in the system may promote a slot, and a rule cannot reach a verified slot
    /// until it is marked needs-review again.
    func confirm(key: String, language: String) {

    }
    func confirmRow(_ key: String) {

    }
    func markNeedsReview(key: String, language: String) {

    }
    /// `shouldTranslate = false`. The value is kept — ignoring a key is not
    /// deleting its translation.
    func setTranslatable(_ translatable: Bool, key: String) {

    }

    // MARK: - editing

    func setValue(_ value: StringBody, key: String, language: String) {

    }
    func setPluralValue(_ value: String, key: String, language: String, rule: Plural.Rule) {

    }
    /// A note is a memo for humans, or a project RULE that the translator follows.
    /// A memo never reaches a document or a model.
    func setNote(_ note: String?, scope: NoteScope, key: String) {

    }
    /// The reviewer's guideline. Review side only: it never enters a prompt except
    /// as a gate input for an item that is already over it.
    func setMaxWidth(_ width: Int?, key: String) {

    }

    enum NoteScope {
      /// Stored on the row, shown in the app, sent to nobody.
      case memo
      /// Folded into the project document as a rule the translator follows.
      case projectRule
    }

    // MARK: - persistence

    /// Save is the only writer of the `.xcstrings`, and it writes through the
    /// catalog model the app already has (format validation, in-memory catalog,
    /// then the file). The store is written after it — and unlike the store, this
    /// is async, because the file is.
    func save() async throws {

    }
    /// Closing with unsaved edits owes the user the same three-way contract as
    /// today: save, discard, or stay.
    func resolveLeave(_ choice: LeaveChoice) async {

    }
    enum LeaveChoice {
      case save
      case discard
      case stay
    }
  }
}
