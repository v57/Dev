import Foundation
import SwiftData
import Testing

@testable import Dev

/// A plural taken away in Xcode stays away: the app's form records, reviewed or not, never
/// write their forms back over a flat value a person confirmed in the file.
@MainActor @Suite struct ReviewedFlatShapeTests {
  let key = "%@ Diamonds"

  func catalog(ruState: String) throws -> StringCatalog {
    let json = """
      {"sourceLanguage":"en","version":"1.0","strings":{"\(key)":{"localizations":{
        "ru":{"stringUnit":{"state":"\(ruState)","value":"%@ алмазов"}}}}}}
      """
    return try JSONDecoder().decode(StringCatalog.self, from: Data(json.utf8))
  }

  /// A project holding what the store kept from the plural era: a flat record adopted from
  /// the file and per-form records a person reviewed in the app.
  func project() throws -> (ModelContainer, Project) {
    let schema = Schema([
      Project.self, TranslationRecord.self, TranslationEdit.self, ContextDoc.self,
      ContextEdit.self, TranslationMemoryEntry.self, RunCursor.self, ServerConnection.self,
    ])
    let container = try ModelContainer(
      for: schema,
      configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
    let context = container.mainContext
    let project = Project(name: "Test", catalogURL: URL(fileURLWithPath: "/tmp/Test.xcstrings"))
    context.insert(project)
    let forms = ["one": "%@ алмаз", "few": "%@ алмаза", "many": "%@ алмазов", "other": "%@ алмазов"]
    var records = [
      TranslationRecord(
        key: key, sourceText: key, language: "ru", value: "%@ алмазов", state: .reviewed)
    ]
    for (category, value) in forms {
      records.append(TranslationRecord(
        key: key, sourceText: key, language: "ru", value: value, provider: .deepseek,
        state: .reviewed, reviewedAt: .now, lastEditor: "Dmitry", category: category))
    }
    for record in records {
      context.insert(record)
      record.project = project
    }
    try context.save()
    return (container, project)
  }

  @Test func reviewedFlatSlotIsHeldFlat() throws {
    #expect(try catalog(ruState: "translated").holdsReviewedFlat(key: key, language: "ru"))
    #expect(try !catalog(ruState: "needs_review").holdsReviewedFlat(key: key, language: "ru"))
    var plural = try catalog(ruState: "translated")
    plural.varyByPlural(key: key, languages: ["ru"])
    #expect(!plural.holdsReviewedFlat(key: key, language: "ru"))
  }

  @Test func mergeKeepsAReviewedFlatSlotFlat() throws {
    let (container, project) = try project()
    let merged = Reconcile.merge(try catalog(ruState: "translated"), project: project)
    #expect(!merged.catalog.hasPlurals(for: key, language: "ru"))
    #expect(merged.catalog.strings[key]?.localizations?["ru"]?.stringUnit?.value == "%@ алмазов")
    _ = container
  }
}
