//
//  TranslationDatabase.swift
//  Dev
//

import Foundation

/// Everything one write to the translation database carries. `TranslationData` collects the
/// app's changes into one of these and the writer applies it in ONE transaction, off the main
/// thread.
///
/// Records, edits and memory entries are addressed by their natural keys — a slot by (project,
/// key, language, category), a memory entry by (source, source language, target language) — so
/// nothing waits for a row id the database would assign.
nonisolated struct TranslationChanges: Sendable {
  var records: [TranslationRecord] = []
  /// Slots to delete, per project.
  var deletedRecords: [(project: Int64, slot: SlotKey)] = []
  /// Every slot of a project to delete (the project itself is going).
  var deletedProjectRecords: [Int64] = []
  var edits: [TranslationEdit] = []
  var memory: [TranslationMemoryEntry] = []
  var deletedMemory: [(source: String, sourceLanguage: String, targetLanguage: String)] = []
  var projects: [Project] = []
  var deletedProjects: [Int64] = []
  var documents: [ContextDoc] = []
  var deletedDocuments: [Int64] = []
  var documentEdits: [ContextEdit] = []
  var cursors: [RunCursor] = []
  var servers: [ServerConnection] = []
  var deletedServers: [String] = []
  /// Empties the translation state (records, journal, documents, memory, cursors) before the
  /// rest of this write applies. Projects and servers stay.
  var clearTranslationState = false

  var isEmpty: Bool {
    records.isEmpty && deletedRecords.isEmpty && deletedProjectRecords.isEmpty && edits.isEmpty
      && memory.isEmpty && deletedMemory.isEmpty && projects.isEmpty && deletedProjects.isEmpty
      && documents.isEmpty && deletedDocuments.isEmpty && documentEdits.isEmpty
      && cursors.isEmpty && servers.isEmpty && deletedServers.isEmpty && !clearTranslationState
  }

  /// Folds a later write into this one: the later value of a row wins.
  mutating func append(_ later: TranslationChanges) {
    if later.clearTranslationState {
      self = TranslationChanges(projects: projects, deletedProjects: deletedProjects,
                                servers: servers, deletedServers: deletedServers)
      clearTranslationState = true
    }
    records += later.records
    deletedRecords += later.deletedRecords
    deletedProjectRecords += later.deletedProjectRecords
    edits += later.edits
    memory += later.memory
    deletedMemory += later.deletedMemory
    projects += later.projects
    deletedProjects += later.deletedProjects
    documents += later.documents
    deletedDocuments += later.deletedDocuments
    documentEdits += later.documentEdits
    cursors += later.cursors
    servers += later.servers
    deletedServers += later.deletedServers
  }
}

