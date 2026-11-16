import Foundation
import Testing

@testable import DevApp

/// The translate wire: lines out (`Prompt`), lines back (`Validator.Scanner`).
@MainActor struct TranslationWireTests {
  typealias Validator = Translation.Validator
  typealias Prompt = Translation.Prompt

  @Test func scannerReadsLinesAndEnd() {
    var scanner = Validator.Scanner()
    var rows = scanner.feed("0\tProjekt öffnen\n1\t„%@“ lö")
    #expect(rows == [.init(id: "0", text: "Projekt öffnen")])
    rows = scanner.feed("schen?\n2.one\t%lld Datei\n2.other\t%lld Dateien\nEND\n")
    #expect(rows.count == 2)
    #expect(rows[0] == .init(id: "1", text: "„%@“ löschen?"))
    #expect(rows[1].id == "2")
    #expect(rows[1].text == #"{"one":"%lld Datei","other":"%lld Dateien"}"#)
    #expect(!scanner.isCut)
  }

  @Test func scannerKeepsRowsOfACutReply() {
    let raw = "0\tEins\n1\tZwei\n2\tDr"
    var scanner = Validator.Scanner()
    let rows = scanner.feed(raw) + scanner.finish()
    #expect(rows.map(\.id) == ["0", "1", "2"])
    #expect(scanner.isCut)
    #expect(Validator.isTruncated(raw))
    #expect(!Validator.isTruncated(raw + "ei\nEND"))
  }

  @Test func scannerToleratesDrift() {
    let raw = """
      Here you go:
      ```
      0: Öffnen
      1 Schließen
      2\tde\tSichern
      ```
      END
      """
    let answers = Validator.answers(in: raw)
    #expect(answers == ["0": "Öffnen", "1": "Schließen", "2": "Sichern"])
  }

  @Test func scannerIgnoresWhatFollowsEnd() {
    #expect(Validator.answers(in: "0\tJa\nEND\n1\tNein") == ["0": "Ja"])
  }

  @Test func decodeTurnsEscapesBackOnlyWhereTheSourceHadThem() {
    let multiline = Translation.Run.Item(
      key: "k", language: "de", source: .value("Line one\nLine two"), target: .empty, comment: "", maxWidth: 0)
    #expect(Validator.decode(#"Zeile eins\nZeile zwei"#, for: multiline, language: "de") == .value("Zeile eins\nZeile zwei"))
    let literal = Translation.Run.Item(
      key: "k", language: "de", source: .value(#"Type \n for a newline"#), target: .empty, comment: "", maxWidth: 0)
    #expect(Validator.decode(#"Tippe \n für eine neue Zeile"#, for: literal, language: "de") == .value(#"Tippe \n für eine neue Zeile"#))
  }

  @Test func pluralRowDecodesIntoTheLanguagesForms() {
    var source = Plurals(language: "en")
    source.set("%lld file", for: .one)
    source.set("%lld files", for: .other)
    let item = Translation.Run.Item(
      key: "k", language: "ru", source: .plural(source), target: .empty, comment: "", maxWidth: 0)
    let reply = "0.one\t%lld файл\n0.few\t%lld файла\n0.many\t%lld файлов\n0.other\t%lld файла\nEND"
    let answers = Validator.answers(in: reply)
    let body = Validator.decode(answers["0"] ?? "", for: item, language: "ru")
    guard case .plural(let plural) = body else {
      Issue.record("expected a plural body")
      return
    }
    #expect(plural.value(for: .few) == "%lld файла")
    #expect(Validator.defects(body, of: item, language: "ru").isEmpty)
  }

  @Test func languageRequestKeepsTheStablePartFirst() {
    let items = [
      Translation.Run.Item(
        key: "open", language: "de", source: .value("Open\nProject"), target: .empty, comment: "Menu item",
        maxWidth: 12)
    ]
    let request = Prompt.languageRequest(
      language: "de", items: items, shared: ["CONTEXT — PROJECT\nRules"], style: "Use Sie.",
      glossary: ["Project = Projekt"], keep: ["Xcode"])
    #expect(request.user.hasPrefix(request.prefix))
    #expect(request.prefix.contains("TARGET LANGUAGE\nGerman (de)"))
    #expect(request.prefix.contains("STYLE\nUse Sie."))
    #expect(!request.prefix.contains("GLOSSARY"))
    #expect(request.user.hasSuffix("ITEMS\n0\tOpen\\nProject\n  note: Menu item\n  max: 12"))
    #expect(request.ids == ["0"])
    #expect(!request.user.contains("open"))
  }

  @Test func rowRequestListsSettledReferencesAndEditableValues() {
    let items = [
      Translation.Run.Item(
        key: "save", language: "de", source: .value("Save"), target: .value("Speichern"), comment: "",
        maxWidth: 0),
      Translation.Run.Item(
        key: "save", language: "fr", source: .value("Save"), target: .value("Sauver"), comment: "", maxWidth: 0),
    ]
    let request = Prompt.rowRequest(items: items, shared: []) { _ in
      [("de", "Sichern"), ("ja", "保存")]
    }
    #expect(request.user == "ROWS\nROW\tSave\nja\t保存\n0\tde\tSpeichern\n1\tfr\tSauver")
  }

  @Test func styleRulesStartFromTheLanguage() {
    #expect(Translation.StyleRules.rules(for: "de").contains("Sie"))
    #expect(Translation.StyleRules.rules(for: "zh-Hant").contains("Traditional"))
    #expect(Translation.Languages.name(of: "pt-PT").contains("Portug"))
    #expect(Translation.Languages.script(of: "zh-Hans") == .han)
  }

  @Test func sourceIndexMatchesLiteralsToKeys() throws {
    let source = #"""
      // Text("Commented out")
      struct V: View {
        var body: some View {
          Text("Delete “\(name)”?")
          Button("Open Project") {}
          Text(verbatim: "say \("nested \(1)") here")
        }
      }
      """#
    let literals = Translation.SourceIndex.literals(in: source)
    #expect(literals.map(\.text).contains("Delete “\u{1}”?"))
    #expect(!literals.map(\.text).contains("Commented out"))
    #expect(literals.first { $0.text == "Open Project" }?.line == 5)

    let root = FileManager.default.temporaryDirectory.appendingPathComponent("SourceIndex-\(UUID().uuidString)")
    let folder = root.appendingPathComponent("Sidebar")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try source.write(to: folder.appendingPathComponent("Row.swift"), atomically: true, encoding: .utf8)
    let found = Translation.SourceIndex.locations(of: ["Delete “%@”?", "Open Project", "Missing"], in: [root])
    #expect(found["Delete “%@”?"]?.file == root.lastPathComponent + "/Sidebar/Row.swift")
    #expect(found["Open Project"]?.line == 5)
    #expect(found["Missing"] == nil)
  }

  @Test func keepListsNamesAndAcronyms() {
    let item = Translation.Run.Item(
      key: "k", language: "de", source: .value("Sync with iCloud over SSH, or open URLs in GitHub. OK"),
      target: .empty, comment: "", maxWidth: 0)
    #expect(Prompt.keep([item]) == ["GitHub", "SSH", "URLs", "iCloud"])
  }

  @Test func itemsOfOneFileFollowItsHeader() {
    let items = ["Open", "Close"].map {
      Translation.Run.Item(
        key: $0, language: "de", source: .value($0), target: .empty, comment: "", maxWidth: 0, file: "App/Menu.swift")
    }
    #expect(Prompt.itemLines(items, language: "de") == "# App/Menu.swift\n0\tOpen\n1\tClose")
  }
}
