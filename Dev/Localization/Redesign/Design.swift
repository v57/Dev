//
//  Stages.swift
//  Dev
//
//  Created by Dmitry on 12.09.26.
//
//  Design only: signatures with placeholder bodies that compile and change no
//  behaviour. Semantics are in docs/Translation design notes.md.
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
    static let batch = 10_000
    /// Model-response RETRIES after a batch's first attempt (5.9): a retryable failure
    /// re-asks the same request, so one batch costs at most `retries + 1` sends.
    ///
    /// It is a floor, not a chain: retries exist so one flaky answer does not cost a
    /// batch, and they END — the batch fails after them exactly as it did before the
    /// loop existed. Only a failure the run already calls `retryable` is re-asked; a
    /// non-retryable one is not retried into the ground.
    static let retries = 3
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
      /// The language code of a language document, nil for the two prose scopes.
      /// A document's format is its scope's (3.7): lesson lines are a language
      /// document's, so only a language document has a compression shape, and a
      /// caller doing the format's work asks this instead of re-deriving the id.
      var languageCode: String? {
        switch self {
        case .global, .project: nil
        case .language(_, let code): code
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
    /// Where the body and the version are read and written. State is held in memory
    /// (`TranslationData`), so the reads and writes below are synchronous lookups, not
    /// suspension points.
    let store: Store
    /// The client a compression call goes out through. A document does not own a run,
    /// so it takes the client it is handed and otherwise makes its own: a `Router` is
    /// a model id plus its pacing state, and `Router.stream` is the redesign's only
    /// transport, so there is no second way to make the call. A runner that has a
    /// client of its own hands it in, which is what would put the tokens a
    /// compression spends into that run's tally; until a runner does, the call still
    /// reaches Muse and still parks Muse when it is refused, and only the telemetry
    /// stays out of the run's report.
    private let router: Router
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
    init(scope: Scope, store: Store, router: Router? = nil) throws {
      self.id = scope.id
      self.scope = scope
      self.store = store
      self.router = router ?? Router()
      self.limit = scope.limit
      try loadContext()
    }
    /// Reads the stored body + version for this scope, and sets `hasDocument`. No
    /// document yet is an empty body at version 1 — absence is not a bump and marks
    /// nothing stale.
    ///
    /// The read is `Store.document(_:)`: a fetch on the main actor, which is why this
    /// is `throws` and not `async throws` (7.1). What it must NOT do is invent a
    /// version: a scope nothing was ever written for publishes 0 through
    /// `publishedVersion`, and that is the whole reason `hasDocument` is stored
    /// beside the number.
    private func loadContext() throws {
      guard let document = try store.document(scope) else {
        context = ""
        version = 1
        hasDocument = false
        return
      }
      context = document.content
      // A stored row carries a real version; the floor is for the all-nil corner a
      // legacy write could leave behind (versions start at 1 everywhere else).
      version = max(1, document.version)
      hasDocument = true
    }
    /// Writes body + version. Called only after a real change, and it is this write
    /// that carries the sentinel rule (see `Store`): a Version of all zeros is stored as
    /// the sentinel, never as three nils.
    func save() throws {
      try store.saveDocument(scope, body: context, version: version)
    }
    /// Appends one line, canonical for this scope: a language document carries
    /// `KEY<TAB>SOURCE<TAB>VALUE` (escaped, exactly three fields), deduped to one
    /// line per (key, source) with the newest value winning, and a cleared value
    /// RETRACTS its line. A project document carries plain prose rules. An append
    /// that changes nothing returns without bumping the version.
    func append(value: String) {
      let incoming = Self.lines(in: value)
      guard !incoming.isEmpty else { return }
      let existing = Self.lines(in: context)
      let merged = Self.merging(existing: existing, incoming: incoming, scope: scope)
      // The change gate. It is what makes a repeated lesson a no-op: the version is
      // what marks the rest of that column stale, so re-learning a lesson must not
      // re-bill the column.
      guard merged != existing else { return }
      context = merged.joined(separator: "\n")
      version += 1
      // The body just became real, so the document EXISTS from here on: a scope that
      // published 0 because nothing had ever been written publishes its version the
      // moment it has one, and that is what makes the appended lesson mark the rest of
      // the column stale.
      hasDocument = true
      // `append` is deliberately not a throwing call — the runner folds a reply into a
      // document without a `try`, and neither caller (a fold, a project rule) has
      // anywhere to report a store failure. A write that fails therefore leaves the
      // new body and the bumped version in memory, unpublished; the next write of this
      // document (another fold, a compression, Save) persists them.
      try? save()
    }
    var isOverLimit: Bool { context.count > limit }
    /// The fallback, not the budget keeper: drops the OLDEST lines until the body
    /// fits. This is why document order is append-only.
    ///
    /// A single line longer than the whole budget keeps its own TAIL, so the body is
    /// bounded and never empty. What a dropped line carried is not lost with it in a
    /// language document: every folded lesson also has a translation-memory entry, and
    /// a gold hit resolves the slot with no prompt at all (6.1). The cut is a real
    /// change of the body, so it bumps the version like any other — a slot stamped
    /// against the lines that were cut is exactly what "stale" means.
    func truncateToLimit() {
      guard isOverLimit else { return }
      var kept: [String] = []
      var used = 0
      for line in Self.lines(in: context).reversed() {
        let cost = line.count + (kept.isEmpty ? 0 : 1)
        if kept.isEmpty, cost > limit {
          kept.append(String(line.suffix(limit)))
          break
        }
        guard used + cost <= limit else { break }
        kept.append(line)
        used += cost
      }
      let body = kept.reversed().joined(separator: "\n")
      guard body != context else { return }
      context = body
      version += 1
      // A cut is a real change of the body, so it publishes like any other write.
      hasDocument = true
      // Same reason `append` cannot throw: this is the fallback path of a document the
      // model could not shorten, and a failed store write leaves the cut in memory.
      try? save()
    }
    /// One model call per over-budget document, run after every learn fold, so
    /// the STORED body fits what a prompt can send. ASYNC because it is a model
    /// call — the store read that follows it is not. Change-gated, for the same
    /// reason `append` is: a no-op rewrite must write nothing.
    ///
    /// One call, never one per line (3.6). Four ways out, and three of them keep the
    /// stored body as the model left it: a body the model says it cannot usefully
    /// shorten (`NO_CHANGE`), a rewrite that canonicalizes to the body already stored
    /// (the change gate), and a rewrite still over the cap. All three fall through to
    /// the tail-preserving cut, which is the documented fallback. Only an unusable
    /// reply is an error, and it is thrown rather than swallowed: the caller (a fold)
    /// reports it on the run, and the cut still keeps the stored body bounded.
    func compressIfNeeded() async throws {
      guard context.count > limit else { return }
      // Only a LANGUAGE document has a compression shape. A project or global document
      // is human prose, and `Prompt.compress` states the lesson-line format its answer
      // has to come back in (3.7: the two formats are not interchangeable) — asking a
      // model to keep prose rules in that shape would corrupt the rules, and cutting
      // them would destroy authored text that no memory entry backs. A prose document
      // therefore stays as it is, and the prompt builder clamps what it sends.
      guard let language = scope.languageCode else { return }
      let before = context
      let answer = try await compressed(language: language)
      if answer == Self.noChange {
        truncateToLimit()
        return
      }
      let canonical = Self.merging(
        existing: [], incoming: Self.lines(in: answer), scope: scope)
      guard !canonical.isEmpty else { throw CompressionError.unusableReply }
      let body = canonical.joined(separator: "\n")
      guard body != before else {
        truncateToLimit()
        return
      }
      context = body
      version += 1
      hasDocument = true
      // A published change: the version is what re-marks the column, so this write is
      // throwing rather than best-effort — the fold reports a failed one.
      try save()
      // The model was asked for at most `limit` characters; a body that is nonetheless
      // over it goes through the cut, so what is STORED always fits what can be sent.
      if isOverLimit { truncateToLimit() }
    }
    // MARK: - the document's own format

    /// The word a fold and a compression answer with when the document already covers
    /// everything they were handed.
    private static let noChange = "NO_CHANGE"
    /// The literal two-character escape a model sometimes writes instead of a real tab
    /// separator (it reads the instruction as "write \\t"). Tolerated on read and
    /// canonicalized to a real tab on write — the same tolerance the current
    /// implementation's `GlossaryFormat` has, restated here because the redesign calls
    /// nothing in that file.
    private static let literalSeparator = "\\t"
    /// A document body as its lines: one per line, trimmed, empties dropped. A stored
    /// body is canonical, so a "before" and an "after" compare line for line.
    ///
    /// What is trimmed is spaces and newlines and NEVER a tab: a tab is a lesson line's
    /// separator, and a retraction line's empty third field IS a trailing tab —
    /// `CharacterSet.whitespaces` would eat it and turn the retraction into a two-field
    /// line nothing can read (3.8).
    private static func lines(in text: String) -> [String] {
      text.split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: Self.edges) }
        .filter { !$0.isEmpty }
    }
    /// The characters a document line may lose without changing what it says.
    private static let edges = CharacterSet(charactersIn: " \r\n")
    /// A raw line as its canonical lesson line, or nil when it is not a lesson line at
    /// all. A language document holds `KEY<TAB>SOURCE<TAB>VALUE` and nothing else
    /// (3.7), so a line that does not split into exactly three fields is dropped
    /// instead of stored as prose — the fold already reports those to the run, which
    /// is where a malformed reply belongs.
    private static func lesson(_ line: String) -> String? {
      if line.split(separator: "\t", omittingEmptySubsequences: false).count == 3 {
        return line
      }
      guard !line.contains("\t"), line.contains(literalSeparator) else { return nil }
      let parts = line.components(separatedBy: literalSeparator)
      guard parts.count == 3 else { return nil }
      return parts.joined(separator: "\t")
    }
    /// The (key, source) pair a canonical lesson line is filed under. The escaped field
    /// text is compared as written: the pair is what makes a lesson unique, and an
    /// escape is part of the field's text, not part of the identity.
    private static func identity(of line: String) -> String? {
      let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
      guard fields.count == 3 else { return nil }
      return "\(fields[0])\t\(fields[1])"
    }
    /// The body an append produces, per scope (3.8).
    ///
    /// A LANGUAGE document is deduped to one line per (key, source) with the newest
    /// value winning IN PLACE — the line keeps its position, so document order stays
    /// append-order and the tail-preserving cut keeps meaning "the newest lessons
    /// survive". A cleared value retracts its line. A PROJECT document is prose: an
    /// exact-line membership test, appended in order (3.5). The global document is
    /// prose too — who may write it is decision 10.2's subject, not this function's.
    private static func merging(
      existing: [String], incoming: [String], scope: Scope
    ) -> [String] {
      var merged = existing
      switch scope {
      case .global, .project:
        for line in incoming where !merged.contains(line) {
          merged.append(line)
        }
      case .language:
        for raw in incoming {
          guard let line = lesson(raw), let pair = identity(of: line) else { continue }
          let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
          guard fields.count == 3 else { continue }
          if fields[2].isEmpty {
            merged.removeAll { identity(of: $0) == pair }
          } else if let position = merged.firstIndex(where: { identity(of: $0) == pair }) {
            merged[position] = line
          } else {
            merged.append(line)
          }
        }
      }
      return merged
    }
    /// One compression call, to Muse and nowhere else (3.6). The request is built by
    /// `Prompt.compress`, which restates the line format because the reply IS the
    /// document's new body, and the reply is read as TEXT: like the learn fold, this
    /// answers a document rather than a per-id map, so there is nothing to match and
    /// nothing to validate against ids — the chunks are simply collected.
    private func compressed(language: String) async throws -> String {
      let request = Prompt.compress(language: language, document: context, limit: limit)
      let candidate = try await candidate()
      try await router.admit(candidate)
      var text = ""
      for try await chunk in router.stream(request, using: candidate) { text += chunk }
      return Self.strippingFence(text)
    }
    /// Muse, or a wait. `next()` answers nil exactly while Muse is parked, and there is
    /// no second candidate to fall back to, so waiting the park out is the only thing
    /// that is not giving up (5.2). The runner has the same three lines for a batch.
    private func candidate() async throws -> Router.Candidate {
      while true {
        try Task.checkCancellation()
        if let candidate = router.next() { return candidate }
        let wait = router.cooldownUntil?.timeIntervalSinceNow ?? Router.cooldownWindow
        try await Task.sleep(nanoseconds: UInt64(max(wait, 1) * 1_000_000_000))
      }
    }
    /// A reply as its text. A fence pair a model insists on is stripped, because a
    /// document body must not start with one; everything else is kept exactly as it
    /// arrived.
    private static func strippingFence(_ raw: String) -> String {
      let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      guard text.hasPrefix("```") else { return text }
      return text.replacingOccurrences(of: "```json", with: "")
        .replacingOccurrences(of: "```", with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// A reply that is not a document at all: no lesson line, no `NO_CHANGE`. Reported
    /// rather than swallowed, because a document that is over its budget and could not
    /// be rewritten is worth knowing about.
    enum CompressionError: LocalizedError {
      case unusableReply
      var errorDescription: String? {
        switch self {
        case .unusableReply: "the compression reply holds no lesson line"
        }
      }
    }
  }

  // MARK: - global

  @Observable @MainActor class Global {
    /// The one store every object below borrows: in memory, main actor, sync.
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
    ///
    /// The registry IS the app's own `Project` rows, which the store persists as they are
    /// written, so there is nothing of the redesign's own left to write here.
    func save() throws {}
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
    /// One entry per CATALOG key, sorted by key. The catalog key — not the
    /// array position — is the identity every operation carries.
    ///
    /// SORTED BY KEY, and not in file order: the catalog is the row universe (4.8), and
    /// its own model holds `strings` as a `[String: Entry]` Dictionary, so the file's
    /// order is not available to anything downstream. An earlier doc promised "catalog
    /// order" and that claim is withdrawn rather than faked.
    var data: [LocalizationKey] = []
    /// key -> position in `data`, so a result can be applied by key and
    /// re-checked against the scan's snapshot.
    var rowIndex: [String: Int] = [:]
    /// When the snapshot in `data` was taken. Nothing whose store record carries a NEWER
    /// stamp is this session's to overwrite: it belongs to whoever wrote it
    /// (`adoptForeignWrites`). A project whose `loadData` never ran keeps the distant past,
    /// which adopts nothing.
    private(set) var loadedAt: Date = .distantPast
    /// The parsed catalog the rows are projected from (4.8). A row IS a catalog key, so
    /// the artifact is what makes the row universe — and keeping it is what lets the
    /// no-argument `loadData()` re-project the same file state (a discard, a stage
    /// factory, the run's own prepare). Nil until a catalog is handed to
    /// `loadData(catalog:)`; a project with no artifact has no rows at all.
    private var catalog: StringCatalog?
    /// The machine-write journal the row pass's page reads (`HorizontalTranslate.Journal`).
    ///
    /// Read from the store ONCE (`loadJournal`, off the main actor, when the workspace opens)
    /// and kept current from then on by the runner's write-back (`recordJournal`), which is the
    /// only writer of machine edits — the writes that land before the read are in what it
    /// reads. Not observed: the page takes a copy with the rest of its page models, so a write
    /// does not repaint it on its own (see `Run.frame`).
    @ObservationIgnored private var journalCache: HorizontalTranslate.Journal?
    @ObservationIgnored private var pendingJournal: [HorizontalTranslate.Write] = []
    var journal: HorizontalTranslate.Journal {
      journalCache ?? HorizontalTranslate.Journal(pendingJournal)
    }
    /// Reads the journal from the store, once.
    func loadJournal() async {
      guard journalCache == nil else { return }
      let loaded = await HorizontalTranslate.journal(of: self)
      guard journalCache == nil else { return }
      // Writes recorded while the read ran are in the store already, so the read has them.
      pendingJournal = []
      journalCache = HorizontalTranslate.Journal(loaded)
    }
    /// Machine writes that just landed, in order.
    func recordJournal(_ writes: [HorizontalTranslate.Write]) {
      guard !writes.isEmpty else { return }
      if journalCache != nil {
        journalCache?.append(contentsOf: writes)
      } else {
        pendingJournal += writes
      }
    }
    init(id: String, global: Global) throws {
      self.id = id
      self.global = global
      context = try Context(scope: .project(id), store: global.store)
      try loadLanguages()
    }
    /// The languages in play: what the store remembers for this project,
    /// intersected with what the user asked for (the Add Language overlay). A fetch,
    /// not a file read.
    ///
    /// The store is the only source of that set reachable from a synchronous call: the
    /// artifact's own language list belongs to the catalog layer (it opens and parses
    /// the `.xcstrings` when a project opens — 7.1), and language documents are
    /// addressed one scope at a time by their full id, so there is nothing to
    /// enumerate. A SLOT RECORD is what "in play" means on this side: the reconcile
    /// that seeds a project creates one per (key, language, category) — the empty ones
    /// included — so a column exists exactly when the store has rows for it. The rows
    /// themselves come from the catalog now (4.8), so a column reaches keys the store
    /// holds no record for; what it cannot do is appear for a language nothing in the
    /// store knows.
    private func loadLanguages() throws {
      // The COLUMN SET, not the rows: this runs on every open, and asking for the records to
      // then throw all but one column away was the launch hang the reader's profiler caught
      // (`loadProject` -> `loadLanguages` -> `Store.records` -> `sorted(by:)`: 2.0 s for one
      // project, 10.5 s for the largest, against 0.02 s for this — measured on the reader's own
      // store, 2026-09-15).
      for code in try global.store.languages(project: id) where languages[code] == nil {
        languages[code] = try Language(id: code, project: self)
      }
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
    /// Builds the rows from an OPEN CATALOG — the artifact is the row universe (4.8), so
    /// this is the entry point an open goes through: the pane hands over the catalog it is
    /// showing (its parsed `StringCatalog`), and the store supplies the STATE of the keys
    /// that catalog holds.
    ///
    /// One row per CATALOG key, sorted by key (see `data`). A record whose key the catalog
    /// does not hold produces NO row — its state stays in the store, waiting for the key to
    /// come back — and a catalog key the store holds no record for IS a row, whose slots
    /// start from the artifact. Where BOTH hold the key the STORE wins for the value: a run
    /// writes app-side and the file only catches up on Save (5.8), so the artifact's value
    /// is the base state and never the latest one.
    ///
    /// The catalog is KEPT (`self.catalog`), which is what makes the no-argument
    /// `loadData()` a re-projection of the same artifact rather than a second source of
    /// truth.
    ///
    /// Every row this projects is a row of the open catalog BY CONSTRUCTION — its key came
    /// out of `catalog.strings` — and saying so is the builder's job: the rows carry
    /// `isCatalogRow`, and `row(key:records:catalog:)` below is that flag's one
    /// definition (4.8).
    func loadData(catalog: StringCatalog) throws {
      self.catalog = catalog
      try loadData()
    }
    /// Re-projects the rows from the artifact this project last loaded.
    ///
    /// SYNCHRONOUS, and deliberately (7.1): the `.xcstrings` was opened and PARSED by the
    /// catalog layer (`StringCatalog.loadOffMainActor` is its async half) and handed in as a
    /// value, so what is left here is a walk over the catalog's own Dictionary plus ONE fetch
    /// (`Store.records`) for the whole project. A project no catalog was handed to has no
    /// rows at all: there is no key set to build them from, and the store is not one.
    func loadData() throws {
      guard let catalog else { return }
      guard data.isEmpty else { return }
      let built = Self.rows(
        catalog: catalog, records: try global.store.records(project: id),
        languages: languages.keys.sorted())
      adopt(built)
    }

    /// The same, built OFF the main actor — the open path: every catalog key × every language
    /// in play is real work on a big catalog.
    func loadData(catalog: StringCatalog) async throws {
      self.catalog = catalog
      loads += 1
      let load = loads
      guard data.isEmpty else { return }
      let records = try global.store.records(project: id)
      let languages = languages.keys.sorted()
      let built = await Task.detached(priority: .userInitiated) {
        Self.rows(catalog: catalog, records: records, languages: languages)
      }.value
      // A newer catalog handed over meanwhile builds its own rows.
      guard data.isEmpty, load == loads else { return }
      adopt(built)
    }
    /// Bumped by every `loadData(catalog:)`, so only the latest one's rows are adopted.
    @ObservationIgnored private var loads = 0

    /// Takes a built row set, and starts listening for what moves under it.
    private func adopt(_ built: (rows: [LocalizationKey], positions: [String: Int])) {
      data = built.rows
      rowIndex = built.positions
      // The stamp a foreign write is read against (`adoptForeignWrites`): from here on, every
      // key the store writes is noted.
      loadedAt = .now
      movedKeys = []
      if recordObservation == nil, let owner = try? global.store.projectRow(id: id)?.id {
        recordObservation = global.store.data.observeRecords { [weak self] project, slots in
          guard let self, project == owner else { return }
          if slots.isEmpty { self.movedKeys = nil } else { self.movedKeys?.formUnion(slots.map(\.key)) }
        }
      }
    }

    /// The keys the store wrote since the rows were built (nil: the whole project moved), for
    /// `adoptForeignWrites`.
    @ObservationIgnored private var movedKeys: Set<String>? = []
    @ObservationIgnored private var recordObservation: ObservationToken?

    /// One row per CATALOG key, sorted by key — PURE, so the open path builds them off the
    /// main actor.
    nonisolated private static func rows(
      catalog: StringCatalog, records: ProjectRecords, languages: [String]
    ) -> (rows: [LocalizationKey], positions: [String: Int]) {
      var rows: [LocalizationKey] = []
      var positions: [String: Int] = [:]
      rows.reserveCapacity(catalog.strings.count)
      for key in catalog.strings.keys.sorted() {
        positions[key] = rows.count
        rows.append(row(key: key, records: records.records(key: key), catalog: catalog, languages: languages))
      }
      return (rows, positions)
    }

    /// Adopts the store's own version of every slot whose RECORDS moved after this session
    /// loaded — the universe rule (4.8) read from the other side.
    ///
    /// The rows are a SNAPSHOT: `loadData()` builds them once and deliberately refuses to
    /// build them again, and everything this side writes comes out of them — the catalog the
    /// publish step hands the app, and the records `saveData` stamps. The store, meanwhile,
    /// has other writers: the browser's cell edit writes a record straight (it never goes
    /// through this session), a second window saves, an old-pipeline run fills slots. A
    /// snapshot that old is a REVERSION MACHINE, and it was one in the field: a human edited
    /// an imported value in the browser, pressed Save on this side, and the session wrote its
    /// snapshot over the edit BOTH ways — the record came back auto-reviewed with the shipped
    /// text, and the published catalog put that same text back into the `.xcstrings`.
    ///
    /// So the RECORD wins wherever one moved under the session: a slot with a record stamped
    /// newer than `loadedAt` is re-projected from its records, exactly as the row builder
    /// would have projected it had they read that way at the load. What the session owns by
    /// itself is untouched — a slot the human edited HERE has no record behind its edit yet
    /// (the store hears about it in `saveData`), so its stamp has not moved and nothing is
    /// adopted. The two statuses the store cannot express (`.ignore` for a row taken out of
    /// scope, `.stale` from the file) are the session's own reading, so a slot carrying one
    /// keeps it over the store's.
    ///
    /// Returns how many slots were adopted: 0 for a session whose world did not move, which
    /// is the ordinary case (the caller's own run writes are the session's too).
    @discardableResult
    func adoptForeignWrites() throws -> Int {
      let records = try global.store.records(project: id)
      // Only the keys the store wrote since the rows were built can differ from them.
      let moved = movedKeys ?? Set(records.keys)
      movedKeys = []
      var adopted = 0
      for key in moved {
        let ofKey = records.records(key: key)
        guard let row = rowIndex[key], data.indices.contains(row) else { continue }
        for (language, ofLanguage) in Dictionary(grouping: ofKey, by: \.language) {
          let ofLanguage = Self.records(ofLanguage, shapedBy: catalog, key: key, language: language)
          guard ofLanguage.contains(where: { $0.updatedAt > loadedAt }),
            let at = data[row].index(of: language)
          else { continue }
          let current = data[row].targets[at]
          var stored = Self.slot(language: language, records: ofLanguage)
          guard stored.target != current.target || stored.status != current.status else {
            continue  // the session already says what the store says
          }
          if current.status == .ignore || current.status == .stale { stored.status = current.status }
          data[row].targets[at] = stored
          adopted += 1
        }
      }
      return adopted
    }
    /// One row of the table: a CATALOG key, with what the store knows about it.
    ///
    /// It is also the ONE place a row is told it belongs to the open catalog
    /// (`isCatalogRow`), and the only builder there is: `loadData` calls it once per
    /// catalog key and nothing else calls it at all (4.8).
    ///
    /// The source is the ARTIFACT's (the file is where source text is authored, and the
    /// store's `sourceText` is a copy the reconcile took from that same file), the comment
    /// likewise — it is the one row field with no home on this side, because the format
    /// carries it and the store has no column for it — and the width guideline is the
    /// STORE's (the `.xcstrings` format has no width field). The ignore flag is the
    /// artifact's too: 2.1's first row is `shouldTranslate == false -> ignore`, so a key the
    /// FILE takes out of scope reads as out of scope whatever the store says about it.
    ///
    /// The slots are one per language IN PLAY (`languages`, which the store supplies). Where
    /// the store holds records for the pair they ARE the slot; where it holds none the slot
    /// is the artifact's own. `maxWidth` is key-scoped in the store — every record of the key
    /// carries the same guideline — so taking the first non-nil one is exact, not a guess.
    nonisolated private static func row(
      key: String, records: [TranslationRecord], catalog: StringCatalog, languages: [String]
    ) -> LocalizationKey {
      let translatable = catalog.entry(for: key)?.shouldTranslate != false
      let byLanguage = Dictionary(grouping: records, by: \.language)
      var targets: [LocalizationString] = []
      for language in languages {
        var slot: LocalizationString
        if let ofLanguage = byLanguage[language].map({
          Self.records($0, shapedBy: catalog, key: key, language: language)
        }), !ofLanguage.isEmpty {
          slot = Self.slot(language: language, records: ofLanguage)
        } else {
          slot = Self.slot(language: language, key: key, catalog: catalog)
        }
        // An ignored key is out of scope for every stage and keeps its value (2.1): the
        // status is what a scan and `Run.writable` read, so a record written before the flag
        // was set cannot be translated over.
        if !translatable { slot.status = .ignore }
        targets.append(slot)
      }
      return LocalizationKey(
        key: key,
        source: Self.source(of: key, in: catalog),
        comment: catalog.entry(for: key)?.comment ?? "",
        maxWidth: records.compactMap(\.maxWidth).first ?? 0,
        translatable: translatable,
        // THE definition of the row's own answer to the universe question (4.8): this
        // builder only ever runs for a CATALOG key, so a row it builds IS a row of the
        // open catalog, and nothing else in the app sets the flag. A hand-built data
        // set, a preview and any future caller inherit the default — false — and their
        // rows are therefore never work for any stage.
        isCatalogRow: true,
        targets: targets)
    }
    /// The row's source body, read from the ARTIFACT.
    ///
    /// The `.xcstrings` is where source text is AUTHORED: the store's `sourceText` is a copy
    /// the reconcile took from that same file, so the file wins wherever the two can
    /// disagree (a source edited in Xcode, a project the app's own open has not reconciled
    /// yet). A source the file varies by plural carries its FORMS — a plural body rather
    /// than one form's text, because the prompt and the write-back both read the whole set —
    /// and a source the file has no unit for reads as the key, which is what the artifact
    /// itself shows (4.3).
    nonisolated private static func source(of key: String, in catalog: StringCatalog) -> StringBody {
      guard catalog.hasPlurals(for: key, language: catalog.sourceLanguage) else {
        return .value(catalog.sourceDisplay(for: key))
      }
      var forms = Plurals(language: catalog.sourceLanguage)
      for (category, value) in catalog.sourcePluralForms(for: key) {
        guard let rule = Plural.Rule(rawValue: category) else { continue }
        forms.set(value, for: rule)
      }
      // A varied key whose source forms the file fills with nothing is an EMPTY body, so the
      // row still falls back to its key (`content`).
      return forms.isEmpty ? .value(catalog.sourceDisplay(for: key)) : .plural(forms)
    }
    /// One (key, language) slot the STORE holds no record for: the artifact's own state.
    ///
    /// This is the row the universe rule CREATES (4.8) — a key the file holds and the store
    /// has never seen — so everything here comes from the file: the value (`rawValue`, or the
    /// plural forms the node carries for this language, rebuilt over the TARGET language's
    /// own rule set as 1.4 requires) and the status (2.1's file mapping). `machine` and
    /// `reviewed` stay empty by construction — nobody has produced a machine value for this
    /// slot and nobody has confirmed one — which is exactly what makes it WORK like any other
    /// row. The stamp is `.none`: no document was in play when the file was written, so a
    /// document that exists marks the slot stale (3.4).
    nonisolated private static func slot(
      language: String, key: String, catalog: StringCatalog
    ) -> LocalizationString {
      var slot = LocalizationString(language: language)
      let state: String?
      if let units = catalog.pluralUnits(for: key, language: language) {
        var target = Plurals(language: language)
        for (category, unit) in units {
          guard let rule = Plural.Rule(rawValue: category) else { continue }
          target.set(unit.value ?? "", for: rule)
        }
        state = Self.state(of: units)
        slot.target = .plural(target)
      } else {
        state = catalog.state(for: key, language: language)
        slot.target = .value(catalog.rawValue(for: key, language: language) ?? "")
      }
      slot.status = Self.status(state: state, value: slot.target)
      return slot
    }
    /// The file's own state for a plural node.
    ///
    /// A varied node carries its state INSIDE each form — there is no flat unit to read — and
    /// Xcode gives a plural ONE state per language rather than one per form (1.4), so the
    /// forms are read as one: the `other` form's state when the file states one, else the
    /// first state any form carries, in category order so the answer never depends on a
    /// Dictionary's iteration order. A node that states none leaves the status to the value.
    nonisolated private static func state(of units: [String: StringCatalog.StringUnit]) -> String? {
      if let other = units["other"]?.state { return other }
      return units.keys.sorted().compactMap { units[$0]?.state }.first
    }
    /// The status an ARTIFACT slot reads as — 2.1's FILE mapping, deliberately not the store
    /// mapping beside it (the two disagree about who wrote the value and whether anyone
    /// vouched for it):
    ///
    ///     absent unit / empty value -> needsTranslate
    ///     "new"                     -> needsTranslate
    ///     "needs_review"            -> translated
    ///     "translated"              -> verified
    ///     "stale"                   -> stale
    ///
    /// An empty value outranks the state, exactly as it does on the store side: a unit with
    /// nothing in it is work whatever it claims. A state the format does not name — an absent
    /// one included — reads as UNREVIEWED output rather than as a confirmation, because
    /// nothing but a human produces `.verified` (2.2). `.imported` is never produced here: it
    /// is app-side knowledge the file cannot carry, and the imported-database resolve is what
    /// writes it (`Workspace.applyImported`, 6.3).
    nonisolated private static func status(state: String?, value: StringBody) -> LocalizationString.Status {
      guard !value.isEmpty else { return .needsTranslate }
      switch state {
      case "new": return .needsTranslate
      case "needs_review": return .translated
      case "translated": return .verified
      case "stale": return .stale
      default: return .translated
      }
    }
    /// The records a (key, language) slot is projected from, in the shape the FILE gives it.
    ///
    /// A flat value a person confirmed in the file is a shape a person chose
    /// (`holdsReviewedFlat`), so the store's form records for the pair are a shape the load
    /// left behind, and the slot reads flat: projected as plural, the write-back (`apply`)
    /// would clear the flat unit and put the forms back into the file. Empty when the store
    /// holds no flat record for the pair, so the slot is the artifact's own.
    nonisolated private static func records(
      _ records: [TranslationRecord], shapedBy catalog: StringCatalog?, key: String,
      language: String
    ) -> [TranslationRecord] {
      guard let catalog, catalog.holdsReviewedFlat(key: key, language: language) else {
        return records
      }
      return records.filter { $0.category == nil }
    }
    /// One (key, language) slot, projected from the records of that pair.
    ///
    /// The pair HAS records by construction: a (key, language) the store holds nothing for is
    /// the artifact's own slot (`slot(language:key:catalog:)`).
    ///
    /// The records are per language and, for a varied key, per category. A plural slot
    /// is rebuilt over the TARGET LANGUAGE'S OWN rules (1.4), which is what keeps its
    /// three bodies parallel: a rule the store has no record for reads empty, and an
    /// empty form is exactly the skeleton a prompt asks to be filled (4.3). `machine`
    /// and `reviewed` are parallel plural bodies too, because the store keeps one row
    /// per form for all three of them.
    nonisolated private static func slot(
      language: String, records: [TranslationRecord]
    ) -> LocalizationString {
      let forms = records.filter { $0.category != nil }
      // The record that speaks for the slot — its status and its stamp. Chosen by RULE, never
      // by the order the records came in: the flat record; for a plural slot the `other` form
      // (the one every language has, and the one the file's own state is read from), else the
      // first form in the language's rule order.
      let owner = forms.isEmpty
        ? (records.first { $0.category == nil } ?? records[0])
        : Self.speaking(for: forms, language: language)
      var slot = LocalizationString(language: language)
      if forms.isEmpty {
        slot.target = .value(owner.value ?? "")
        slot.machine = .value(owner.machine ?? "")
        slot.reviewed = owner.reviewed.map { .value($0) }
      } else {
        var target = Plurals(language: language)
        var machine = Plurals(language: language)
        var reviewed = Plurals(language: language)
        for record in forms {
          guard let category = record.category, let rule = Plural.Rule(rawValue: category)
          else { continue }
          target.set(record.value ?? "", for: rule)
          machine.set(record.machine ?? "", for: rule)
          reviewed.set(record.reviewed ?? "", for: rule)
        }
        slot.target = .plural(target)
        slot.machine = .plural(machine)
        // A snapshot exists only where a human confirmed one: a set of empty forms is
        // not a snapshot, and `toLearn` reads nil as "nothing confirmed since".
        slot.reviewed = reviewed.isEmpty ? nil : .plural(reviewed)
      }
      slot.status = Self.status(of: owner, value: slot.target)
      slot.versions = Store.version(owner.contextVersions)
      return slot
    }
    /// The form record a plural slot's status and stamp are read from: `other` when it holds a
    /// value, else the first form with a value in the language's rule order, else `other`, else
    /// the first form in that order.
    nonisolated private static func speaking(
      for forms: [TranslationRecord], language: String
    ) -> TranslationRecord {
      let order = Plural.rules(language: language).map(\.rawValue)
      let sorted = forms.sorted {
        (order.firstIndex(of: $0.category ?? "") ?? order.count)
          < (order.firstIndex(of: $1.category ?? "") ?? order.count)
      }
      let other = sorted.first { $0.category == "other" }
      if let other, other.value?.isEmpty == false { return other }
      return sorted.first { $0.value?.isEmpty == false } ?? other ?? sorted[0]
    }
    /// The status a stored record reads as.
    ///
    /// This is the STORE mapping, and it is not the file mapping (2.1): `state` says who
    /// wrote the value, `autoReviewed` says nobody vouched for it, and an empty value
    /// outranks both — a slot with nothing in it is work whatever its row claims. A slot the
    /// store holds no record for reads through the FILE mapping instead
    /// (`status(state:value:)`), because there is no record to read.
    ///
    /// `.stale` is deliberately NOT produced here. A store record cannot express it
    /// (app-side staleness is never written back), so it is the staleness predicate's
    /// output rather than this projection's: a slot is stale when a scope that owns it
    /// moved past the slot's stamp (3.4), and which scopes that predicate consults is
    /// decision 10.11 — a project-document bump deliberately enqueues nothing (2.3).
    /// What this projection does carry is the INPUT to that comparison: every slot keeps
    /// the stamp it was produced against.
    nonisolated private static func status(
      of record: TranslationRecord, value: StringBody
    ) -> LocalizationString.Status {
      guard !value.isEmpty else { return .needsTranslate }
      switch record.state {
      case .empty: return .needsTranslate
      case .needs_review: return .translated
      case .reviewed: return record.autoReviewed ? .imported : .verified
      }
    }
    /// Writes the app-side session for this project to the store. Note what this
    /// does NOT do: it never writes the artifact — `Save` on the open catalog is the
    /// only writer of the `.xcstrings`.
    ///
    /// It writes the SESSION: every slot's value, its status as the record's own state,
    /// the stamp, and the two bodies the model and the human own (`machine`, `reviewed`).
    /// A plural slot writes one record per form, which is how the store keeps forms and
    /// how the artifact shows them. Provenance is mostly the WRITER's business — a run's
    /// write-back sets the producing model, a human action sets `.manual` and the
    /// confirmation moment (`Reconcile` is the precedent, read and not called) — and this
    /// method lifts only what it can tell for itself: a value that arrived from a human,
    /// and the confirmation a `.verified` slot is.
    func saveData() async throws {
      guard !data.isEmpty, let owner = try global.store.projectRow(id: id)?.id else { return }
      let rows = data
      let records = try global.store.records(project: id)
      let userName = Self.userName
      // The walk is the whole session — every row × slot × form — so it runs off the main
      // actor over a snapshot and comes back as the writes to make.
      let writes = await Task.detached(priority: .userInitiated) {
        Self.sessionWrites(rows: rows, records: records, projectID: owner, userName: userName)
      }.value
      // ONE landing for the whole session, and only over records nobody wrote meanwhile: a
      // slot the store moved since the snapshot (a run's write-back) keeps the newer writer.
      let store = global.store
      let current = try store.records(project: id)
      var landed: Set<SlotKey> = []
      for (record, before) in writes.records where current[record.slotKey] == before {
        try store.upsert(record, saving: false)
        landed.insert(record.slotKey)
      }
      for edit in writes.edits where landed.contains(edit.slotKey) {
        try store.append(edit, saving: false)
      }
      try store.save()
    }

    /// What saving the session writes — PURE: every slot whose record does not already say
    /// what the session says, with the record as it was (nil: none yet), plus the journal
    /// rows for the values a human settled that MOVED.
    ///
    /// The change gate is the same as a document's: a save is a walk of the whole project,
    /// so a slot that already says exactly what the session says is skipped — and
    /// `updatedAt` keeps meaning when the slot last MOVED.
    nonisolated private static func sessionWrites(
      rows: [LocalizationKey], records: ProjectRecords, projectID: Int64, userName: String
    ) -> (records: [(TranslationRecord, TranslationRecord?)], edits: [TranslationEdit]) {
      var writes: [(TranslationRecord, TranslationRecord?)] = []
      var edits: [TranslationEdit] = []
      for row in rows {
        for slot in row.targets {
          for form in forms(of: slot) {
            let existing = records[SlotKey(key: row.key, language: slot.language, category: form.category)]
            var record = existing ?? newRecord(for: row, slot: slot, form: form, projectID: projectID)
            guard !unchanged(form, of: slot, record) else { continue }
            let before = record.value
            write(form, of: slot, to: &record, userName: userName)
            writes.append((record, existing))
            // The journal, which is the learning corpus (7.2, 2.5). The ONE edit
            // recorded here is a value a human settled that MOVED: a machine write-back
            // journals itself at the run's write-back, a pure confirmation records
            // nothing (the model agreeing with the human is not a lesson), and the
            // imported resolve is not a lesson about our model at all (6.3).
            if slot.status == .verified, before != record.value {
              edits.append(TranslationEdit(
                record: record,
                fromValue: before,
                toValue: record.value ?? "",
                editor: .human,
                reason: "Confirmed in review: the human's value replaced the stored one",
                contextVersions: Store.persistable(slot.versions),
                isUserConfirmed: true))
            }
          }
        }
      }
      return (writes, edits)
    }
    /// True when the record already carries exactly what the session says, so writing it
    /// again would be a no-op with a side effect. The mirror of `write(_:of:to:)`: every
    /// field that write sets is compared here, and the two have to agree.
    nonisolated private static func unchanged(
      _ form: Form, of slot: LocalizationString, _ record: TranslationRecord
    ) -> Bool {
      let value = form.value.isEmpty ? nil : form.value
      let machine = form.machine.isEmpty ? nil : form.machine
      guard record.value == value, record.machine == machine else { return false }
      if let reviewed = form.reviewed, record.reviewed != reviewed { return false }
      guard Store.version(record.contextVersions) == slot.versions else { return false }
      switch slot.status {
      case .needsTranslate: return record.state == .empty
      case .translated: return record.state == .needs_review
      case .verified: return record.state == .reviewed && !record.autoReviewed
      case .imported: return record.state == .reviewed && record.autoReviewed
      // App-side knowledge the record does not express: the value above is the whole
      // question, and the state stays whatever it was.
      case .stale, .ignore: return true
      }
    }
    /// One form of a slot, as the store keeps it.
    nonisolated private struct Form: Sendable {
      let category: String?
      let value: String
      let machine: String
      let reviewed: String?
    }
    /// The forms one slot writes: one record with no category for a flat value, one per
    /// category for a plural one. The bodies are read per form, so a slot's three bodies
    /// stay parallel exactly as they were projected.
    nonisolated private static func forms(of slot: LocalizationString) -> [Form] {
      switch slot.target {
      case .value(let text):
        return [
          Form(
            category: nil, value: text, machine: slot.machine.catalogValue,
            reviewed: slot.reviewed?.catalogValue)
        ]
      case .plural(let plural):
        return plural.values.map { form in
          Form(
            category: form.rule.rawValue,
            value: form.value,
            machine: Self.form(slot.machine, form.rule),
            reviewed: slot.reviewed.map { Self.form($0, form.rule) })
        }
      }
    }
    /// One form of a body as text: a flat body is its whole text, a plural body answers
    /// with the form the rule names (empty when it does not carry it).
    nonisolated private static func form(_ body: StringBody, _ rule: Plural.Rule) -> String {
      guard case .plural(let plural) = body else { return body.catalogValue }
      return plural.value(for: rule)
    }
    /// The row the store does not hold yet for one form — a language added in this session
    /// has no records until its first save. The new record carries `.empty` and no value:
    /// what the session says is written onto it by `write(_:of:to:)`, so nothing here is a
    /// second guess at the row's state. Its stamp starts as the SENTINEL (all-zero), never
    /// three nils (7.3).
    nonisolated private static func newRecord(
      for row: LocalizationKey, slot: LocalizationString, form: Form, projectID: Int64
    ) -> TranslationRecord {
      TranslationRecord(
        key: row.key,
        sourceText: row.source.catalogValue,
        language: slot.language,
        value: nil,
        state: .empty,
        contextVersions: Store.persistable(.none),
        projectID: projectID,
        category: form.category,
        maxWidth: row.maxWidth > 0 ? row.maxWidth : nil)
    }
    /// One form written onto its record.
    ///
    /// The status decides the state (2.1 is the FILE mapping; this is the store's), and
    /// two statuses write no state at all: `.stale` and `.ignore` are app-side knowledge
    /// a record cannot express, so the record keeps what it had. `.imported` is the
    /// auto-reviewed shape the imported resolve writes — reviewed, with nobody having
    /// vouched for it. A `.verified` slot is a human's: the confirmation moment is
    /// recorded once, and a value that differs from the stored one makes the human the
    /// writer, so no model's confidence stays attached to it.
    nonisolated private static func write(
      _ form: Form, of slot: LocalizationString, to record: inout TranslationRecord, userName: String
    ) {
      let value = form.value.isEmpty ? nil : form.value
      let authored = record.value != value
      let confirmed = record.state == .reviewed && !record.autoReviewed
      record.value = value
      record.machine = form.machine.isEmpty ? nil : form.machine
      // The confirmation snapshot is written when the slot carries one and never
      // cleared here: it is the value a human confirmed, and history is not rewritten.
      if let reviewed = form.reviewed { record.reviewed = reviewed }
      switch slot.status {
      case .needsTranslate:
        record.state = .empty
      case .translated:
        record.state = .needs_review
      case .verified:
        record.state = .reviewed
        record.autoReviewed = false
        if authored || !confirmed {
          record.reviewedAt = .now
          record.lastEditor = userName
        }
        if authored {
          record.provider = .manual
          record.confidence = nil
          record.hasEdits = true
        }
      case .imported:
        record.state = .reviewed
        record.autoReviewed = true
        record.reviewedAt = nil
        if authored { record.provider = .importedDB }
      case .ignore, .stale:
        // App-side knowledge with no column in the store: the value is kept, and so is
        // whatever state the record already carried.
        break
      }
      record.contextVersions = Store.persistable(slot.versions)
      record.updatedAt = .now
    }
    /// Who a human write is attributed to, the way the current implementation words it.
    private static var userName: String {
      let name = ProcessInfo.processInfo.fullUserName
      return name.isEmpty ? "Manual" : name
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
  nonisolated struct LocalizationKey: Hashable, Identifiable, Sendable {
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
    /// True when this row is a row of the OPEN CATALOG (4.8) — the universe rule
    /// stated on the ROW, so every scan can ask it without reaching into the store
    /// or the file for the answer.
    ///
    /// ONE definition, and it is the builder's: `loadData` is the only builder, and
    /// the rows it builds ARE catalog keys, so `row(key:records:catalog:)` sets this
    /// true and nothing else does. The default is therefore FALSE, not true: a
    /// `LocalizationKey` that came into being any other way — a hand-built data set,
    /// a preview, a caller the redesign has not met yet — is not a row of the
    /// catalog, so every scan skips it exactly like an ignored key: no model call,
    /// no batch, nothing to write, and its slots keep whatever they carry.
    ///
    /// It is deliberately NOT derived per stage and not derived from the store: a
    /// record of a key the open file does not hold is STATE without a row, and what
    /// makes a row is the catalog key it was built from, which only `loadData` knows.
    var isCatalogRow: Bool = false
    /// Eligibility (4.7): a string whose CONTENT holds no English character is
    /// never translated.
    ///
    /// The test is on the content a request would send — `content`, so a row whose
    /// source unit is missing is tested on its KEY (4.3) — and never on a slot's
    /// status: the question is "is there anything here a translator could
    /// translate". A leaked format string (`%d - %d`), a bare number, a bullet, an
    /// em dash: there is no prose to translate, so a translate stage SKIPS the row
    /// rather than sending it. A row skipped this way keeps whatever it carries,
    /// exactly like an ignored key: no model call, no batch, nothing to write. The
    /// row pass skips it too (4.6): it is not a row whose columns need adapting.
    ///
    /// English means a LATIN LETTER — A–Z / a–z — in the content that is PROSE, so
    /// `"Hello %@"` is eligible and `"OK"` is, while `"%d - %d"` and `"->"` are
    /// not. Digits, punctuation, whitespace, symbols and emoji count as ZERO, and so
    /// do CJK and Cyrillic: a Cyrillic value is skipped unless it also holds a Latin
    /// letter.
    ///
    /// A FORMAT SPECIFIER is not prose, and that is the case this rule exists for:
    /// `"%d - %d"` holds two `d`s and would otherwise read as English, so the
    /// content is read with its specifiers stepped over — `%@`, `%d`, `%1$@`, `%lld`
    /// count as zero, exactly like the punctuation around them. `"%@"` alone is
    /// therefore skipped and `"%@ items"` is not. (`StringBody.placeholders` is the
    /// validation side of the same notion and is still a stub; if the two scanners
    /// ever disagree, one of them has to win — 9.1.)
    ///
    /// ONE place on purpose: both translate scans ask THIS row-level predicate
    /// (`VerticalTranslate.scan`, `HorizontalTranslate.scan`), so the column pass
    /// and the row pass inherit one rule instead of each carrying a copy of it.
    ///
    /// The REPLY side is deliberately NOT here: refusing a model answer that holds
    /// no letter while its source does is a validation matter (5.3), not
    /// eligibility.
    var hasEnglishCharacters: Bool {
      switch content {
      case .value(let text): Self.holdsLatinLetter(text)
      case .plural(let plural): plural.values.contains { Self.holdsLatinLetter($0.value) }
      }
    }
    /// A Latin letter (A–Z / a–z) outside every format specifier — the 4.7 boundary.
    ///
    /// Read as UNICODE SCALARS, not as characters: a precomposed `"Á"` is not in A–Z,
    /// while an `"A"` followed by a combining accent still holds the `A` it is built
    /// from. Read with specifiers stepped over, so `"%d - %d"` finds none while
    /// `"Hello %@"` finds `H`.
    private static func holdsLatinLetter(_ text: String) -> Bool {
      let scalars = text.unicodeScalars
      var index = scalars.startIndex
      while index < scalars.endIndex {
        let scalar = scalars[index]
        if scalar == "%", let after = endOfSpecifier(after: index, in: scalars) {
          index = after
          continue
        }
        if (scalar.value >= 65 && scalar.value <= 90) || (scalar.value >= 97 && scalar.value <= 122) {
          return true
        }
        index = scalars.index(after: index)
      }
      return false
    }
    /// The scalar just past the format specifier a `%` starts, or nil when that `%`
    /// starts none — a lone `%` is punctuation and stays in the text.
    ///
    /// The shape is the catalog's own: flags (`- + # 0 '`), an optional positional
    /// index (`1$`), width and precision (`5`, `*`, `.2`), an optional length
    /// modifier (`hh`, `ll`, `l`, `q`, `z`, `j`, `t`, `L`, `w`) and the conversion
    /// character (`d i o u x X e E f F g G a A c C s S p n @`, or a literal `%%`).
    private static func endOfSpecifier(
      after percent: String.UnicodeScalarView.Index, in text: String.UnicodeScalarView
    ) -> String.UnicodeScalarView.Index? {
      var index = text.index(after: percent)
      while index < text.endIndex, "-+ #0'".unicodeScalars.contains(text[index]) {
        index = text.index(after: index)
      }
      while index < text.endIndex, isDigit(text[index]) || text[index] == "*" {
        index = text.index(after: index)
      }
      if index < text.endIndex, text[index] == "$" { index = text.index(after: index) }
      if index < text.endIndex, text[index] == "." {
        index = text.index(after: index)
        while index < text.endIndex, isDigit(text[index]) || text[index] == "*" {
          index = text.index(after: index)
        }
      }
      // The two-scalar modifiers first, or `ll` would match as `l` + a conversion
      // the letter after it does not start.
      for modifier in ["hh", "ll", "h", "l", "q", "z", "j", "t", "L", "w"]
      where text[index...].starts(with: modifier.unicodeScalars) {
        index = text.index(index, offsetBy: modifier.count)
        break
      }
      guard index < text.endIndex,
            "diouxXeEfgGaAcCsSpn@%".unicodeScalars.contains(text[index])
      else { return nil }
      return text.index(after: index)
    }
    private static func isDigit(_ scalar: Unicode.Scalar) -> Bool {
      scalar.value >= 48 && scalar.value <= 57
    }
    var targets: [LocalizationString]
    var id: String { key }
    func target(_ language: String) -> LocalizationString? {
      targets.first { $0.language == language }
    }
    func index(of language: String) -> Int? {
      targets.firstIndex { $0.language == language }
    }
    mutating func setTarget(_ value: LocalizationString, for language: String) {
      guard let index = index(of: language) else { return }
      targets[index] = value
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
  nonisolated struct LocalizationString: Hashable, Identifiable, Sendable {
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
    enum Status: Sendable {
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
  nonisolated enum StringBody: Hashable, Sendable {
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
  /// vertical -> horizontal`, in that order: preparation settles the rows (scan,
  /// merge the catalog, load the session data, resolve the imported database — no
  /// model call), prelearn supplies the machine record a human-verified slot is
  /// missing, learn folds what the human changed into the project's language
  /// document, only then is the column translated, and the row pass closes the run so
  /// the corrections a verification session produced reach the other languages. They
  /// are ordered operations of ONE run, not passes the user triggers separately.
  ///
  /// `horizontal` is therefore not a run of its own by default, but it CAN be started
  /// alone (`Stage.horizontal`): a project-document bump deliberately enqueues nothing
  /// (2.3), so applying a changed rule to values written before it is a paid sweep the
  /// user asks for — and that is the only way it runs alone.
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
    /// Where the ROW this came from is in the run's life.
    ///
    /// It belongs to the operation rather than to its batch (8.1, "stage pages"): a page marks
    /// the row from its own state, and the list follows the last row the run has ANSWERED
    /// (reader, 2026-09-15) — both of which need the phase here rather than on the batch's flags.
    var phase: Run.Phase { get }
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
