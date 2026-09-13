//
//  Stages.swift
//  Dev
//
//  Created by Dmitry on 12.09.26.
//
//  Design only: signatures with placeholder bodies that compile and change no
//  behaviour. Semantics are in "Design notes.md" beside this file.
//

import SwiftUI

enum Translation {
  // MARK: - budgets

  /// Every character budget in the redesign, in one place so the runner, the
  /// progress model and the prompt builder cannot drift apart.
  ///
  /// A context budget is a PROMPT budget: a document may exist at any size, but
  /// what a prompt sends is capped, and compression keeps the stored body under
  /// the cap so the truncation path does not fire. A batch budget is SOURCE
  /// characters on top of the context blocks. Batches are sized by characters
  /// and never by record count — the routed models carry very large context
  /// windows, so a grapheme count is accurate enough and free, and there is
  /// deliberately no tokenizer.
  enum Limits {
    /// Cross-project vocabulary. Nothing writes the global document yet, which
    /// is what makes its auto-enqueue harmless.
    static let globalContext = 10_000
    /// Human-authored prose rules for one project.
    static let projectContext = 10_000
    /// Accumulated lessons for one language — cross-key conventions only.
    /// Per-key knowledge lives in translation memory, which resolves an exact
    /// (source, key, value) hit with no prompt at all. That is why this one is
    /// small on purpose.
    static let languageContext = 1_000
    /// Source characters per translate request (vertical and horizontal).
    static let batch = 20_000
    /// Reference material carried into a language batch.
    static let neighbors = 10
    static let neighborCharacters = 400
    static let commentCharacters = 600
  }

  // MARK: - context documents

  /// A versioned context document: one global, one per project, one per
  /// language. Growth is autonomous and append-ordered; the character budget is
  /// kept by compression, not by truncation.
  @Observable @MainActor class Context: Identifiable {
    /// Which document this is. The id is DERIVED from the scope and never built
    /// by interpolating an object (`"\(project)"` prints the object, not its
    /// id).
    enum Scope: Hashable {
      case global
      /// Project-wide human rules — prose, no model call, an exact-line
      /// membership test. The widest blast radius after global.
      case project(String)
      /// One project's lessons for one language. Per project on purpose: a lesson
      /// is usually that project's own vocabulary, and one shared document per
      /// language code would flatten every project into the most generic lines it
      /// can agree on. The id carries both halves — `"project/<id>/language/<code>"`
      /// — and is still built from strings, never from an object.
      case language(project: String, code: String)
      var id: String {
        switch self {
        case .global: "global"
        case .project(let id): "project/\(id)"
        case .language(let project, let code): "project/\(project)/language/\(code)"
        }
      }
      var limit: Int {
        switch self {
        case .global: Limits.globalContext
        case .project: Limits.projectContext
        case .language: Limits.languageContext
        }
      }
    }

    /// Snapshot of the document versions a slot was produced against. 0 means
    /// "no document existed then", so 0 is older than any published version —
    /// that is what makes a first fold mark the rest of a column stale.
    nonisolated struct Version: Hashable, Sendable, Codable {
      var global: Int = 0
      var project: Int = 0
      var language: Int = 0
      static let none = Version()
      /// Stale when any scope that governs the slot moved past the stamp.
      func isStale(against current: Version) -> Bool {
        global < current.global || project < current.project || language < current.language
      }
    }

