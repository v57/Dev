//
//  Stages.swift
//  Dev
//
//  Created by Dmitry on 12.09.26.
//
//  Design only: signatures with placeholder bodies that compile and change no
//  behaviour. Semantics are in "Design notes.md" beside this file.
//

import SwiftData
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
    /// Where the body and the version are read and written. State is SwiftData, so
    /// the reads and writes below are synchronous — a fetch on the main actor, not
    /// a suspension point.
    let store: Store
    /// The client a compression call goes out through. A document does not own a run,
    /// so it takes the client it is handed and otherwise makes its own: a `Router` is
    /// a model id plus its pacing state, and `Router.send` is the redesign's only
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
    /// that carries the sentinel rule (see `Store`): SwiftData on this SDK crashes
    /// re-faulting an all-nil versions row, so a Version of all zeros is stored as
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
    /// nothing to validate against ids.
    private func compressed(language: String) async throws -> String {
      let request = Prompt.compress(language: language, document: context, limit: limit)
      let candidate = try await candidate()
      try await router.admit(candidate)
      _ = try await router.send(request, using: candidate)
      return Self.strippingFence(router.lastRawReply ?? "")
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
    ///
    /// The registry IS the app's own `Project` rows: name (the title), catalog URL and
    /// root URL are what the app already stores, and the redesign deliberately adds no
    /// table for them (7.2, 10.16). A project that is not open is not resident here, so
    /// there is nothing of the redesign's own to write — this is the container's flush,
    /// which is what makes a rename or a newly seen project durable before the next
    /// open reads it back.
    func save() throws {
      try store.context.save()
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
    ///
    /// The store is the only source of that set reachable from a synchronous call: the
    /// artifact's own language list belongs to the catalog layer (it opens and parses
    /// the `.xcstrings` when a project opens — 7.1), and language documents are
    /// addressed one scope at a time by their full id, so there is nothing to
    /// enumerate. A SLOT RECORD is what "in play" means on this side: the reconcile
    /// that seeds a project creates one per (key, language, category) — the empty ones
    /// included — so a column exists exactly when the store has rows for it, and the
    /// columns cannot disagree with the rows `loadData` projects from the same fetch.
    private func loadLanguages() throws {
      for code in Set(try global.store.records(project: id).map(\.language)).sorted()
      where languages[code] == nil {
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
    /// Builds the rows: the catalog's keys, projected onto what the store knows
    /// about them — the imported-database resolve (status `.imported`), the
    /// staleness stamps, the journal. The artifact's own values are the base state.
    ///
    /// SYNCHRONOUS, and deliberately: by the time this runs, Prepare has already
    /// opened and parsed the .xcstrings (that part is async and belongs to the
    /// catalog layer), so this is a fetch plus a projection.
    ///
    /// The projection is from the app's OWN records — `Store.records`, ONE fetch for
    /// the whole project — which is what the redesign shares with the browser the old
    /// pipeline feeds (10.16): a key the store holds no record for is not a row, and
    /// the reconcile creates a record only for a TRANSLATABLE key (it skips
    /// `shouldTranslate == false`), so `translatable` reads true for every row this
    /// builds and an ignored key simply has no row. Two things the store does not
    /// carry are therefore absent by construction rather than by accident: the
    /// developer COMMENT (it lives in the artifact, and reaches a prompt through the
    /// catalog layer) and the artifact's own key order (the order here is the fetch's,
    /// which is by key). Neither changes the shape of a row: a row with no comment
    /// sends none (4.3), and the key is what every operation carries (1.2).
    func loadData() throws {
      guard data.isEmpty else { return }
      let records = try global.store.records(project: id)
      guard !records.isEmpty else { return }
      let byKey = Dictionary(grouping: records, by: \.key)
      var rows: [LocalizationKey] = []
      var positions: [String: Int] = [:]
      for key in byKey.keys.sorted() {
        guard let ofKey = byKey[key] else { continue }
        positions[key] = rows.count
        rows.append(row(key: key, records: ofKey))
      }
      data = rows
      rowIndex = positions
    }
    /// One row of the table, projected from the records of one key.
    ///
    /// The source is the STORED source text, which is what the reconcile took from the
    /// catalog (including a plural's source form), and everything else is the row's
    /// slots. `maxWidth` is key-scoped in the store — every record of the key carries
    /// the same guideline — so taking the first non-nil one is exact, not a guess.
    private func row(key: String, records: [TranslationRecord]) -> LocalizationKey {
      var targets: [LocalizationString] = []
      for language in Set(records.map(\.language)).sorted() {
        targets.append(slot(language: language, records: records.filter { $0.language == language }))
      }
      return LocalizationKey(
        key: key,
        source: .value(records.first?.sourceText ?? key),
        comment: "",
        maxWidth: records.compactMap(\.maxWidth).first ?? 0,
        targets: targets)
    }
    /// One (key, language) slot, projected from the records of that pair.
    ///
    /// The records are per language and, for a varied key, per category. A plural slot
    /// is rebuilt over the TARGET LANGUAGE'S OWN rules (1.4), which is what keeps its
    /// three bodies parallel: a rule the store has no record for reads empty, and an
    /// empty form is exactly the skeleton a prompt asks to be filled (4.3). `machine`
    /// and `reviewed` are parallel plural bodies too, because the store keeps one row
    /// per form for all three of them.
    private func slot(
      language: String, records: [TranslationRecord]
    ) -> LocalizationString {
      let owner = records.first { $0.category == nil } ?? records[0]
      var slot = LocalizationString(language: language)
      let forms = records.filter { $0.category != nil }
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
      slot.status = Self.status(of: records, value: slot.target)
      slot.versions = Store.version(owner.contextVersions)
      return slot
    }
    /// The status a stored record reads as.
    ///
    /// This is the STORE mapping, and it is not the file mapping (2.1): `state` says who
    /// wrote the value, `autoReviewed` says nobody vouched for it, and an empty value
    /// outranks both — a slot with nothing in it is work whatever its row claims.
    ///
    /// `.stale` is deliberately NOT produced here. A store record cannot express it
    /// (app-side staleness is never written back), so it is the staleness predicate's
    /// output rather than this projection's: a slot is stale when a scope that owns it
    /// moved past the slot's stamp (3.4), and which scopes that predicate consults is
    /// decision 10.11 — a project-document bump deliberately enqueues nothing (2.3).
    /// What this projection does carry is the INPUT to that comparison: every slot keeps
    /// the stamp it was produced against.
    private static func status(
      of records: [TranslationRecord], value: StringBody
    ) -> LocalizationString.Status {
      guard !value.isEmpty, let record = records.first else { return .needsTranslate }
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
    func saveData() throws {
      guard !data.isEmpty else { return }
      var records: [RecordKey: TranslationRecord] = [:]
      for record in try global.store.records(project: id) {
        records[RecordKey(
          key: record.key, language: record.language,
          category: record.category ?? "")] = record
      }
      for row in data {
        for slot in row.targets {
          for form in Self.forms(of: slot) {
            let record = try record(for: row, slot: slot, form: form, of: records)
            // The change gate, for the same reason a document has one: a save is a walk
            // of the whole project, and `Store.upsert` writes per call — so a slot that
            // already says exactly what the session says is skipped, and `updatedAt`
            // keeps meaning when the slot last MOVED.
            guard !unchanged(form, of: slot, record) else { continue }
            let before = record.value
            write(form, of: slot, to: record)
            try global.store.upsert(record)
            // The journal, which is the learning corpus (7.2, 2.5). The ONE edit
            // recorded here is a value a human settled that MOVED: a machine write-back
            // journals itself at the run's write-back, a pure confirmation records
            // nothing (the model agreeing with the human is not a lesson), and the
            // imported resolve is not a lesson about our model at all (6.3).
            if slot.status == .verified, before != record.value {
              try global.store.append(
                TranslationEdit(
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
    }
    /// True when the record already carries exactly what the session says, so writing it
    /// again would be a no-op with a side effect. The mirror of `write(_:of:to:)`: every
    /// field that write sets is compared here, and the two have to agree.
    private func unchanged(
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
    /// A slot's identity in the store: the model's own triple. `Runner` has the same
    /// three fields for the same reason — a plural slot's forms ARE separate records.
    private struct RecordKey: Hashable {
      let key: String
      let language: String
      let category: String
    }
    /// One form of a slot, as the store keeps it.
    private struct Form {
      let category: String?
      let value: String
      let machine: String
      let reviewed: String?
    }
    /// The forms one slot writes: one record with no category for a flat value, one per
    /// category for a plural one. The bodies are read per form, so a slot's three bodies
    /// stay parallel exactly as they were projected.
    private static func forms(of slot: LocalizationString) -> [Form] {
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
    private static func form(_ body: StringBody, _ rule: Plural.Rule) -> String {
      guard case .plural(let plural) = body else { return body.catalogValue }
      return plural.value(for: rule)
    }
    /// The store's record for one form, or the row the store does not hold yet — a
    /// language added in this session has no records until its first save. The new
    /// record carries `.empty` and no value: what the session says is written onto it
    /// by `write(_:of:to:)`, so nothing here is a second guess at the row's state. Its
    /// stamp starts as the SENTINEL (all-zero), never three nils: SwiftData on this SDK
    /// traps re-faulting an all-nil versions row, which is the whole reason the sentinel
    /// exists (7.3).
    private func record(
      for row: LocalizationKey, slot: LocalizationString, form: Form,
      of records: [RecordKey: TranslationRecord]
    ) throws -> TranslationRecord {
      let identity = RecordKey(
        key: row.key, language: slot.language, category: form.category ?? "")
      if let record = records[identity] { return record }
      return TranslationRecord(
        key: row.key,
        sourceText: row.source.catalogValue,
        language: slot.language,
        value: nil,
        state: .empty,
        contextVersions: Store.persistable(.none),
        project: try global.store.projectRow(id: id),
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
    private func write(_ form: Form, of slot: LocalizationString, to record: TranslationRecord) {
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
          record.lastEditor = Self.userName
        }
        if authored {
          record.provider = .manual
          record.confidence = nil
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
