//
//  TranslationData.swift
//  Dev
//

import Foundation
import os

/// One project's slot records, by slot, with an index by key — so one row's records are a
/// lookup, not a walk of six figures of them. A value: a snapshot handed to a background pass
/// costs nothing until one side writes.
nonisolated struct ProjectRecords: Sendable {
  private(set) var bySlot: [SlotKey: TranslationRecord] = [:]
  private(set) var slotsByKey: [String: Set<SlotKey>] = [:]
  /// How many records each language has, so the language set is not a walk.
  private var languageCounts: [String: Int] = [:]

  init() {}

  init(_ records: [TranslationRecord]) {
    bySlot.reserveCapacity(records.count)
    for record in records { self[record.slotKey] = record }
  }

  subscript(slot: SlotKey) -> TranslationRecord? {
    get { bySlot[slot] }
    set {
      if let newValue {
        if bySlot.updateValue(newValue, forKey: slot) == nil {
          slotsByKey[slot.key, default: []].insert(slot)
          languageCounts[slot.language, default: 0] += 1
        }
      } else if bySlot.removeValue(forKey: slot) != nil {
        slotsByKey[slot.key]?.remove(slot)
        if slotsByKey[slot.key]?.isEmpty == true { slotsByKey[slot.key] = nil }
        languageCounts[slot.language, default: 0] -= 1
        if languageCounts[slot.language] == 0 { languageCounts[slot.language] = nil }
      }
    }
  }

  /// Every record of one key (every language and form), in a FIXED order — by language, the
  /// flat record before the forms, the forms in CLDR order — because callers read "the first
  /// record of the key" (its note, its width, a slot's status) and a set's order is not one.
  func records(key: String) -> [TranslationRecord] {
    (slotsByKey[key] ?? []).sorted { a, b in
      a.language != b.language
        ? a.language < b.language
        : Self.categoryRank(a.category) < Self.categoryRank(b.category)
    }.compactMap { bySlot[$0] }
  }

  private static func categoryRank(_ category: String) -> Int {
    switch category {
    case "": 0
    case "zero": 1
    case "one": 2
    case "two": 3
    case "few": 4
    case "many": 5
    case "other": 6
    default: 7
    }
  }

  /// Every record, unordered.
  var values: Dictionary<SlotKey, TranslationRecord>.Values { bySlot.values }
  var count: Int { bySlot.count }
  var isEmpty: Bool { bySlot.isEmpty }
  var keys: Dictionary<String, Set<SlotKey>>.Keys { slotsByKey.keys }

  /// The languages the records carry.
  var languages: Set<String> { Set(languageCounts.keys) }
}

/// The app's translation data, in memory on the main actor and persisted in the background.
///
/// Every read is a dictionary lookup and every write a dictionary store plus a change queued for
/// the writer, which applies the queued changes to `Translation.sqlite` in one transaction on its
/// own serial queue. Nothing here touches the database on the main thread.
///
/// The small tables (projects, context documents, run cursors, servers) are loaded once at
/// launch (`start`). A project's records — six figures on a real catalog — are loaded when
/// something first asks for them (`loadRecords`), off the main thread, and stay. Translation
/// memory is loaded the same way (`loadMemory`). The journal is only appended to; reading it is
/// an async query (`edits`).
///
/// Records are VALUES: a change is a copy handed back to `upsert`. Who needs to know about one
/// subscribes (`observeRecords`) and is told which slots moved, once per main-actor turn.
@MainActor final class TranslationData {
  /// The app's store. A test swaps in one over a file of its own (`init(location:)`), so it
  /// never reads or writes the user's.
  static var shared = TranslationData(
    location: LaunchOptions.isScreenshotMode ? nil : TranslationData.databaseURL)

  private let writer: Writer

  /// A store over the database at `location` (nil: in memory). A new file there imports the
  /// SwiftData store beside it (`legacyStoreURL`) only for the app's own location.
  init(location: URL?) {
    writer = Writer(location: location, importsLegacyStore: location == Self.databaseURL)
  }

  // MARK: - launch

  /// True once the small tables are loaded.
  private(set) var isReady = false
  private var startTask: Task<Void, Never>?
  /// What went wrong opening the database, for the UI.
  private(set) var openError: String?