    let id: String
    let scope: Scope
    /// Where the body and the version are read and written. State is SwiftData, so
    /// the reads and writes below are synchronous — a fetch on the main actor, not
    /// a suspension point.
    let store: Store
    /// The body. Append-ordered, which is what makes tail-preserving truncation
    /// mean "the newest lessons survive".
    var context: String = ""
    /// Monotonic, starts at 1, bumped once per REAL change. A repeated lesson
    /// (an identical line) must NOT bump it: the version is what makes every
    /// other slot of that column stale, so a no-op write would re-bill the whole
    /// column.
    var version: Int = 1
    /// True when `loadContext()` found a stored document. The version number cannot
    /// express this: it starts at 1 either way, so without the flag an ABSENT
    /// document would look NEWER than every slot (stamp 0) and the heaviest paid
    /// pass would sweep a project nobody ever wrote a rule for.
    private(set) var hasDocument: Bool = false
    /// The version other objects may compare against. 0 means "no document has ever
    /// been written", which is what makes an absent document mark nothing stale
    /// (0 < 0 is false). Every staleness and freshness comparison uses THIS, never
    /// the raw `version`.
    var publishedVersion: Int { hasDocument ? version : 0 }
    var limit: Int
    init(scope: Scope, store: Store) throws {
      self.id = scope.id
      self.scope = scope
      self.store = store
      self.limit = scope.limit
      try loadContext()
    }
    /// Reads the stored body + version for this scope, and sets `hasDocument`. No
    /// document yet is an empty body at version 1 — absence is not a bump and marks
    /// nothing stale.
    private func loadContext() throws {

    }
    /// Writes body + version. Called only after a real change, and it is this write
    /// that carries the sentinel rule (see `Store`): SwiftData on this SDK crashes
    /// re-faulting an all-nil versions row, so a Version of all zeros is stored as
    /// the sentinel, never as three nils.
    func save() throws {

    }
    /// Appends one line, canonical for this scope: a language document carries
    /// `KEY<TAB>SOURCE<TAB>VALUE` (escaped, exactly three fields), deduped to one
    /// line per (key, source) with the newest value winning, and a cleared value
    /// RETRACTS its line. A project document carries plain prose rules. An append
    /// that changes nothing returns without bumping the version.
    func append(value: String) {
      version += 1
      if context.isEmpty {
        context = value
      } else {
        context += "\n\(value)"
      }
    }
    var isOverLimit: Bool { context.count > limit }
    /// The fallback, not the budget keeper: drops the OLDEST lines until the body
    /// fits. This is why document order is append-only.
    func truncateToLimit() {

    }
    /// One model call per over-budget document, run after every learn fold, so
    /// the STORED body fits what a prompt can send. ASYNC because it is a model
    /// call — the store read that follows it is not. Change-gated, for the same
    /// reason `append` is: a no-op rewrite must write nothing.
    func compressIfNeeded() async throws {
      guard context.count > limit else { return }
    }
  }

  // MARK: - global

  @Observable @MainActor class Global {
    /// The one store every object below borrows: SwiftData, main actor, sync.
    let store: Store
    /// The cross-project document.
    var context: Context
    /// The project registry, so the sidebar, the workspace and the runner all
    /// address the same objects. A project that is not open is not resident.
    var projects: [String: Project] = [:]
    init(store: Store) throws {
      self.store = store
      context = try Context(scope: .global, store: store)
    }
    func loadProject(id: String) throws -> Project {
      if let project = projects[id] {
        return project
      } else {
        let project = try Project(id: id, global: self)
        self.projects[id] = project
        return project
      }
    }
    /// Drops a project and its data from memory; everything it owns is already
    /// persisted in the store.
    func unloadProject(id: String) {
      projects[id] = nil
    }
    /// Persists the registry (ids and titles) — never a project's rows.
    func save() throws {

    }
  }

  // MARK: - project

