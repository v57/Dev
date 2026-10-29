import Foundation
import Testing

@testable import DevApp

/// A plural taken away in Xcode stays away: the app's form records, reviewed or not, never
/// write their forms back over a flat value a person confirmed in the file.
@Suite struct ReviewedFlatShapeTests {
  let key = "%@ Diamonds"

  func catalog(ruState: String) throws -> StringCatalog {
    let json = """
      {"sourceLanguage":"en","version":"1.0","strings":{"\(key)":{"localizations":{
        "ru":{"stringUnit":{"state":"\(ruState)","value":"%@ алмазов"}}}}}}
      """
    return try JSONDecoder().decode(StringCatalog.self, from: Data(json.utf8))
  }

  /// What the store kept from the plural era: a flat record adopted from the file and per-form
  /// records a person reviewed in the app.
  var records: [TranslationRecord] {
    let forms = ["one": "%@ алмаз", "few": "%@ алмаза", "many": "%@ алмазов", "other": "%@ алмазов"]
    var records = [
      TranslationRecord(
        key: key, sourceText: key, language: "ru", value: "%@ алмазов", state: .reviewed,
        projectID: 1)
    ]
    for (category, value) in forms {
      records.append(TranslationRecord(
        key: key, sourceText: key, language: "ru", value: value, provider: .deepseek,
        state: .reviewed, reviewedAt: .now, lastEditor: "Dmitry", projectID: 1, category: category))
    }
    return records
  }

  @Test func reviewedFlatSlotIsHeldFlat() throws {
    #expect(try catalog(ruState: "translated").holdsReviewedFlat(key: key, language: "ru"))
    #expect(try !catalog(ruState: "needs_review").holdsReviewedFlat(key: key, language: "ru"))
    var plural = try catalog(ruState: "translated")
    plural.varyByPlural(key: key, languages: ["ru"])
    #expect(!plural.holdsReviewedFlat(key: key, language: "ru"))
  }

  @Test func mergeKeepsAReviewedFlatSlotFlat() throws {
    let merged = Reconcile.merge(try catalog(ruState: "translated"), records: records)
    #expect(!merged.catalog.hasPlurals(for: key, language: "ru"))
    #expect(merged.catalog.strings[key]?.localizations?["ru"]?.stringUnit?.value == "%@ алмазов")
  }
}
