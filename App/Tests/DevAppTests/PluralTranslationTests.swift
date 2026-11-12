import Foundation
import Testing

@testable import DevApp

#if canImport(Darwin)
  import Darwin
#endif

/// Count strings in every language: a key whose English source is varied by plural is translated into exactly the
/// target language's CLDR categories, as ICU (what Foundation selects a `.stringsdict` form with) has them; a flat
/// translation from before the source was varied is work again; and an answer must keep the number in every form
/// that covers more than one number.
@Suite struct PluralTranslationTests {
  /// The languages the Translations tool translates into (Localizations.json, 2026-11-12).
  static let languages = [
    "de", "fr", "es", "ja", "zh-Hans", "pt-BR", "ko", "it", "ru", "ar", "ars", "as", "az", "be", "bg", "bn", "bo",
    "brx", "ca", "chr", "ckb", "cs", "cy", "da", "doi", "dv", "el", "et", "fa", "fi", "fil", "fo", "ga", "gu", "haw",
    "he", "hi", "hr", "hu", "hy", "id", "is", "ka", "kk", "km", "kn", "kok", "ks", "ku", "ky", "lo", "lt", "lv", "mai",
    "mi", "mk", "ml", "mn", "mni", "mr", "ms", "mt", "my", "nb", "ne", "nl", "nn", "or", "pa", "pl", "ps", "pt_PT", "ro",
    "sa", "sat", "sd", "si", "sk", "sl", "sq", "sr", "sv", "sw", "ta", "te", "tg", "th", "tk", "to", "tr", "ug", "uk",
    "ur", "vi", "yue",
  ]

  // MARK: the table

  #if canImport(Darwin)
    /// ICU's own answers, from the system's `libicucore` (the library Foundation selects plural forms with).
    struct ICU {
      typealias Open = @convention(c) (UnsafePointer<CChar>, UnsafeMutablePointer<Int32>) -> OpaquePointer?
      typealias Keywords = @convention(c) (OpaquePointer?, UnsafeMutablePointer<Int32>) -> OpaquePointer?
      typealias Next = @convention(c) (OpaquePointer?, UnsafeMutablePointer<Int32>?, UnsafeMutablePointer<Int32>) ->
        UnsafePointer<CChar>?
      typealias Select = @convention(c) (
        OpaquePointer?, Double, UnsafeMutablePointer<UInt16>, Int32, UnsafeMutablePointer<Int32>
      ) -> Int32
      typealias Close = @convention(c) (OpaquePointer?) -> Void
      let open: Open, keywords: Keywords, next: Next, select: Select, close: Close, closeEnum: Close

      init?() {
        guard let library = dlopen("/usr/lib/libicucore.dylib", RTLD_NOW) else { return nil }
        func symbol<T>(_ name: String, _: T.Type) -> T? {
          dlsym(library, name).map { unsafeBitCast($0, to: T.self) }
        }
        guard let open = symbol("uplrules_open", Open.self), let keywords = symbol("uplrules_getKeywords", Keywords.self),
          let next = symbol("uenum_next", Next.self), let select = symbol("uplrules_select", Select.self),
          let close = symbol("uplrules_close", Close.self), let closeEnum = symbol("uenum_close", Close.self)
        else { return nil }
        (self.open, self.keywords, self.next, self.select, self.close, self.closeEnum) =
          (open, keywords, next, select, close, closeEnum)
      }

      /// The language's categories (CLDR order) and how many whole numbers 0…20000 (plus a few millions) each one takes.
      func rules(_ language: String) -> (categories: [String], counts: [String: Int]) {
        var status: Int32 = 0
        let rules = open(language.replacingOccurrences(of: "-", with: "_"), &status)
        defer { close(rules) }
        var found: [String] = []
        let list = keywords(rules, &status)
        while let word = next(list, nil, &status) { found.append(String(cString: word)) }
        closeEnum(list)
        var counts: [String: Int] = [:]
        var buffer = [UInt16](repeating: 0, count: 32)
        for number in Array(0...20000) + [1_000_000, 2_000_000, 10_000_000] {
          let length = select(rules, Double(number), &buffer, 32, &status)
          counts[String(decoding: buffer[0..<Int(length)], as: UTF16.self), default: 0] += 1
        }
        let order = ["zero", "one", "two", "few", "many", "other"]
        return (found.sorted { order.firstIndex(of: $0)! < order.firstIndex(of: $1)! }, counts)
      }
    }