  @Observable @MainActor class Project: Identifiable {
    unowned let global: Global
    let id: String
    /// Human-authored rules for this project.
    var context: Context
    /// Only the languages in play. A language that is in the catalog but not in
    /// this map is not translated, and its column is not shown.
    var languages: [String: Language] = [:]
    /// One entry per catalog key, in catalog order. The catalog key — not the
    /// array position — is the identity every operation carries.
    var data: [LocalizationKey] = []
    /// key -> position in `data`, so a result can be applied by key and
    /// re-checked against the scan's snapshot.
    var rowIndex: [String: Int] = [:]
    init(id: String, global: Global) throws {
      self.id = id
      self.global = global
      context = try Context(scope: .project(id), store: global.store)
      try loadLanguages()
    }
    /// The languages in play: what the store remembers for this project,
    /// intersected with what the user asked for (the Add Language overlay). A fetch,
    /// not a file read.
    private func loadLanguages() throws {

    }
    func addLanguage(_ code: String) throws -> Language {
      if let language = languages[code] { return language }
      let language = try Language(id: code, project: self)
      languages[code] = language
      return language
    }
    /// The artifact writes nothing: removing a language removes the app-side
    /// session for it, not the column (only Save writes the file).
    func removeLanguage(_ code: String) {
      languages[code] = nil
    }
    /// Builds the rows: the catalog's keys, projected onto what the store knows
    /// about them — the imported-database resolve (status `.imported`), the
    /// staleness stamps, the journal. The artifact's own values are the base state.
    ///
    /// SYNCHRONOUS, and deliberately: by the time this runs, Prepare has already
    /// opened and parsed the .xcstrings (that part is async and belongs to the
    /// catalog layer), so this is a fetch plus a projection.
    func loadData() throws {
      guard data.isEmpty else { return }
    }
    /// Writes the app-side session for this project to the store. Note what this
    /// does NOT do: it never writes the artifact — `Save` on the open catalog is the
    /// only writer of the `.xcstrings`.
    func saveData() throws {
      guard !data.isEmpty else { return }
    }
    func row(at index: Int) -> LocalizationKey? {
      data.indices.contains(index) ? data[index] : nil
    }
    func row(_ key: String) -> LocalizationKey? {
      rowIndex[key].flatMap { row(at: $0) }
    }
    func language(_ code: String) -> Language? { languages[code] }
    /// The stamp a slot written RIGHT NOW would carry — what the staleness
    /// computation compares against. Every scope goes through `publishedVersion`, so
    /// a scope with no stored document contributes 0 and can never make a slot look
    /// stale; that is the difference between "the rule changed under this value" and
    /// "nobody has written a rule yet".
    func currentVersion(for language: String) -> Context.Version {
      Context.Version(
        global: global.context.publishedVersion,
        project: context.publishedVersion,
        language: languages[language]?.context.publishedVersion ?? 0)
    }
    /// A language-document bump auto-enqueues (that is how a lesson re-applies to the
    /// rest of the column); a project-document bump deliberately does NOT — it would
    /// sweep every record of the project, and reaches existing slots only through an
    /// explicit run the user asked for.
    func verticalPrelearn() throws -> VerticalPrelearn {
      try loadData()
      return VerticalPrelearn(project: self)
    }
    func verticalLearn() throws -> VerticalLearn {
      try loadData()
      return VerticalLearn(project: self)
    }
    func verticalTranslate() throws -> VerticalTranslate {
      try loadData()
      return VerticalTranslate(project: self)
    }
    func horizontalTranslate() throws -> HorizontalTranslate {
      try loadData()
      return HorizontalTranslate(project: self)
    }
  }

  // MARK: - language

  @Observable @MainActor class Language {
    let id: String
    unowned let project: Project
    /// This language's accumulated lessons.
    var context: Context
    var global: Global { project.global }
    init(id: String, project: Project) throws {
      self.id = id
      self.project = project
      context = try Context(scope: .language(project: project.id, code: id), store: project.global.store)
    }
    /// Every slot of this language, projected from the project's rows — what a
    /// column renders and what a stage scans.
    var slots: [LocalizationString] {
      project.data.flatMap { row in row.targets.filter { $0.language == id } }
    }
    /// The aggregate a language column shows, so the work is visible without
    /// opening a stage.
    struct Progress {
      var needsTranslate: Int = 0
      var stale: Int = 0
      var translated: Int = 0
      var imported: Int = 0
      var verified: Int = 0
      var ignored: Int = 0
      var total: Int = 0
    }
    var progress: Progress { Progress() }
  }

  // MARK: - rows

  /// One catalog key and its slots.
  struct LocalizationKey: Hashable, Identifiable {
    /// The `strings` dictionary key. This — not the array position — is the
    /// identity the artifact, the imported database and the memory all address.
    let key: String
    /// Source body, in the catalog's source language. May be empty when the
    /// artifact carries no source unit — see `content`.
    let source: StringBody
    /// The text a request actually sends for this row. The catalog KEY is never
    /// sent to a model: it never matters to the translation. So a row whose source
    /// is missing falls back to the key as its content, which is exactly what the
    /// artifact shows when it has no source unit.
    ///
    /// Everything downstream uses this — the batch budget, the prompt, the lesson
    /// line, the width comparison. `source` stays the authored value, and stays
    /// empty when nothing was authored.
    var content: StringBody { source.isEmpty ? .value(key) : source }
    /// Developer comment attached to the key: where the string appears, plus any
    /// length or register hint.
    let comment: String
    /// Reviewer's width guideline, in characters; 0 = none. REVIEW SIDE ONLY: it
    /// is never sent to the translator, because a width constraint in a
    /// translation prompt degrades the translation. It reaches a model only for a
    /// candidate that is already over.
    let maxWidth: Int
    /// `shouldTranslate != false`. An ignored key is out of scope for every
    /// stage and keeps whatever value it carries.
    var translatable: Bool = true
    var targets: [LocalizationString]
    var id: String { key }
    func target(_ language: String) -> LocalizationString? {
      targets.first { $0.language == language }
    }
    func index(of language: String) -> Int? {
      targets.firstIndex { $0.language == language }
    }
    mutating func setTarget(_ value: LocalizationString, for language: String) {

    }
    /// One row needs work as soon as one of its slots does — which is what makes
    /// a row a candidate for the horizontal (one request, every language) pass.
    var needsMachineTranslate: Bool {
      targets.contains(where: { $0.needsMachineTranslate })
    }
  }

