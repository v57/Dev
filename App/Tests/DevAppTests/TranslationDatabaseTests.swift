import Foundation
import Testing

@testable import DevApp

/// The translation database: what is written comes back, a slot is one row however often it is
/// written, and the SwiftData store the app kept before imports into it once.
@Suite struct TranslationDatabaseTests {
  func database() throws -> (TranslationDatabase, URL) {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("TranslationDatabaseTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return (try TranslationDatabase(url: folder.appendingPathComponent("Translation.sqlite")), folder)
  }

  func record(_ key: String, _ language: String, category: String? = nil, value: String? = "v")
    -> TranslationRecord
  {
    TranslationRecord(
      key: key, sourceText: key, language: language, value: value, provider: .deepseek,
      state: .needs_review, contextVersions: ContextVersions(global: 0, project: 2),
      projectID: 7, category: category, note: "n", maxWidth: 12, machine: "m")
  }

  @Test func recordsEditsAndMemoryRoundTrip() throws {
    let (database, folder) = try database()
    defer { try? FileManager.default.removeItem(at: folder) }
    var changes = TranslationChanges()
    changes.projects = [Project(id: 7, name: "P", catalogURL: URL(fileURLWithPath: "/tmp/P.xcstrings"))]
    let flat = record("hello", "ru")
    let form = record("%d files", "ru", category: "few", value: "%d файла")
    changes.records = [flat, form]
    changes.edits = [TranslationEdit(record: flat, fromValue: nil, toValue: "v", editor: .provider)]
    changes.memory = [TranslationMemoryEntry(
      sourceText: "hello", sourceLanguage: "en", targetLanguage: "ru", value: "привет", state: .reviewed)]
    try database.apply(changes)

    let records = try database.records(project: 7)
    #expect(records.count == 2)
    let read = try #require(records.first { $0.key == "hello" })
    #expect(read == flat)
    #expect(records.first { $0.category == "few" }?.value == "%d файла")
    #expect(try database.edits(project: 7).map(\.toValue) == ["v"])
    #expect(try database.memory().first?.value == "привет")
    #expect(try database.projects().map(\.name) == ["P"])
    let counts = try database.recordCounts()[7]
    #expect(counts?.records == 2)
    #expect(counts?.keys == 2)
    #expect(counts?.languages["ru"]?.needsReview == 2)
  }

  @Test func aSlotIsOneRowAndDeletesApply() throws {
    let (database, folder) = try database()
    defer { try? FileManager.default.removeItem(at: folder) }
    var first = TranslationChanges()
    first.records = [record("a", "de", value: "1")]
    try database.apply(first)
    var second = TranslationChanges()
    second.records = [record("a", "de", value: "2")]
    try database.apply(second)
    #expect(try database.records(project: 7).map(\.value) == ["2"])
    var third = TranslationChanges()
    third.deletedRecords = [(7, SlotKey(key: "a", language: "de", category: ""))]
    try database.apply(third)
    #expect(try database.records(project: 7).isEmpty)
  }

  @Test func pendingWritesKeepTheLastWriteOfARow() {
    var pending = TranslationData.Pending()
    let slot = RecordAddress(project: 7, slot: SlotKey(key: "a", language: "de", category: ""))
    pending.records[slot] = record("a", "de", value: "1")
    pending.records[slot] = .some(nil)
    pending.records[slot] = record("a", "de", value: "3")
    let changes = pending.changes
    #expect(changes.records.map(\.value) == ["3"])
    #expect(changes.deletedRecords.isEmpty)
  }

  /// A store shaped like SwiftData's (Z-prefixed tables), with a duplicated slot.
  @Test func legacyStoreImportsOnceAndKeepsTheReviewedDuplicate() throws {
    let (database, folder) = try database()
    defer { try? FileManager.default.removeItem(at: folder) }
    let legacy = folder.appendingPathComponent("Translation.store")
    let old = try SQLiteConnection(path: legacy.path)
    try old.execute("""
      CREATE TABLE ZPROJECT (Z_PK INTEGER PRIMARY KEY, ZNAME VARCHAR, ZCATALOGURL VARCHAR, ZROOTURL VARCHAR,
        ZICONURL VARCHAR, ZCREATEDAT TIMESTAMP);
      CREATE TABLE ZTRANSLATIONRECORD (Z_PK INTEGER PRIMARY KEY, ZPROJECT1 INTEGER, ZKEY VARCHAR,
        ZLANGUAGE1 VARCHAR, ZCATEGORY VARCHAR, ZSOURCETEXT VARCHAR, ZVALUE VARCHAR, ZPROVIDER VARCHAR,
        ZAUTOREVIEWED INTEGER, ZSTATE VARCHAR, ZCONFIDENCE FLOAT, ZGLOBAL INTEGER, ZPROJECT INTEGER,
        ZLANGUAGE INTEGER, ZCREATEDAT TIMESTAMP, ZUPDATEDAT TIMESTAMP, ZREVIEWEDAT TIMESTAMP,
        ZLASTEDITOR VARCHAR);
      CREATE TABLE ZTRANSLATIONEDIT (Z_PK INTEGER PRIMARY KEY, ZRECORD INTEGER, ZFROMVALUE VARCHAR,
        ZTOVALUE VARCHAR, ZEDITOR VARCHAR, ZREASON VARCHAR, ZGLOBAL INTEGER, ZPROJECT INTEGER,
        ZLANGUAGE INTEGER, ZISUSERCONFIRMED INTEGER, ZCREATEDAT TIMESTAMP);
      INSERT INTO ZPROJECT VALUES (3, 'playgra', 'file:///tmp/playgra/Localizable.xcstrings', NULL, NULL, 10);
      INSERT INTO ZTRANSLATIONRECORD VALUES
        (1, 3, 'k', 'ru', NULL, 'k', 'reviewed one', NULL, 0, 'reviewed', NULL, 0, NULL, NULL, 1, 5, 5, 'Me'),
        (2, 3, 'k', 'ru', NULL, 'k', 'newer machine', 'deepseek', 0, 'needs_review', NULL, 0, NULL, NULL, 1, 9, NULL, NULL);
      INSERT INTO ZTRANSLATIONEDIT VALUES (1, 2, NULL, 'newer machine', 'provider', NULL, 0, NULL, NULL, 0, 9);
      """)
    try LegacyImport.run(from: legacy, into: database)
    let records = try database.records(project: 3)
    #expect(records.count == 1)
    #expect(records.first?.value == "reviewed one")
    #expect(records.first?.hasEdits == true)
    #expect(try database.projects().first?.id == 3)
    #expect(try database.edits(project: 3).count == 1)
  }

  /// A key's records come back in one order however they were stored: by language, the flat
  /// slot first, the forms in CLDR order — callers read "the first record" (a plural slot's
  /// status came from whichever form a set happened to yield first).
  @Test func aKeysRecordsComeInAFixedOrder() {
    let forms = ["other", "many", "one", "few"].map { record("k", "ru", category: $0) }
    var records = ProjectRecords(forms + [record("k", "de"), record("k", "ru")])
    records[SlotKey(key: "x", language: "ru", category: "")] = record("x", "ru")
    #expect(records.records(key: "k").map { "\($0.language)/\($0.category ?? "")" }
      == ["de/", "ru/", "ru/one", "ru/few", "ru/many", "ru/other"])
    #expect(records.languages == ["de", "ru"])
  }
}