/// The translation database: one SQLite file (`Translation.sqlite`) holding projects, slot
/// records, the edit journal, translation memory, context documents, run cursors and
/// localization servers.
///
/// Used only from the writer's serial queue (`TranslationData`), never from the main thread:
/// reads return values, and every write is one transaction.
nonisolated final class TranslationDatabase {
  let connection: SQLiteConnection
  let url: URL

  /// The schema this code reads and writes.
  static let schemaVersion: Int64 = 1

  init(url: URL) throws {
    self.url = url
    connection = try SQLiteConnection(path: url.path)
    try connection.execute("PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL; PRAGMA foreign_keys = OFF;")
    try migrate()
  }

  private func migrate() throws {
    let version = try connection.scalar("PRAGMA user_version") ?? 0
    guard version < Self.schemaVersion else { return }
    try connection.transaction {
      try connection.execute(Self.schema)
      try connection.execute("PRAGMA user_version = \(Self.schemaVersion)")
    }
  }

  private static let schema = """
    CREATE TABLE IF NOT EXISTS project (
      id INTEGER PRIMARY KEY,
      name TEXT NOT NULL,
      catalog_url TEXT NOT NULL,
      root_url TEXT,
      icon_url TEXT,
      created_at REAL NOT NULL
    );
    CREATE TABLE IF NOT EXISTS slot (
      project INTEGER NOT NULL,
      key TEXT NOT NULL,
      language TEXT NOT NULL,
      category TEXT NOT NULL DEFAULT '',
      source_text TEXT NOT NULL,
      value TEXT,
      provider TEXT,
      auto_reviewed INTEGER NOT NULL DEFAULT 0,
      state TEXT NOT NULL,
      confidence REAL,
      v_global INTEGER, v_project INTEGER, v_language INTEGER,
      created_at REAL NOT NULL,
      updated_at REAL NOT NULL,
      reviewed_at REAL,
      last_editor TEXT,
      note TEXT, note_scope TEXT, note_folded_at REAL, note_folded_text TEXT,
      max_width INTEGER,
      machine TEXT,
      reviewed TEXT,
      has_edits INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY (project, key, language, category)
    ) WITHOUT ROWID;
    CREATE TABLE IF NOT EXISTS edit (
      id INTEGER PRIMARY KEY,
      project INTEGER NOT NULL,
      key TEXT NOT NULL,
      language TEXT NOT NULL,
      category TEXT NOT NULL DEFAULT '',
      from_value TEXT,
      to_value TEXT NOT NULL,
      editor TEXT NOT NULL,
      reason TEXT,
      v_global INTEGER, v_project INTEGER, v_language INTEGER,
      is_user_confirmed INTEGER NOT NULL,
      created_at REAL NOT NULL
    );
    CREATE INDEX IF NOT EXISTS edit_slot ON edit (project, key, language, category);
    CREATE TABLE IF NOT EXISTS memory (
      source_text TEXT NOT NULL,
      source_language TEXT NOT NULL,
      target_language TEXT NOT NULL,
      value TEXT NOT NULL,
      provider TEXT NOT NULL,
      state TEXT NOT NULL,
      project_tag TEXT,
      v_global INTEGER, v_project INTEGER, v_language INTEGER,
      confirmed_at REAL,
      confidence REAL,
      PRIMARY KEY (source_text, source_language, target_language)
    ) WITHOUT ROWID;
    CREATE TABLE IF NOT EXISTS context_doc (
      id INTEGER PRIMARY KEY,
      scope TEXT NOT NULL,
      identifier TEXT,
      version INTEGER NOT NULL,
      content TEXT NOT NULL,
      created_at REAL NOT NULL,
      updated_at REAL NOT NULL,
      project INTEGER
    );
    CREATE TABLE IF NOT EXISTS context_edit (
      id INTEGER PRIMARY KEY,
      doc INTEGER NOT NULL,
      before TEXT,
      after TEXT NOT NULL,
      reason TEXT NOT NULL,
      author TEXT NOT NULL,
      created_at REAL NOT NULL
    );
    CREATE INDEX IF NOT EXISTS context_edit_doc ON context_edit (doc);
    CREATE TABLE IF NOT EXISTS run_cursor (
      project TEXT NOT NULL,
      stage TEXT NOT NULL,
      batch_index INTEGER NOT NULL,
      updated_at REAL NOT NULL,
      PRIMARY KEY (project, stage)
    ) WITHOUT ROWID;
    CREATE TABLE IF NOT EXISTS server_connection (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      endpoint TEXT NOT NULL,
      added_at REAL NOT NULL,
      key_account TEXT NOT NULL
    ) WITHOUT ROWID;
    """

  // MARK: - reads

  func projects() throws -> [Project] {
    try connection.query(
      "SELECT id, name, catalog_url, root_url, icon_url, created_at FROM project ORDER BY id"
    ) { row in
      Project(
        id: row.int64(0), name: row.string(1), catalogURL: Self.url(row.string(2)),
        createdAt: row.date(5), rootURL: row.stringOptional(3).map(Self.url),
        iconURL: row.stringOptional(4).map(Self.url))
    }
  }

  private static let slotColumns = """
    project, key, language, category, source_text, value, provider, auto_reviewed, state,
    confidence, v_global, v_project, v_language, created_at, updated_at, reviewed_at, last_editor,
    note, note_scope, note_folded_at, note_folded_text, max_width, machine, reviewed, has_edits
    """

  /// Every slot record of a project.
  func records(project: Int64) throws -> [TranslationRecord] {
    try connection.query("SELECT \(Self.slotColumns) FROM slot WHERE project = ?", [.int(project)]) {
      Self.record($0)
    }
  }

  private static func record(_ row: SQLiteRow) -> TranslationRecord {
    let category = row.string(3)
    return TranslationRecord(
      key: row.string(1), sourceText: row.string(4), language: row.string(2),
      value: row.stringOptional(5), provider: row.stringOptional(6).flatMap(Provider.init(rawValue:)),
      state: TranslationState(rawValue: row.string(8)) ?? .empty,
      confidence: row.doubleOptional(9),
      contextVersions: ContextVersions(
        global: row.intOptional(10), project: row.intOptional(11), language: row.intOptional(12)),
      createdAt: row.date(13), updatedAt: row.date(14), reviewedAt: row.dateOptional(15),
      lastEditor: row.stringOptional(16), projectID: row.int64(0), hasEdits: row.bool(24),
      category: category.isEmpty ? nil : category, autoReviewed: row.bool(7),
      note: row.stringOptional(17), noteScope: row.stringOptional(18),
      noteFoldedAt: row.dateOptional(19), noteFoldedText: row.stringOptional(20),
      maxWidth: row.intOptional(21), machine: row.stringOptional(22), reviewed: row.stringOptional(23))
  }

  /// Per project: how many records, distinct keys and `needs_review` records it holds, and the
  /// same per language — the sidebar's badges, counted by the database.
  func recordCounts() throws -> [Int64: RecordCounts] {
    var counts: [Int64: RecordCounts] = [:]
    _ = try connection.query(
      """
      SELECT project, language, COUNT(*), SUM(state = 'needs_review'), SUM(state <> 'empty')
      FROM slot GROUP BY project, language
      """
    ) { row in
      let project = row.int64(0)
      var entry = counts[project] ?? RecordCounts()
      let total = row.int(2), review = row.int(3), translated = row.int(4)
      entry.records += total
      entry.needsReview += review
      entry.languages[row.string(1)] = RecordCounts.Language(records: total, needsReview: review, translated: translated)
      counts[project] = entry
    }
    _ = try connection.query("SELECT project, COUNT(DISTINCT key) FROM slot GROUP BY project") { row in
      counts[row.int64(0), default: RecordCounts()].keys = row.int(1)
    }
    return counts
  }

  /// The journal of a project, oldest first.
  func edits(project: Int64) throws -> [TranslationEdit] {
    try connection.query(
      """
      SELECT project, key, language, category, from_value, to_value, editor, reason,
             v_global, v_project, v_language, is_user_confirmed, created_at
      FROM edit WHERE project = ? ORDER BY created_at, id
      """, [.int(project)]
    ) { row in
      let category = row.string(3)
      return TranslationEdit(
        projectID: row.int64(0), key: row.string(1), language: row.string(2),
        category: category.isEmpty ? nil : category, fromValue: row.stringOptional(4),
        toValue: row.string(5), editor: Editor(rawValue: row.string(6)) ?? .provider,
        reason: row.stringOptional(7),
        contextVersions: ContextVersions(
          global: row.intOptional(8), project: row.intOptional(9), language: row.intOptional(10)),
        isUserConfirmed: row.bool(11), createdAt: row.date(12))
    }
  }

  /// The whole translation memory.
  func memory() throws -> [TranslationMemoryEntry] {
    try connection.query(
      """
      SELECT source_text, source_language, target_language, value, provider, state, project_tag,
             v_global, v_project, v_language, confirmed_at, confidence
      FROM memory
      """
    ) { row in
      TranslationMemoryEntry(
        sourceText: row.string(0), sourceLanguage: row.string(1), targetLanguage: row.string(2),
        value: row.string(3), provider: Provider(rawValue: row.string(4)) ?? .manual,
        state: TranslationState(rawValue: row.string(5)) ?? .needs_review,
        projectTag: row.stringOptional(6),
        contextVersions: ContextVersions(
          global: row.intOptional(7), project: row.intOptional(8), language: row.intOptional(9)),
        confirmedAt: row.dateOptional(10), confidence: row.doubleOptional(11))
    }
  }

  func documents() throws -> [ContextDoc] {
    try connection.query(
      "SELECT id, scope, identifier, version, content, created_at, updated_at, project FROM context_doc"
    ) { row in
      ContextDoc(
        id: row.int64(0), scope: ContextScope(rawValue: row.string(1)) ?? .global,
        identifier: row.stringOptional(2), version: row.int(3), content: row.string(4),
        createdAt: row.date(5), updatedAt: row.date(6), projectID: row.int64Optional(7))
    }
  }

  func documentEdits(doc: Int64) throws -> [ContextEdit] {
    try connection.query(
      "SELECT doc, before, after, reason, author, created_at FROM context_edit WHERE doc = ? ORDER BY created_at, id",
      [.int(doc)]
    ) { row in
      ContextEdit(
        docID: row.int64(0), before: row.stringOptional(1), after: row.string(2),
        reason: row.string(3), author: Provider(rawValue: row.string(4)) ?? .manual,
        createdAt: row.date(5))
    }
  }

  func cursors() throws -> [RunCursor] {
    try connection.query("SELECT project, stage, batch_index, updated_at FROM run_cursor") { row in
      RunCursor(project: row.string(0), stage: row.string(1), batchIndex: row.int(2), updatedAt: row.date(3))
    }
  }

  func servers() throws -> [ServerConnection] {
    try connection.query("SELECT id, name, endpoint, added_at, key_account FROM server_connection") { row in
      var server = ServerConnection(
        id: row.string(0), name: row.string(1), endpoint: row.string(2), addedAt: row.date(3))
      server.keyAccount = row.string(4)
      return server
    }
  }

  /// The largest row id of a table, so `TranslationData` can hand out the next ones itself.
  func maxID(_ table: String) throws -> Int64 {
    try connection.scalar("SELECT MAX(id) FROM \(table)") ?? 0
  }

  // MARK: - writes

  /// Applies one write in one transaction.
  func apply(_ changes: TranslationChanges) throws {
    guard !changes.isEmpty else { return }
    try connection.transaction {
      if changes.clearTranslationState {
        try connection.execute(
          "DELETE FROM slot; DELETE FROM edit; DELETE FROM memory; DELETE FROM context_doc; DELETE FROM context_edit; DELETE FROM run_cursor;")
      }
      for id in changes.deletedProjects {
        try connection.run("DELETE FROM project WHERE id = ?", [.int(id)])
      }
      for project in changes.projects {
        try connection.run(
          """
          INSERT INTO project (id, name, catalog_url, root_url, icon_url, created_at) VALUES (?, ?, ?, ?, ?, ?)
          ON CONFLICT(id) DO UPDATE SET name = excluded.name, catalog_url = excluded.catalog_url,
            root_url = excluded.root_url, icon_url = excluded.icon_url
          """,
          [.int(project.id), .text(project.name), .text(project.catalogURL.absoluteString),
           .text(project.rootURL?.absoluteString), .text(project.iconURL?.absoluteString),
           .date(project.createdAt)])
      }
      for project in changes.deletedProjectRecords {
        try connection.run("DELETE FROM slot WHERE project = ?", [.int(project)])
        try connection.run("DELETE FROM edit WHERE project = ?", [.int(project)])
      }
      if !changes.deletedRecords.isEmpty {
        let delete = try connection.statement(
          "DELETE FROM slot WHERE project = ? AND key = ? AND language = ? AND category = ?")
        for (project, slot) in changes.deletedRecords {
          try delete.run([.int(project), .text(slot.key), .text(slot.language), .text(slot.category)])
        }
      }
      if !changes.records.isEmpty {
        let upsert = try connection.statement(
          """
          INSERT OR REPLACE INTO slot (\(Self.slotColumns))
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          """)
        for record in changes.records {
          try upsert.run(Self.binds(record))
        }
      }
      if !changes.edits.isEmpty {
        let insert = try connection.statement(
          """
          INSERT INTO edit (project, key, language, category, from_value, to_value, editor, reason,
                            v_global, v_project, v_language, is_user_confirmed, created_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          """)
        for edit in changes.edits {
          try insert.run([
            .int(edit.projectID), .text(edit.key), .text(edit.language), .text(edit.category ?? ""),
            .text(edit.fromValue), .text(edit.toValue), .text(edit.editor.rawValue), .text(edit.reason),
            .int(edit.contextVersions.global), .int(edit.contextVersions.project),
            .int(edit.contextVersions.language), .bool(edit.isUserConfirmed), .date(edit.createdAt),
          ])
        }
      }
      for entry in changes.deletedMemory {
        try connection.run(
          "DELETE FROM memory WHERE source_text = ? AND source_language = ? AND target_language = ?",
          [.text(entry.source), .text(entry.sourceLanguage), .text(entry.targetLanguage)])
      }
      if !changes.memory.isEmpty {
        let upsert = try connection.statement(
          """
          INSERT OR REPLACE INTO memory (source_text, source_language, target_language, value, provider,
            state, project_tag, v_global, v_project, v_language, confirmed_at, confidence)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          """)
        for entry in changes.memory {
          try upsert.run([
            .text(entry.sourceText), .text(entry.sourceLanguage), .text(entry.targetLanguage),
            .text(entry.value), .text(entry.provider.rawValue), .text(entry.state.rawValue),
            .text(entry.projectTag), .int(entry.contextVersions.global),
            .int(entry.contextVersions.project), .int(entry.contextVersions.language),
            .date(entry.confirmedAt), .double(entry.confidence),
          ])
        }
      }
      for id in changes.deletedDocuments {
        try connection.run("DELETE FROM context_doc WHERE id = ?", [.int(id)])
        try connection.run("DELETE FROM context_edit WHERE doc = ?", [.int(id)])
      }
      for doc in changes.documents {
        try connection.run(
          """
          INSERT OR REPLACE INTO context_doc (id, scope, identifier, version, content, created_at, updated_at, project)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?)
          """,
          [.int(doc.id), .text(doc.scope.rawValue), .text(doc.identifier), .int(doc.version),
           .text(doc.content), .date(doc.createdAt), .date(doc.updatedAt),
           doc.projectID.map { .int($0) } ?? .null])
      }
      for edit in changes.documentEdits {
        try connection.run(
          "INSERT INTO context_edit (doc, before, after, reason, author, created_at) VALUES (?, ?, ?, ?, ?, ?)",
          [.int(edit.docID), .text(edit.before), .text(edit.after), .text(edit.reason),
           .text(edit.author.rawValue), .date(edit.createdAt)])
      }
      for cursor in changes.cursors {
        try connection.run(
          "INSERT OR REPLACE INTO run_cursor (project, stage, batch_index, updated_at) VALUES (?, ?, ?, ?)",
          [.text(cursor.project), .text(cursor.stage), .int(cursor.batchIndex), .date(cursor.updatedAt)])
      }
      for id in changes.deletedServers {
        try connection.run("DELETE FROM server_connection WHERE id = ?", [.text(id)])
      }
      for server in changes.servers {
        try connection.run(
          "INSERT OR REPLACE INTO server_connection (id, name, endpoint, added_at, key_account) VALUES (?, ?, ?, ?, ?)",
          [.text(server.id), .text(server.name), .text(server.endpoint), .date(server.addedAt),
           .text(server.keyAccount)])
      }
    }
  }

  private static func binds(_ record: TranslationRecord) -> [SQLiteValue] {
    [
      .int(record.projectID), .text(record.key), .text(record.language), .text(record.category ?? ""),
      .text(record.sourceText), .text(record.value), .text(record.provider?.rawValue),
      .bool(record.autoReviewed), .text(record.state.rawValue), .double(record.confidence),
      .int(record.contextVersions.global), .int(record.contextVersions.project),
      .int(record.contextVersions.language), .date(record.createdAt), .date(record.updatedAt),
      .date(record.reviewedAt), .text(record.lastEditor), .text(record.note), .text(record.noteScope),
      .date(record.noteFoldedAt), .text(record.noteFoldedText), .int(record.maxWidth),
      .text(record.machine), .text(record.reviewed), .bool(record.hasEdits),
    ]
  }

  /// A URL as the database keeps it: its absolute string (a file URL survives the round trip).
  static func url(_ string: String) -> URL {
    URL(string: string) ?? URL(fileURLWithPath: string)
  }
}

/// A project's record counts (the sidebar's badges).
nonisolated struct RecordCounts: Sendable, Equatable {
  struct Language: Sendable, Equatable {
    var records = 0
    var needsReview = 0
    /// Records whose state is not `empty`.
    var translated = 0
  }

  var records = 0
  var keys = 0
  var needsReview = 0
  var languages: [String: Language] = [:]
}
