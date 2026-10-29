import Foundation
import Testing

@testable import DevApp

/// The browser's flows end to end over the store: a catalog file and a database of the test's
/// own (never the user's), driven through `LocalizationStore` the way the pane drives it.
@MainActor @Suite(.serialized) struct LocalizationFlowTests {
  let folder: URL
  let catalogURL: URL
  let databaseURL: URL

  init() throws {
    folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("LocalizationFlowTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    catalogURL = folder.appendingPathComponent("Localizable.xcstrings")
    databaseURL = folder.appendingPathComponent("Translation.sqlite")
    try Self.catalog.write(to: catalogURL, atomically: true, encoding: .utf8)
    TranslationData.shared = TranslationData(location: databaseURL)
  }

  static let catalog = """
    {"sourceLanguage":"en","version":"1.0","strings":{
      "hello":{"localizations":{"de":{"stringUnit":{"state":"translated","value":"Hallo"}}}},
      "bye":{"comment":"Leaving","localizations":{"de":{"stringUnit":{"state":"needs_review","value":"Tschüss"}}}},
      "%lld files":{"localizations":{
        "en":{"variations":{"plural":{"one":{"stringUnit":{"state":"translated","value":"%lld file"}},
                                      "other":{"stringUnit":{"state":"translated","value":"%lld files"}}}}},
        "ru":{"variations":{"plural":{"one":{"stringUnit":{"state":"translated","value":"%lld файл"}},
                                      "few":{"stringUnit":{"state":"translated","value":"%lld файла"}},
                                      "many":{"stringUnit":{"state":"translated","value":"%lld файлов"}},
                                      "other":{"stringUnit":{"state":"translated","value":"%lld файла"}}}}}}}
    }}
    """

  /// Waits (without blocking the main actor) until `condition` holds.
  func until(_ condition: () -> Bool) async throws {
    for _ in 0..<400 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
    #expect(condition())
  }

  func opened() async throws -> (LocalizationStore, Project) {
    let store = LocalizationStore()
    await store.open(catalogURL)
    try await until { !store.isLoading && store.isLoaded && !store.rows.isEmpty }
    let project = try #require(store.project)
    return (store, project)
  }

  var data: TranslationData { .shared }

  @Test func openMirrorsTheCatalogIntoRecordsAndRows() async throws {
    let (store, project) = try await opened()
    #expect(store.rows.count == 3)
    let records = try #require(data.records(project: project.id))
    // hello/de, bye/de and the ru forms (one, few, many, other); plus the empty slots each
    // key gets in the other language.
    #expect(records[SlotKey(key: "hello", language: "de", category: "")]?.state == .reviewed)
    #expect(records[SlotKey(key: "bye", language: "de", category: "")]?.state == .needs_review)
    #expect(records[SlotKey(key: "%lld files", language: "ru", category: "few")]?.value == "%lld файла")
    #expect(records[SlotKey(key: "hello", language: "ru", category: "")]?.state == .empty)
    #expect(store.browserLanguages == ["de", "ru"])
  }

  @Test func anEditIsRecordedJournaledAndSaved() async throws {
    let (store, project) = try await opened()
    store.setValue("Guten Tag", for: "hello", language: "de")
    let record = try #require(data.record(project: project.id, slot: SlotKey(key: "hello", language: "de", category: "")))
    #expect(record.value == "Guten Tag")
    #expect(record.provider == .manual)
    #expect(record.hasEdits)
    #expect(store.hasUnsavedChanges)
    #expect(store.value(for: "hello", language: "de") == "Guten Tag")
    #expect(await data.edits(project: project.id).map(\.toValue) == ["Guten Tag"])
    await store.save()
    #expect(!store.hasUnsavedChanges)
    let saved = try StringCatalog.load(url: catalogURL)
    #expect(saved.strings["hello"]?.localizations?["de"]?.stringUnit?.value == "Guten Tag")
    #expect(saved.strings["hello"]?.localizations?["de"]?.stringUnit?.state == "translated")
  }

  @Test func whatIsWrittenSurvivesAReopenOfTheDatabase() async throws {
    let (store, project) = try await opened()
    store.setValue("Moin", for: "hello", language: "de")
    await data.flush()
    let reopened = TranslationData(location: databaseURL)
    await reopened.start()
    #expect(reopened.project(id: project.id)?.catalogURL == catalogURL)
    let records = await reopened.loadRecords(project: project.id)
    #expect(records[SlotKey(key: "hello", language: "de", category: "")]?.value == "Moin")
  }

  @Test func reviewNoteAndWidthLandOnEveryRecordOfTheKey() async throws {
    let (store, project) = try await opened()
    store.setRowState("bye", .reviewed)
    #expect(data.record(project: project.id, slot: SlotKey(key: "bye", language: "de", category: ""))?.state == .reviewed)
    store.setNote(key: "bye", note: "Keep it casual", scope: .project)
    #expect(store.note(for: "bye").text == "Keep it casual")
    #expect(store.projectContextText.contains("Keep it casual"))
    store.setMaxWidth(key: "bye", width: 8)
    #expect(store.maxWidth(for: "bye") == 8)
    #expect(store.rows.first { $0.key == "bye" }?.maxWidth == 8)
  }

  @Test func pluralsVaryAndCollapseAndRecordsFollow() async throws {
    let (store, project) = try await opened()
    store.toggleLanguage("de")
    store.varyByPlural(key: "bye")
    #expect(store.catalog?.hasPlurals(for: "bye", language: "de") == true)
    #expect(data.record(project: project.id, slot: SlotKey(key: "bye", language: "de", category: "other"))?.value == "Tschüss")
    store.removePlurals(key: "bye")
    #expect(store.catalog?.hasPlurals(for: "bye", language: "de") == false)
    #expect(data.records(project: project.id, key: "bye").allSatisfy { $0.category == nil })
  }

  @Test func anAddedLanguageIsSeededForEveryKey() async throws {
    let (store, project) = try await opened()
    store.addLanguages(["fr"])
    try await until { !store.isAddingLanguage }
    let fr = data.records(project: project.id, key: "hello").filter { $0.language == "fr" }
    #expect(fr.count == 1)
    // A plural source gets its forms straight away.
    #expect(data.records(project: project.id, key: "%lld files").filter { $0.language == "fr" }.count == 2)
    try await until { store.browserLanguages.contains("fr") }
  }

  @Test func aReloadAsksWhenAReviewedFileValueDisagreesWithTheApp() async throws {
    let (store, _) = try await opened()
    // The app owns the value (a human edit) and Xcode changed the file under it.
    store.setValue("Servus", for: "hello", language: "de")
    await store.save()
    var file = try StringCatalog.load(url: catalogURL)
    file.strings["hello"]?.localizations?["de"]?.stringUnit = .init(state: "translated", value: "Grüß Gott")
    try file.save(to: catalogURL)
    await store.reload()
    try await until { store.isVersionsPromptPresented }
    await store.resolveDifferences(.file)
    try await until { !store.isLoading }
    #expect(store.value(for: "hello", language: "de") == "Grüß Gott")
  }

  /// The redesign's session over the same catalog: built, saved untouched, and the file says
  /// exactly what it said — every value and every state (a plural slot once read its state from
  /// whichever form came first, and a save turned reviewed forms into `new`).
  @Test func anUntouchedSessionSavesNothingNew() async throws {
    let (store, _) = try await opened()
    let before = try String(contentsOf: catalogURL, encoding: .utf8)
    let shell = Translation.Shell()
    shell.handOver(store: store, catalogURL: catalogURL)
    let catalog = try #require(store.catalog)
    let workspace = try #require(await shell.focus(catalogURL: catalogURL, catalog: catalog))
    #expect(workspace.project.data.count == 3)
    let ru = workspace.project.row("%lld files")?.targets.first { $0.language == "ru" }
    #expect(ru?.status == .verified)
    await workspace.save()
    #expect(workspace.error == nil)
    let after = try String(contentsOf: catalogURL, encoding: .utf8)
    let units = { (text: String) throws -> [String: String] in
      let parsed = try JSONDecoder().decode(StringCatalog.self, from: Data(text.utf8))
      var found: [String: String] = [:]
      for (key, entry) in parsed.strings {
        for (language, loc) in entry.localizations ?? [:] {
          if let unit = loc.stringUnit { found["\(key)/\(language)"] = "\(unit.state ?? "")|\(unit.value ?? "")" }
          for (category, form) in loc.variations?["plural"] ?? [:] {
            if let unit = form.stringUnit { found["\(key)/\(language)/\(category)"] = "\(unit.state ?? "")|\(unit.value ?? "")" }
          }
        }
      }
      return found
    }
    #expect(try units(after) == units(before))
  }
}