  /// Opens the database — importing the old SwiftData store the first time — and loads the
  /// small tables. Safe to call more than once; every caller awaits the same work.
  func start() async {
    if let startTask { return await startTask.value }
    let task = Task {
      let loaded = await writer.read { database -> Result<Snapshot, Error> in
        Result {
          Snapshot(
            projects: try database.projects(),
            documents: try database.documents(),
            cursors: try database.cursors(),
            servers: try database.servers(),
            nextDocumentID: try database.maxID("context_doc") + 1)
        }
      }
      switch loaded {
      case .success(let snapshot):
        projectsByID = Dictionary(snapshot.projects.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        documentsByID = Dictionary(snapshot.documents.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        cursorsByKey = Dictionary(
          snapshot.cursors.map { (CursorKey(project: $0.project, stage: $0.stage), $0) },
          uniquingKeysWith: { $1 })
        serversByID = Dictionary(snapshot.servers.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        nextProjectID = (projectsByID.keys.max() ?? 0) + 1
        nextDocumentID = snapshot.nextDocumentID
      case .failure(let error):
        openError = error.localizedDescription
        NSLog("[TranslationData] could not open the database: %@", error as NSError)
      }
      isReady = true
    }
    startTask = task
    await task.value
  }

  private struct Snapshot: Sendable {
    let projects: [Project]
    let documents: [ContextDoc]
    let cursors: [RunCursor]
    let servers: [ServerConnection]
    let nextDocumentID: Int64
  }

  /// `~/Library/Application Support/dev.v57.dev/Translation.sqlite`.
  nonisolated static var databaseURL: URL {
    applicationSupport.appendingPathComponent("Translation.sqlite")
  }

  /// The SwiftData store the app kept before, imported once into the database.
  nonisolated static var legacyStoreURL: URL {
    applicationSupport.appendingPathComponent("Translation.store")
  }

  nonisolated static var applicationSupport: URL {
    URL.applicationSupportDirectory.appendingPathComponent("dev.v57.dev", isDirectory: true)
  }

  // MARK: - projects

  private var projectsByID: [Int64: Project] = [:]
  private var nextProjectID: Int64 = 1

  /// Every project, oldest first.
  var projects: [Project] { projectsByID.values.sorted { $0.id < $1.id } }

  func project(id: Int64) -> Project? { projectsByID[id] }

  /// A new project row.
  @discardableResult
  func insertProject(
    name: String, catalogURL: URL, rootURL: URL? = nil, iconURL: URL? = nil
  ) -> Project {
    let project = Project(
      id: nextProjectID, name: name, catalogURL: catalogURL, rootURL: rootURL, iconURL: iconURL)
    nextProjectID += 1
    update(project)
    return project
  }

  func update(_ project: Project) {
    projectsByID[project.id] = project
    writer.queue { $0.projects[project.id] = project }
  }

  /// Deletes a project with its records, journal and project document.
  func deleteProject(id: Int64) {
    projectsByID[id] = nil
    recordsByProject[id] = nil
    generations[id, default: 0] += 1
    loadingRecords[id] = nil
    for doc in documentsByID.values where doc.projectID == id {
      deleteDocument(id: doc.id)
    }
    writer.queue {
      $0.projects[id] = .some(nil)
      $0.deleteRecords(ofProject: id)
    }
    notify(project: id, slots: [])
  }

  // MARK: - records

  private var recordsByProject: [Int64: ProjectRecords] = [:]
  private var loadingRecords: [Int64: Task<ProjectRecords, Never>] = [:]
  /// Writes made while a project's records were loading, applied over the loaded set.
  private var writesWhileLoading: [Int64: [SlotKey: TranslationRecord?]] = [:]

  /// A project's records, loading them off the main thread the first time.
  func loadRecords(project: Int64) async -> ProjectRecords {
    if let loaded = recordsByProject[project] { return loaded }
    if let loading = loadingRecords[project] { return await loading.value }
    writesWhileLoading[project] = [:]
    let task = Task { [writer] in
      let loaded = await writer.read { database in
        let started = Date()
        let rows = (try? database.records(project: project)) ?? []
        let records = ProjectRecords(rows)
        NSLog("[TranslationData] loaded %d records of project %lld in %.2f s",
              rows.count, project, Date().timeIntervalSince(started))
        return records
      }
      return loaded
    }
    loadingRecords[project] = task
    var records = await task.value
    // A delete or another load may have replaced this one meanwhile.
    if let loaded = recordsByProject[project] { return loaded }
    guard loadingRecords[project] != nil else { return records }
    for (slot, record) in writesWhileLoading[project] ?? [:] {
      records[slot] = record
    }
    writesWhileLoading[project] = nil
    loadingRecords[project] = nil
    recordsByProject[project] = records
    return records
  }

  /// A project's records when they are loaded, else nil.
  func records(project: Int64) -> ProjectRecords? { recordsByProject[project] }

  /// One slot's record, when the project's records are loaded and it has one.
  func record(project: Int64, slot: SlotKey) -> TranslationRecord? {
    recordsByProject[project]?[slot]
  }

  /// The records of one key (every language and form), when the project is loaded.
  func records(project: Int64, key: String) -> [TranslationRecord] {
    recordsByProject[project]?.records(key: key) ?? []
  }

  /// Bumped on every write to a project's records: a background pass that started from
  /// `generation(project:)` may replace the set only while it is still the same.
  private var generations: [Int64: Int] = [:]

  func generation(project: Int64) -> Int { generations[project, default: 0] }

  /// Stores a record (inserting it, or replacing the one in its slot).
  func upsert(_ record: TranslationRecord) {
    upsert([record])
  }

  /// Stores records.
  func upsert(_ records: [TranslationRecord]) {
    guard !records.isEmpty else { return }
    var touched: [Int64: [SlotKey]] = [:]
    for record in records {
      let slot = record.slotKey
      store(record, at: slot, project: record.projectID)
      touched[record.projectID, default: []].append(slot)
    }
    writer.queue { pending in
      for record in records { pending.records[RecordAddress(project: record.projectID, slot: record.slotKey)] = record }
    }
    for (project, slots) in touched { notify(project: project, slots: slots) }
  }

  /// Deletes slots' records.
  func delete(project: Int64, slots: [SlotKey]) {
    guard !slots.isEmpty else { return }
    for slot in slots { store(nil, at: slot, project: project) }
    writer.queue { pending in
      for slot in slots { pending.records[RecordAddress(project: project, slot: slot)] = .some(nil) }
    }
    notify(project: project, slots: slots)
  }

  /// Replaces a whole project's record set with one computed off the main thread from the set
  /// it had at `generation` — but only when nothing wrote the project since; returns false
  /// otherwise, and the caller applies its changes one by one instead.
  ///
  /// The changes are what make the persisted copy match: `upserts` and `deletions` are exactly
  /// the difference between that set and `records`.
  func replaceRecords(
    project: Int64, generation: Int, with records: ProjectRecords,
    upserts: [TranslationRecord], deletions: [SlotKey]
  ) -> Bool {
    guard recordsByProject[project] != nil, generations[project, default: 0] == generation else {
      return false
    }
    recordsByProject[project] = records
    generations[project, default: 0] += 1
    writer.queue { pending in
      for record in upserts { pending.records[RecordAddress(project: project, slot: record.slotKey)] = record }
      for slot in deletions { pending.records[RecordAddress(project: project, slot: slot)] = .some(nil) }
    }
    notify(project: project, slots: upserts.map(\.slotKey) + deletions)
    return true
  }

  private func store(_ record: TranslationRecord?, at slot: SlotKey, project: Int64) {
    generations[project, default: 0] += 1
    if recordsByProject[project] != nil {
      recordsByProject[project]![slot] = record
    } else if writesWhileLoading[project] != nil {
      writesWhileLoading[project]![slot] = .some(record)
    }
  }

  // MARK: - change observation

  /// Called once per main-actor turn with the slots a write moved (empty: the project's whole
  /// record set changed — deleted, cleared or reloaded).
  typealias RecordObserver = @MainActor (_ project: Int64, _ slots: Set<SlotKey>) -> Void

  private var observers: [UUID: RecordObserver] = [:]
  private var pendingNotifications: [Int64: Set<SlotKey>] = [:]
  private var wholeProjects: Set<Int64> = []
  private var notifyScheduled = false

  /// Subscribes to record changes; keep the token for as long as the subscription should last.
  func observeRecords(_ observer: @escaping RecordObserver) -> ObservationToken {
    let id = UUID()
    observers[id] = observer
    return ObservationToken { [weak self] in self?.observers[id] = nil }
  }

  private func notify(project: Int64, slots: [SlotKey]) {
    if slots.isEmpty {
      wholeProjects.insert(project)
    } else {
      pendingNotifications[project, default: []].formUnion(slots)
    }
    guard !notifyScheduled else { return }
    notifyScheduled = true
    DispatchQueue.main.async { [weak self] in
      MainActor.assumeIsolated { self?.deliver() }
    }
  }

  private func deliver() {
    notifyScheduled = false
    var batch = pendingNotifications
    for project in wholeProjects { batch[project] = [] }
    pendingNotifications = [:]
    wholeProjects = []
    for (project, slots) in batch {
      for observer in observers.values { observer(project, slots) }
    }
  }

  // MARK: - journal

  /// Appends a journal row and marks its slot as edited.
  func append(_ edit: TranslationEdit) {
    append([edit])
  }

  func append(_ edits: [TranslationEdit]) {
    guard !edits.isEmpty else { return }
    var marked: [TranslationRecord] = []
    for edit in edits {
      guard var record = recordsByProject[edit.projectID]?[edit.slotKey], !record.hasEdits else { continue }
      record.hasEdits = true
      marked.append(record)
    }
    upsert(marked)
    writer.queue { $0.edits += edits }
  }

  /// A project's journal, oldest first. Reads what was written before it was asked.
  func edits(project: Int64) async -> [TranslationEdit] {
    await writer.read { (try? $0.edits(project: project)) ?? [] }
  }

  // MARK: - translation memory

  private var memoryTable: MemoryTable?
  private var loadingMemory: Task<MemoryTable, Never>?
  private var memoryWritesWhileLoading: [MemoryKey: TranslationMemoryEntry?] = [:]

  /// Loads the translation memory off the main thread, the first time.
  func loadMemory() async {
    if memoryTable != nil { return }
    if let loadingMemory { _ = await loadingMemory.value; return }
    let task = Task { [writer] in
      await writer.read { MemoryTable((try? $0.memory()) ?? []) }
    }
    loadingMemory = task
    var table = await task.value
    guard memoryTable == nil else { return }
    for (key, entry) in memoryWritesWhileLoading { table[key] = entry }
    memoryWritesWhileLoading = [:]
    memoryTable = table
    loadingMemory = nil
  }

  /// True once the memory is loaded.
  var isMemoryLoaded: Bool { memoryTable != nil }

  /// The entry for a (source, source language, target language), when the memory is loaded.
  func memoryEntry(source: String, sourceLanguage: String, targetLanguage: String) -> TranslationMemoryEntry? {
    memoryTable?[MemoryKey(source: source, sourceLanguage: sourceLanguage, targetLanguage: targetLanguage)]
  }

  /// Every entry translating `source` into `targetLanguage`, whatever its source language.
  func memoryEntries(source: String, targetLanguage: String) -> [TranslationMemoryEntry] {
    memoryTable?.entries(source: source, targetLanguage: targetLanguage) ?? []
  }

  /// Every entry into `targetLanguage` (a walk).
  func memoryEntries(targetLanguage: String) -> [TranslationMemoryEntry] {
    memoryTable?.entries.values.filter { $0.targetLanguage == targetLanguage } ?? []
  }

  func upsert(_ entry: TranslationMemoryEntry) {
    let key = MemoryKey(entry)
    if memoryTable != nil { memoryTable![key] = entry } else { memoryWritesWhileLoading[key] = .some(entry) }
    writer.queue { $0.memory[key] = entry }
  }

  func delete(_ entry: TranslationMemoryEntry) {
    let key = MemoryKey(entry)
    if memoryTable != nil { memoryTable![key] = nil } else { memoryWritesWhileLoading[key] = .some(nil) }
    writer.queue { $0.memory[key] = .some(nil) }
  }

  // MARK: - context documents

  private var documentsByID: [Int64: ContextDoc] = [:]
  private var nextDocumentID: Int64 = 1

  var documents: [ContextDoc] { documentsByID.values.sorted { $0.id < $1.id } }

  func document(id: Int64) -> ContextDoc? { documentsByID[id] }

  /// A new document row.
  @discardableResult
  func insertDocument(
    scope: ContextScope, identifier: String?, version: Int = 1, content: String = "",
    projectID: Int64? = nil
  ) -> ContextDoc {
    let doc = ContextDoc(
      id: nextDocumentID, scope: scope, identifier: identifier, version: version,
      content: content, projectID: projectID)
    nextDocumentID += 1
    update(doc)
    return doc
  }

  func update(_ doc: ContextDoc) {
    documentsByID[doc.id] = doc
    writer.queue { $0.documents[doc.id] = doc }
  }

  func deleteDocument(id: Int64) {
    documentsByID[id] = nil
    writer.queue { $0.documents[id] = .some(nil) }
  }

  func append(_ edit: ContextEdit) {
    writer.queue { $0.documentEdits.append(edit) }
  }

  func documentEdits(doc: Int64) async -> [ContextEdit] {
    await writer.read { (try? $0.documentEdits(doc: doc)) ?? [] }
  }

  // MARK: - run cursors

  private var cursorsByKey: [CursorKey: RunCursor] = [:]

  func cursor(project: String, stage: String) -> RunCursor? {
    cursorsByKey[CursorKey(project: project, stage: stage)]
  }

  func update(_ cursor: RunCursor) {
    let key = CursorKey(project: cursor.project, stage: cursor.stage)
    cursorsByKey[key] = cursor
    writer.queue { $0.cursors[key] = cursor }
  }

  // MARK: - localization servers

  private var serversByID: [String: ServerConnection] = [:]

  var servers: [ServerConnection] { Array(serversByID.values) }

  func server(id: String) -> ServerConnection? { serversByID[id] }

  func update(_ server: ServerConnection) {
    serversByID[server.id] = server
    writer.queue { $0.servers[server.id] = server }
  }

  func deleteServer(id: String) {
    serversByID[id] = nil
    writer.queue { $0.servers[id] = .some(nil) }
  }

  // MARK: - counts

  /// Record counts per project, counted by the database.
  func recordCounts() async -> [Int64: RecordCounts] {
    await writer.read { (try? $0.recordCounts()) ?? [:] }
  }

  // MARK: - clearing (Design notes 7.5)

  /// Empties the translation state — records, journal, context documents, memory and run
  /// cursors — and reports what it removed. Projects and servers stay, and no `.xcstrings`
  /// is touched.
  @discardableResult
  func clearTranslationState() async -> StoreClearCounts {
    await flush()
    let counts = await writer.read { database -> StoreClearCounts in
      var counts = StoreClearCounts()
      let c = database.connection
      counts.slots = Int((try? c.scalar("SELECT COUNT(*) FROM slot")) ?? 0)
      counts.journal = Int((try? c.scalar("SELECT COUNT(*) FROM edit")) ?? 0)
      counts.contextDocs = Int((try? c.scalar("SELECT COUNT(*) FROM context_doc")) ?? 0)
      counts.contextEdits = Int((try? c.scalar("SELECT COUNT(*) FROM context_edit")) ?? 0)
      counts.memory = Int((try? c.scalar("SELECT COUNT(*) FROM memory")) ?? 0)
      counts.cursors = Int((try? c.scalar("SELECT COUNT(*) FROM run_cursor")) ?? 0)
      return counts
    }
    if counts.isEmpty { return counts }
    let loaded = Array(recordsByProject.keys)
    for project in loaded { generations[project, default: 0] += 1 }
    recordsByProject = [:]
    loadingRecords = [:]
    writesWhileLoading = [:]
    memoryTable = nil
    loadingMemory = nil
    memoryWritesWhileLoading = [:]
    documentsByID = [:]
    cursorsByKey = [:]
    writer.queue { $0.clearTranslationState() }
    await flush()
    for project in loaded { notify(project: project, slots: []) }
    NSLog("[TranslationData] cleared %@", counts.summary)
    return counts
  }

  // MARK: - persistence

  /// Waits until everything written so far is in the database.
  func flush() async {
    await writer.read { _ in () }
  }

  /// The same, blocking — for the last moment before the app quits.
  func flushBeforeTerminating() {
    writer.flushSynchronously()
  }
}

/// Ends a subscription when cancelled or released.
final class ObservationToken {
  private var cancel: (() -> Void)?

  init(_ cancel: @escaping () -> Void) { self.cancel = cancel }

  func invalidate() {
    cancel?()
    cancel = nil
  }

  deinit { cancel?() }
}

// MARK: - keys

/// A record's address across projects.
nonisolated struct RecordAddress: Hashable, Sendable {
  let project: Int64
  let slot: SlotKey
}

/// A memory entry's identity.
nonisolated struct MemoryKey: Hashable, Sendable {
  let source: String
  let sourceLanguage: String
  let targetLanguage: String

  init(source: String, sourceLanguage: String, targetLanguage: String) {
    self.source = source
    self.sourceLanguage = sourceLanguage
    self.targetLanguage = targetLanguage
  }

  init(_ entry: TranslationMemoryEntry) {
    self.init(
      source: entry.sourceText, sourceLanguage: entry.sourceLanguage,
      targetLanguage: entry.targetLanguage)
  }
}

/// The translation memory, by its unique triple and by (source, target language) — the
/// pair a run looks an entry up by.
nonisolated struct MemoryTable: Sendable {
  private(set) var entries: [MemoryKey: TranslationMemoryEntry] = [:]
  private var bySourceTarget: [SourceTarget: Set<MemoryKey>] = [:]

  private struct SourceTarget: Hashable, Sendable {
    let source: String
    let target: String
  }

  init(_ rows: [TranslationMemoryEntry]) {
    entries.reserveCapacity(rows.count)
    for entry in rows { self[MemoryKey(entry)] = entry }
  }

  subscript(key: MemoryKey) -> TranslationMemoryEntry? {
    get { entries[key] }
    set {
      let pair = SourceTarget(source: key.source, target: key.targetLanguage)
      if let newValue {
        entries[key] = newValue
        bySourceTarget[pair, default: []].insert(key)
      } else {
        entries[key] = nil
        bySourceTarget[pair]?.remove(key)
        if bySourceTarget[pair]?.isEmpty == true { bySourceTarget[pair] = nil }
      }
    }
  }

  func entries(source: String, targetLanguage: String) -> [TranslationMemoryEntry] {
    (bySourceTarget[SourceTarget(source: source, target: targetLanguage)] ?? []).compactMap { entries[$0] }
  }
}

/// A run cursor's identity.
nonisolated struct CursorKey: Hashable, Sendable {
  let project: String
  let stage: String
}

// MARK: - writer

extension TranslationData {
  /// The changes waiting for the database, one entry per row (the last write of a row wins),
  /// so a slot written a hundred times between two flushes is written once.
  nonisolated struct Pending: Sendable {
    var records: [RecordAddress: TranslationRecord?] = [:]
    var deletedProjectRecords: [Int64] = []
    var edits: [TranslationEdit] = []
    var memory: [MemoryKey: TranslationMemoryEntry?] = [:]
    var projects: [Int64: Project?] = [:]
    var documents: [Int64: ContextDoc?] = [:]
    var documentEdits: [ContextEdit] = []
    var cursors: [CursorKey: RunCursor] = [:]
    var servers: [String: ServerConnection?] = [:]
    var clear = false

    var isEmpty: Bool {
      records.isEmpty && deletedProjectRecords.isEmpty && edits.isEmpty && memory.isEmpty
        && projects.isEmpty && documents.isEmpty && documentEdits.isEmpty && cursors.isEmpty
        && servers.isEmpty && !clear
    }

    mutating func deleteRecords(ofProject project: Int64) {
      records = records.filter { $0.key.project != project }
      edits.removeAll { $0.projectID == project }
      deletedProjectRecords.append(project)
    }

    mutating func clearTranslationState() {
      records = [:]
      deletedProjectRecords = []
      edits = []
      memory = [:]
      documents = [:]
      documentEdits = []
      cursors = [:]
      clear = true
    }

    /// As one database write: deletions and upserts never overlap, because each row holds
    /// only its last write.
    var changes: TranslationChanges {
      var changes = TranslationChanges()
      changes.clearTranslationState = clear
      changes.deletedProjectRecords = deletedProjectRecords
      for (address, record) in records {
        if let record { changes.records.append(record) } else {
          changes.deletedRecords.append((address.project, address.slot))
        }
      }
      changes.edits = edits
      for (key, entry) in memory {
        if let entry { changes.memory.append(entry) } else {
          changes.deletedMemory.append((key.source, key.sourceLanguage, key.targetLanguage))
        }
      }
      for (id, project) in projects {
        if let project { changes.projects.append(project) } else { changes.deletedProjects.append(id) }
      }
      for (id, doc) in documents {
        if let doc { changes.documents.append(doc) } else { changes.deletedDocuments.append(id) }
      }
      changes.documentEdits = documentEdits
      changes.cursors = Array(cursors.values)
      for (id, server) in servers {
        if let server { changes.servers.append(server) } else { changes.deletedServers.append(id) }
      }
      return changes
    }
  }

  /// Owns the database on one serial queue: drains the pending changes into it and runs the
  /// reads, in the order they were asked for — so a read sees every write queued before it.
  nonisolated final class Writer: @unchecked Sendable {
    private let dispatch = DispatchQueue(label: "dev.v57.dev.translation-db", qos: .userInitiated)
    private let lock = OSAllocatedUnfairLock(initialState: Pending())
    private let scheduled = OSAllocatedUnfairLock(initialState: false)
    /// Opened on the queue, on first use.
    private var database: TranslationDatabase?
    private let location: URL?
    private let importsLegacyStore: Bool

    init(location: URL?, importsLegacyStore: Bool) {
      self.location = location
      self.importsLegacyStore = importsLegacyStore
    }

    /// Queues a change; the drain is scheduled once, however many changes arrive before it.
    func queue(_ change: @Sendable (inout Pending) -> Void) {
      lock.withLock { change(&$0) }
      let schedule = scheduled.withLock { flag -> Bool in
        if flag { return false }
        flag = true
        return true
      }
      if schedule { dispatch.async { self.drain() } }
    }

    /// Runs `body` on the queue, after every change queued before it is written.
    func read<T: Sendable>(_ body: @escaping @Sendable (TranslationDatabase) -> T) async -> T {
      await withCheckedContinuation { continuation in
        dispatch.async {
          self.drain()
          continuation.resume(returning: body(self.open()))
        }
      }
    }

    func flushSynchronously() {
      dispatch.sync { self.drain() }
    }

    private func drain() {
      scheduled.withLock { $0 = false }
      let pending = lock.withLock { pending -> Pending in
        let taken = pending
        pending = Pending()
        return taken
      }
      guard !pending.isEmpty else { return }
      do {
        try open().apply(pending.changes)
      } catch {
        NSLog("[TranslationData] write failed: %@", error as NSError)
      }
    }

    /// The database, opened the first time — importing the old SwiftData store into a new file.
    private func open() -> TranslationDatabase {
      if let database { return database }
      let opened: TranslationDatabase
      do {
        if let location {
          try FileManager.default.createDirectory(
            at: location.deletingLastPathComponent(), withIntermediateDirectories: true)
          let isNew = !FileManager.default.fileExists(atPath: location.path)
          opened = try TranslationDatabase(url: location)
          let legacy = TranslationData.legacyStoreURL
          if isNew, importsLegacyStore, FileManager.default.fileExists(atPath: legacy.path) {
            let started = Date()
            do {
              try LegacyImport.run(from: legacy, into: opened)
              NSLog("[TranslationData] imported %@ in %.1f s", legacy.lastPathComponent,
                    Date().timeIntervalSince(started))
            } catch {
              NSLog("[TranslationData] import of %@ failed: %@", legacy.path, error as NSError)
            }
          }
        } else {
          opened = try TranslationDatabase(url: URL(fileURLWithPath: ":memory:"))
        }
      } catch {
        NSLog("[TranslationData] %@ could not be opened (%@); using memory", location?.path ?? "-", error as NSError)
        opened = try! TranslationDatabase(url: URL(fileURLWithPath: ":memory:"))
      }
      database = opened
      return opened
    }
  }
}