    @Test func theTableIsICUs() throws {
      let icu = try #require(ICU())
      for language in Set(PluralRules.listedLanguages + Self.languages + ["en", "en-GB", "pt-PT", "es-419"]) {
        let rules = icu.rules(language)
        #expect(PluralRules.categories(for: language) == rules.categories, "\(language)")
        let exact = Set(rules.categories.filter { rules.counts[$0] == 1 })
        #expect(PluralRules.exactCategories(for: language) == exact, "\(language)")
      }
    }
  #endif

  @Test func categoriesAndExactForms() {
    #expect(PluralRules.categories(for: "ru") == ["one", "few", "many", "other"])
    #expect(PluralRules.categories(for: "ar") == ["zero", "one", "two", "few", "many", "other"])
    #expect(PluralRules.categories(for: "pt-BR") == ["one", "many", "other"])
    #expect(PluralRules.categories(for: "zh-Hans") == ["other"])
    #expect(PluralRules.categories(for: "de") == ["one", "other"])
    #expect(Plural.rules(language: "pl") == [.one, .few, .many, .other])
    #expect(PluralRules.exactCategories(for: "de") == ["one"])
    #expect(PluralRules.exactCategories(for: "ru").isEmpty)
    #expect(PluralRules.exactCategories(for: "hi").isEmpty)
    #expect(PluralRules.exactCategories(for: "ar") == ["zero", "one", "two"])
  }

  // MARK: a plural source

  let key = "%lld logins"

  /// English varied by plural; Russian translated flat (from before the source was varied), German flat and confirmed
  /// by a person, Polish with every form, Japanese not at all.
  func catalog() throws -> StringCatalog {
    let json = """
      {"sourceLanguage":"en","version":"1.0","strings":{"\(key)":{"localizations":{
        "en":{"variations":{"plural":{
          "one":{"stringUnit":{"state":"translated","value":"%lld login"}},
          "other":{"stringUnit":{"state":"translated","value":"%lld logins"}}}}},
        "ru":{"stringUnit":{"state":"needs_review","value":"%lld логинов"}},
        "de":{"stringUnit":{"state":"translated","value":"%lld Anmeldungen"}},
        "pl":{"variations":{"plural":{
          "one":{"stringUnit":{"state":"needs_review","value":"%lld login"}},
          "few":{"stringUnit":{"state":"needs_review","value":"%lld loginy"}},
          "many":{"stringUnit":{"state":"needs_review","value":"%lld loginów"}},
          "other":{"stringUnit":{"state":"needs_review","value":"%lld loginu"}}}}}}},
        "Open":{"localizations":{"ru":{"stringUnit":{"state":"needs_review","value":"Открыть"}}}}}}
      """
    return try JSONDecoder().decode(StringCatalog.self, from: Data(json.utf8))
  }

  func record(_ language: String, _ value: String, category: String? = nil, state: TranslationState = .needs_review)
    -> TranslationRecord
  {
    TranslationRecord(
      key: key, sourceText: key, language: language, value: value, provider: .deepseek, state: state, projectID: 1,
      category: category)
  }

  @Test func aFlatTranslationUnderAPluralSourceIsWorkAgain() throws {
    let catalog = try catalog()
    #expect(catalog.hasPluralSource(key))
    #expect(!catalog.hasPluralSource("Open"))
    // The store kept the flat machine value and a person's flat German.
    let records = ProjectRecords([record("ru", "%lld логинов"), record("de", "%lld Anmeldungen", state: .reviewed)])
    let rows = Translation.Project.rows(catalog: catalog, records: records, languages: ["de", "ja", "pl", "ru"]).rows
    let row = try #require(rows.first { $0.key == key })
    for language in ["de", "ja", "ru"] {
      let slot = try #require(row.targets.first { $0.language == language })
      #expect(slot.target == .plural(Plurals(language: language)), "\(language)")
      #expect(slot.status == .needsTranslate, "\(language)")
      #expect(slot.needsMachineTranslate)
    }
    let polish = try #require(row.targets.first { $0.language == "pl" })
    guard case .plural(let forms) = polish.target else { Issue.record("Polish isn't plural"); return }
    #expect(forms.values.map(\.rule) == [.one, .few, .many, .other])
    #expect(forms.value(for: .many) == "%lld loginów")
    #expect(polish.status == .translated)
    // A flat key stays flat.
    let open = try #require(rows.first { $0.key == "Open" }?.targets.first { $0.language == "ru" })
    #expect(open.target == .value("Открыть"))
  }

