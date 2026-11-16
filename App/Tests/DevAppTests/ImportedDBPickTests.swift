import Testing

@testable import DevApp

/// The imported database's picker: one translation only when the database is sure of it.
struct ImportedDBPickTests {
  private func rows(_ language: String, _ targets: [(String, String)]) -> [ImportedDBRow] {
    targets.map { ImportedDBRow(language: language, target: $0.0, app: $0.1) }
  }

  @Test func aSingleTargetIsTheHit() {
    let hit = ImportedDBLanguage.hit(
      in: rows("de", [("Abbrechen", "Mail")]), forCatalogLanguage: "de", appRowCounts: [:], source: "Cancel")
    #expect(hit?.value == "Abbrechen")
  }

  @Test func targetsNoAppAgreesOnMoreAreAmbiguous() {
    let audio = rows("tr", [("Kulaklık", "Music"), ("Ses", "TV"), ("Sesler", "Clock")])
    #expect(ImportedDBLanguage.hit(in: audio, forCatalogLanguage: "tr", appRowCounts: [:], source: "Audio") == nil)
  }

  @Test func theTargetMoreAppsAgreeOnWins() {
    let audio = rows("tr", [("Kulaklık", "Music"), ("Ses", "TV"), ("Ses", "Podcasts")])
    let hit = ImportedDBLanguage.hit(in: audio, forCatalogLanguage: "tr", appRowCounts: [:], source: "Audio")
    #expect(hit?.value == "Ses")
    #expect(hit?.agreeingApps == 2)
  }

  @Test func junkIsNeverATranslation() {
    let cancel = rows("de", [("ACTION_CANCEL", "A"), ("ABBRECHEN", "B"), ("Abbrechen", "C")])
    #expect(ImportedDBLanguage.hit(in: cancel, forCatalogLanguage: "de", appRowCounts: [:], source: "Cancel")?.value == "Abbrechen")
    #expect(!ImportedDBLanguage.usable("キャンセル(C)", source: "Cancel", language: "ja"))
    #expect(!ImportedDBLanguage.usable("&Öffnen", source: "Open", language: "de"))
    #expect(!ImportedDBLanguage.usable("Cancelar", source: "Cancel", language: "ru"))
    #expect(ImportedDBLanguage.usable("Отмена", source: "Cancel", language: "ru"))
    #expect(ImportedDBLanguage.usable("OK", source: "OK", language: "ja"))
    #expect(ImportedDBLanguage.usable("iCloud Drive", source: "iCloud Drive", language: "ru"))
    #expect(ImportedDBLanguage.usable("USB", source: "USB", language: "de"))
  }
}