  /// One (key, language) slot. A plural slot is the same object as a flat one:
  /// its bodies are plural bodies, and its status covers the WHOLE slot — Xcode
  /// treats a plural like any other string, so "reviewed" and "needs translation"
  /// are properties of the (key, language) pair and not of an individual form.
  /// There is deliberately no per-form status map.
  struct LocalizationString: Hashable, Identifiable {
    var id: String { language }
    let language: String
    /// What the machine produced. Written by prelearn and by the translate
    /// stages; a human edit never touches it. It exists so that `learn` has
    /// something to compare the human's value with.
    var machine: StringBody = .empty
    /// What the artifact holds now — what ships and what the human sees.
    var target: StringBody = .empty
    /// The value at the moment a human confirmed the slot. A SNAPSHOT, not a
    /// copy of the target: a later human edit makes `target != reviewed`, which
    /// re-arms learning for this slot.
    var reviewed: StringBody?
    var status: Status = .stale
    /// The document versions this value was produced against. Staleness is this
    /// comparison and never a guess; a single Int cannot express it, because
    /// three scopes bump independently.
    var versions: Context.Version = .none
    /// Nothing to teach: the model already agreed with the human, or the slot has
    /// not moved since it was confirmed. Requires machine output, so it is
    /// disjoint from `needsPrelearn` by construction — which is what makes
    /// "prelearn, then learn, then translate" a total order.
    var toLearn: StringBody? {
      guard status == .verified else { return nil }
      guard !machine.isEmpty, !target.isEmpty else { return nil }
      guard machine != target else { return nil }
      guard let reviewed else { return target }
      guard reviewed != target else { return nil }
      return target
    }
    /// A human settled this slot with no machine output on record, so there is
    /// nothing to diff. Prelearn asks for a machine version of the SOURCE first
    /// and writes it to `machine` only — never to `target`, never to `status`:
    /// the human owns the value.
    var needsPrelearn: Bool {
      status == .verified && !target.isEmpty && machine.isEmpty
    }
    /// Work to do. `.stale` counts: a language-document bump is exactly what
    /// makes the rest of that column stale, and a slot that is skipped here never
    /// picks the new lesson up. `.ignore` and `.verified` never enter a run, and
    /// `.imported` arrives already usable (the horizontal pass does not resolve
    /// through the imported database at all).
    var needsMachineTranslate: Bool {
      status == .needsTranslate || status == .stale
    }
    enum Status {
      /// The value predates the documents that govern it. Also what the artifact
      /// says when it knows a source changed under a value. App-side knowledge:
      /// we never write `stale` back.
      case stale
      /// `shouldTranslate == false`: out of scope, the value is kept.
      case ignore
      /// No value yet (an absent unit, or the artifact says `new`).
      case needsTranslate
      /// Machine output, unreviewed. The artifact calls this `needs_review`.
      case translated
      /// A shipped human translation from the imported database: usable without a
      /// model call, unreviewed, and never written back as `imported`. Kept
      /// distinct from `.translated` (and shown in its own colour) because the
      /// reviewer has to know whether the value came from our model or from the
      /// database we import.
      case imported
      /// A human confirmed this value. Nothing else ever produces it. The
      /// artifact calls this `translated` (Xcode's word for human-approved — the
      /// two names that twist).
      case verified
    }
  }