  @Test func formRecordsAreTheSlotUnderAPluralSource() throws {
    let forms = ["one": "%lld логин", "few": "%lld логина", "many": "%lld логинов", "other": "%lld логина"]
    let records = ProjectRecords(
      [record("ru", "%lld логинов")] + forms.map { record("ru", $0.value, category: $0.key) })
    let rows = Translation.Project.rows(catalog: try catalog(), records: records, languages: ["ru"]).rows
    let slot = try #require(rows.first { $0.key == key }?.targets.first)
    guard case .plural(let plural) = slot.target else { Issue.record("Russian isn't plural"); return }
    #expect(plural.value(for: .few) == "%lld логина")
    #expect(slot.status == .translated)
  }

  @Test func aConfirmedFlatValueHoldsNothingBackUnderAPluralSource() throws {
    let catalog = try catalog()
    #expect(!catalog.holdsReviewedFlat(key: key, language: "de"))
    // The file has German's forms (a run wrote them) while the store still has a person's flat German: the load must
    // not flatten the file back.
    var translated = catalog
    translated.setPluralValue("%lld Anmeldung", state: "needs_review", key: key, language: "de", category: "one")
    translated.setPluralValue("%lld Anmeldungen", state: "needs_review", key: key, language: "de", category: "other")
    var entry = try #require(translated.strings[key])
    entry.localizations?["de"]?.stringUnit = nil
    translated.strings[key] = entry
    let records = ProjectRecords([record("de", "%lld Anmeldungen", state: .reviewed)])
    #expect(Reconcile.shapeConflicts(translated, existing: records).isEmpty)
  }

  @Test func progressCountsOnlyEveryForm() throws {
    let progress = SourceProgress(try catalog())
    #expect(progress.keys == 2)
    #expect(progress.translated["pl"] == 1)
    #expect(progress.translated["ru"] == 1)  // "Open" only
    #expect(progress.translated["de"] == nil)
  }

  // MARK: validation

  let source = Translation.StringBody.plural(
    Plurals(array: [Plural(rule: .one, value: "%lld login"), Plural(rule: .other, value: "%lld logins")]))

  func answer(_ language: String, _ forms: [Plural.Rule: String]) -> Translation.StringBody {
    var plural = Plurals(language: language)
    for (rule, value) in forms { plural.set(value, for: rule) }
    return .plural(plural)
  }

  @Test func everyFormIsRequiredWithItsNumber() {
    typealias Validator = Translation.Validator
    let russian: [Plural.Rule: String] = [
      .one: "%lld логин", .few: "%lld логина", .many: "%lld логинов", .other: "%lld логина",
    ]
    #expect(Validator.defects(answer("ru", russian), of: source, language: "ru").isEmpty)
    // A form left out.
    var missing = russian
    missing[.few] = nil
    #expect(Validator.defects(answer("ru", missing), of: source, language: "ru") == [.emptyForm(category: "few")])
    // Russian `one` is also 21 and 31: it has to print the number.
    var spelled = russian
    spelled[.one] = "Один логин"
    #expect(!Validator.defects(answer("ru", spelled), of: source, language: "ru").isEmpty)
    // German `one` is 1 only, Arabic `zero` and `two` 0 and 2: those may say the number in words.
    #expect(
      Validator.defects(answer("de", [.one: "Eine Anmeldung", .other: "%lld Anmeldungen"]), of: source, language: "de")
        .isEmpty)
    let arabic: [Plural.Rule: String] = [
      .zero: "لا تسجيلات", .one: "تسجيل واحد", .two: "تسجيلان", .few: "%lld تسجيلات", .many: "%lld تسجيلًا",
      .other: "%lld تسجيل",
    ]
    #expect(Validator.defects(answer("ar", arabic), of: source, language: "ar").isEmpty)
    // A flat answer (or a flat memory entry) fills `other` alone, which leaves Russian's other forms empty.
    let flat = Translation.Validator.decode("%lld логинов", for: item("ru"), language: "ru")
    #expect(!Validator.defects(flat, of: source, language: "ru").isEmpty)
  }

  func item(_ language: String) -> Translation.Run.Item {
    Translation.Run.Item(
      key: key, language: language, source: source, target: .plural(Plurals(language: language)), comment: "",
      maxWidth: 0)
  }
}
