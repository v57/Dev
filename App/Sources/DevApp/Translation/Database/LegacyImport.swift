//
//  LegacyImport.swift
//  Dev
//

import Foundation

/// Copies the SwiftData store the app used before (`Translation.store`) into the translation
/// database, once: the first launch that finds the old file and an empty database runs it.
///
/// Plain SQL over SwiftData's own tables (`ZPROJECT`, `ZTRANSLATIONRECORD`, …), attached to the
/// new file, so it is a few seconds however large the store is. The old file is left exactly
/// as it was. Row ids of projects and documents are kept, so everything that names them —
/// a document's project, an edit's document — still does.
///
/// SwiftData had no unique key for a slot, and the old store holds duplicates of some; the
/// copy keeps one per (project, key, language, category): a human-reviewed value first, then
/// one with a value, then the newest.
nonisolated enum LegacyImport {
  static func run(from legacy: URL, into database: TranslationDatabase) throws {
    let connection = database.connection
    try connection.execute("ATTACH DATABASE '\(legacy.path.replacingOccurrences(of: "'", with: "''"))' AS old")
    defer { try? connection.execute("DETACH DATABASE old") }
    func columns(_ table: String) throws -> Set<String> {
      Set(try connection.query("SELECT name FROM old.pragma_table_info('\(table)')") { $0.string(0) })
    }
    let tables = Set(try connection.query("SELECT name FROM old.sqlite_master WHERE type = 'table'") { $0.string(0) })
    /// A column of an old table, or NULL where that store never had it.
    func column(_ name: String, in available: Set<String>, as alias: String? = nil) -> String {
      available.contains(name) ? (alias.map { "\($0).\(name)" } ?? name) : "NULL"
    }

    try connection.transaction {
      if tables.contains("ZPROJECT") {
        try connection.execute(
          """
          INSERT OR REPLACE INTO project (id, name, catalog_url, root_url, icon_url, created_at)
          SELECT Z_PK, coalesce(ZNAME, ''), coalesce(ZCATALOGURL, ''), ZROOTURL, ZICONURL, coalesce(ZCREATEDAT, 0)
          FROM old.ZPROJECT
          """)
      }
      if tables.contains("ZTRANSLATIONRECORD") {
        let c = try columns("ZTRANSLATIONRECORD")
        func col(_ name: String) -> String { column(name, in: c) }
        try connection.execute(
          """
          INSERT OR REPLACE INTO slot (project, key, language, category, source_text, value, provider,
            auto_reviewed, state, confidence, v_global, v_project, v_language, created_at, updated_at,
            reviewed_at, last_editor, note, note_scope, note_folded_at, note_folded_text, max_width,
            machine, reviewed, has_edits)
          SELECT ZPROJECT1, ZKEY, ZLANGUAGE1, coalesce(\(col("ZCATEGORY")), ''), coalesce(ZSOURCETEXT, ''),
            ZVALUE, ZPROVIDER, coalesce(\(col("ZAUTOREVIEWED")), 0), coalesce(ZSTATE, 'empty'),
            ZCONFIDENCE, ZGLOBAL, ZPROJECT, ZLANGUAGE, coalesce(ZCREATEDAT, 0), coalesce(ZUPDATEDAT, 0),
            ZREVIEWEDAT, ZLASTEDITOR, \(col("ZNOTE")), \(col("ZNOTESCOPE")), \(col("ZNOTEFOLDEDAT")),
            \(col("ZNOTEFOLDEDTEXT")), \(col("ZMAXWIDTH")), \(col("ZMACHINE")), \(col("ZREVIEWED")), 0
          FROM old.ZTRANSLATIONRECORD
          WHERE ZPROJECT1 IS NOT NULL AND ZKEY IS NOT NULL AND ZLANGUAGE1 IS NOT NULL
          ORDER BY (ZSTATE = 'reviewed' AND coalesce(\(col("ZAUTOREVIEWED")), 0) = 0),
                   (ZVALUE IS NOT NULL AND ZVALUE <> ''), ZUPDATEDAT
          """)
        if tables.contains("ZTRANSLATIONEDIT") {
          let r = try columns("ZTRANSLATIONRECORD")
          try connection.execute(
            """
            INSERT INTO edit (project, key, language, category, from_value, to_value, editor, reason,
              v_global, v_project, v_language, is_user_confirmed, created_at)
            SELECT r.ZPROJECT1, r.ZKEY, r.ZLANGUAGE1, coalesce(\(column("ZCATEGORY", in: r, as: "r")), ''),
              e.ZFROMVALUE, coalesce(e.ZTOVALUE, ''), coalesce(e.ZEDITOR, 'provider'), e.ZREASON,
              e.ZGLOBAL, e.ZPROJECT, e.ZLANGUAGE, coalesce(e.ZISUSERCONFIRMED, 0), coalesce(e.ZCREATEDAT, 0)
            FROM old.ZTRANSLATIONEDIT e JOIN old.ZTRANSLATIONRECORD r ON r.Z_PK = e.ZRECORD
            WHERE r.ZPROJECT1 IS NOT NULL AND r.ZKEY IS NOT NULL AND r.ZLANGUAGE1 IS NOT NULL
            ORDER BY e.ZCREATEDAT, e.Z_PK
            """)
          try connection.execute(
            """
            UPDATE slot SET has_edits = 1 WHERE EXISTS (
              SELECT 1 FROM edit WHERE edit.project = slot.project AND edit.key = slot.key
                AND edit.language = slot.language AND edit.category = slot.category)
            """)
        }
      }
      if tables.contains("ZTRANSLATIONMEMORYENTRY") {
        try connection.execute(
          """
          INSERT OR REPLACE INTO memory (source_text, source_language, target_language, value, provider,
            state, project_tag, v_global, v_project, v_language, confirmed_at, confidence)
          SELECT ZSOURCETEXT, coalesce(ZSOURCELANGUAGE, ''), ZTARGETLANGUAGE, coalesce(ZVALUE, ''),
            coalesce(ZPROVIDER, 'manual'), coalesce(ZSTATE, 'needs_review'), ZPROJECTTAG,
            ZGLOBAL, ZPROJECT, ZLANGUAGE, ZCONFIRMEDAT, ZCONFIDENCE
          FROM old.ZTRANSLATIONMEMORYENTRY
          WHERE ZSOURCETEXT IS NOT NULL AND ZTARGETLANGUAGE IS NOT NULL
          """)
      }
      if tables.contains("ZCONTEXTDOC") {
        try connection.execute(
          """
          INSERT OR REPLACE INTO context_doc (id, scope, identifier, version, content, created_at, updated_at, project)
          SELECT Z_PK, coalesce(ZSCOPE, 'global'), ZIDENTIFIER, coalesce(ZVERSION, 1), coalesce(ZCONTENT, ''),
            coalesce(ZCREATEDAT, 0), coalesce(ZUPDATEDAT, 0), ZPROJECT
          FROM old.ZCONTEXTDOC
          """)
      }
      if tables.contains("ZCONTEXTEDIT") {
        try connection.execute(
          """
          INSERT INTO context_edit (doc, before, after, reason, author, created_at)
          SELECT ZCONTEXTDOC, ZBEFORE, coalesce(ZAFTER, ''), coalesce(ZREASON, ''), coalesce(ZAUTHOR, 'manual'),
            coalesce(ZCREATEDAT, 0)
          FROM old.ZCONTEXTEDIT WHERE ZCONTEXTDOC IS NOT NULL ORDER BY ZCREATEDAT, Z_PK
          """)
      }
      if tables.contains("ZRUNCURSOR") {
        try connection.execute(
          """
          INSERT OR REPLACE INTO run_cursor (project, stage, batch_index, updated_at)
          SELECT ZPROJECT, ZSTAGE, coalesce(ZBATCHINDEX, 0), coalesce(ZUPDATEDAT, 0)
          FROM old.ZRUNCURSOR WHERE ZPROJECT IS NOT NULL AND ZSTAGE IS NOT NULL ORDER BY ZUPDATEDAT
          """)
      }
      if tables.contains("ZSERVERCONNECTION") {
        try connection.execute(
          """
          INSERT OR REPLACE INTO server_connection (id, name, endpoint, added_at, key_account)
          SELECT ZID, coalesce(ZNAME, ''), coalesce(ZENDPOINT, ''), coalesce(ZADDEDAT, 0), coalesce(ZKEYACCOUNT, ZID)
          FROM old.ZSERVERCONNECTION WHERE ZID IS NOT NULL
          """)
      }
    }
  }
}