  /// The text of a slot in one language: a flat value, or a plural set.
  enum StringBody: Hashable {
    case value(String)
    case plural(Plurals)
    static var empty: StringBody { .value("") }
    init(catalogValue: String, language: String) {
      self = .value(catalogValue)
    }
    var characters: Int {
      switch self {
      case .value(let value): value.count
      case .plural(let value): value.count
      }
    }
    var isEmpty: Bool {
      switch self {
      case .value(let value): value.isEmpty
      case .plural(let value): value.isEmpty
      }
    }
    /// The flat text, when this is a flat body; nil for a plural slot.
    var value: String? {
      switch self {
      case .value(let value): value
      case .plural: nil
      }
    }
    /// What the artifact stores for this body: the flat text, or the plural form
    /// the catalog model already picks (`other` wins, else the first filled).
    var catalogValue: String {
      switch self {
      case .value(let value): value
      case .plural(let plural): plural.values.first { $0.rule == .other }?.value ?? ""
      }
    }
    /// `%@`, `%1$@`, `%lld`, … Validation compares the multiset per item, so a
    /// dropped or duplicated placeholder never reaches the paid gate.
    var placeholders: [String] { [] }
  }

  // MARK: - operations

  /// The operations a run is made of.
  ///
  /// A TRANSLATE run is one button that performs `prepare -> prelearn -> learn ->
  /// vertical`, in that order: preparation settles the rows (scan, merge the
  /// catalog, load the session data, resolve the imported database — no model
  /// call), prelearn supplies the machine record a human-verified slot is missing,
  /// learn folds what the human changed into the project's language document, and
  /// only then is the column translated. They are ordered operations of ONE run,
  /// not passes the user triggers separately.
  ///
  /// `horizontal` is the exception: a run of its own (prepare -> horizontal),
  /// because a project-document bump deliberately enqueues nothing and applying a
  /// rule to values written before it is a paid sweep the user asks for.
  enum Stage: String, CaseIterable, Identifiable {
    case prepare
    case prelearn
    case learn
    case vertical
    case horizontal
    var id: String { rawValue }
    var title: String {
      switch self {
      case .prepare: "Prepare"
      case .prelearn: "Prelearn"
      case .learn: "Learn"
      case .vertical: "Translate"
      case .horizontal: "Translate by row"
      }
    }
  }

  /// One unit of work a stage hands to the runner.
  ///
  /// The target language is NOT on the operation: a vertical operation inherits it
  /// from its batch (one request carries one language's L1 block), and a row
  /// operation names it per item through `targets`. `key` is what a reply is
  /// matched and applied by; `index` is only a position in the scan's snapshot.
  protocol Operation {
    /// Catalog key of the row this came from.
    var key: String { get }
    /// Which stage produced it — the runner routes, reports and applies per
    /// stage.
    var stage: Stage { get }
    /// Scan-time position in `project.data`, pinned to the scan's snapshot. Rows
    /// that appear mid-run are picked up by the NEXT scan, never patched into a
    /// batch that is already in flight.
    var index: Int { get }
    var characters: Int { get }
  }

  /// A per-language unit: one source body translated into one target body in one
  /// request (prompt shape L0 -> L1 -> L2).
  ///
  /// What the request carries per item, and nothing else: `comment`, `maxWidth`,
  /// `source` and `target`. NOT the key — it never matters to a translation, so the
  /// wire never sees it. The key is app-side: it is what applies the reply, what
  /// addresses memory, and what the journal records.
  ///
  /// `source` here is the row's `content` (the key stands in when nothing was
  /// authored), and `target` is the current value when there is one — or the empty
  /// plural skeleton of the target language, so the model knows which forms it is
  /// being asked to fill.
  protocol VerticalOperation: Operation {
    var source: StringBody { get }
    var target: StringBody { get }
  }

  /// A row unit: one source body, translated into EVERY language of the row in one
  /// request (prompt shape L0 -> ITEMS, the language named per item).
  ///
  /// No selection on this shape. The payload is the whole row — settled columns
  /// included, because a value the project has already committed to is the strongest
  /// evidence of the register and terminology it uses — and what may be WRITTEN is
  /// decided when the reply is applied: a `.verified` or `.imported` slot is never
  /// overwritten. A settled value is context, not a target.
  protocol RowOperation: Operation {
    var source: StringBody { get }
    /// Every language of the row, in column order: the payload the request asks for.
    var targets: [LocalizationString] { get }
  }
}

extension Translation.VerticalOperation {
  var characters: Int {
    source.characters + target.characters
  }
}

extension Translation.RowOperation {
  /// Every language of the row is one item in the same request, so the source is
  /// paid for once per language — the settled ones included, since they are asked
  /// for as context. That is the deliberate price of row-wide consistency, and the
  /// write-back is what keeps it from being a rewrite of finished work.
  var characters: Int {
    source.characters * targets.count
  }
}
