import CryptoKit
import Foundation
import Testing

@testable import DevApp

/// `.dev/store/` in a temporary project, and the services against stubbed requests: nothing here reaches a network.
@Suite struct StoreTextTests {
  private func project() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("store-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func file(_ root: URL, _ path: String) -> String? {
    try? String(contentsOf: root.appendingPathComponent(StoreTexts.path).appendingPathComponent(path), encoding: .utf8)
  }

  // MARK: Files

  @Test func aNewTextIsAPrivateDraftAndTheIgnoreRuleComesFirst() throws {
    let root = try project()
    let texts = StoreTexts(root: root)
    try texts.write("Dev\n\n", at: StoreAddress(field: .name))
    #expect(file(root, "private/en-US/name.txt") == "Dev\n")
    #expect(file(root, "en-US/name.txt") == nil)
    #expect(file(root, ".gitignore")?.contains("/private/") == true)
    #expect(texts.entry(StoreAddress(field: .name)) == .init(text: "Dev", isPrivate: true))
  }

  @Test func gitReallyIgnoresPrivateFiles() async throws {
    let root = try project()
    let texts = StoreTexts(root: root)
    _ = await LineProcess.run("/usr/bin/git", ["init", "-q"], directory: root)
    try texts.write("Hello testers", at: StoreAddress(field: .testers, version: "1.0"))
    try texts.write("A description", at: StoreAddress(field: .description), ready: true)
    let status = await LineProcess.run("/usr/bin/git", ["status", "--porcelain", "-uall"], directory: root)
    #expect(status.output.contains(".dev/store/en-US/description.txt"))
    #expect(!status.output.contains("private"))
    #expect(!status.output.contains("testers"))
  }

  @Test func readyMovesEveryLocaleAndDraftMovesThemBack() throws {
    let root = try project()
    let texts = StoreTexts(root: root)
    var settings = StoreSettings()
    settings.locales = ["de-DE"]
    try texts.save(settings)
    try texts.write("Hello", at: StoreAddress(field: .description))
    try texts.writeTranslation(
      "Hallo", at: StoreAddress(field: .description, locale: "de-DE"), sourceText: "Hello", sourceIsPrivate: true)

    try texts.setReady(true, field: .description)
    #expect(file(root, "en-US/description.txt") == "Hello\n")
    #expect(file(root, "de-DE/description.txt") == "Hallo\n")
    #expect(file(root, "private/de-DE/description.txt") == nil)
    #expect(texts.translationState(of: StoreAddress(field: .description, locale: "de-DE")) == .current)

    try texts.setReady(false, field: .description)
    #expect(file(root, "private/en-US/description.txt") == "Hello\n")
    #expect(file(root, "en-US/description.txt") == nil)
    #expect(texts.translationState(of: StoreAddress(field: .description, locale: "de-DE")) == .current)
  }

  @Test func reviewNotesAndTesterMessagesNeverLeavePrivate() throws {
    let root = try project()
    let texts = StoreTexts(root: root)
    try texts.write("Log in as demo", at: StoreAddress(field: .reviewNotes), ready: true)
    try texts.write("Try this", at: StoreAddress(field: .testers, version: "1.0"), ready: true)
    #expect(file(root, "private/en-US/review-notes.txt") != nil)
    #expect(file(root, "en-US/review-notes.txt") == nil)
    #expect(file(root, "en-US/versions/1.0/testers.txt") == nil)
    #expect(throws: StoreTextError.self) { try texts.setReady(true, field: .reviewNotes) }
  }

  @Test func theBaseTextsReadBackEvenWhenNoDestinationTakesThem() throws {
    let root = try project()
    let texts = StoreTexts(root: root)
    var settings = texts.settings()
    settings.destinations = [.github]
    try texts.save(settings)
    try texts.write("Dev", at: StoreAddress(field: .name), ready: true)
    try texts.write("Try this", at: StoreAddress(field: .testers, version: "1.0"), ready: false)
    #expect(StoreMCP.report(texts, version: "1.0", field: .name).isEmpty)
    #expect(StoreMCP.base(texts, version: "1.0", field: .name).first?["text"] as? String == "Dev")
    let testers = StoreMCP.base(texts, version: "1.0", field: .testers).first
    #expect(testers?["text"] as? String == "Try this")
    #expect(testers?["private"] as? Bool == true)
    #expect(StoreMCP.base(texts, version: nil, field: .testers).isEmpty)
  }

  @Test func anEditStaysWhereTheTextIsAndAnEmptyTextRemovesIt() throws {
    let root = try project()
    let texts = StoreTexts(root: root)
    let address = StoreAddress(field: .subtitle)
    try texts.write("One", at: address, ready: true)
    try texts.write("Two", at: address)
    #expect(file(root, "en-US/subtitle.txt") == "Two\n")
    try texts.write("", at: address)
    #expect(texts.entry(address) == nil)
    #expect(!FileManager.default.fileExists(atPath: texts.folder.appendingPathComponent("en-US").path))
  }

  @Test func pathsCantLeaveTheFolder() throws {
    let texts = StoreTexts(root: try project())
    #expect(throws: StoreTextError.self) { try texts.write("x", at: StoreAddress(field: .name, locale: "../../evil")) }
    #expect(throws: StoreTextError.self) { try texts.write("x", at: StoreAddress(field: .changelog, version: "../x")) }
    #expect(throws: StoreTextError.self) { try texts.write("x", at: StoreAddress(field: .changelog)) }
    #expect(throws: StoreTextError.self) { try texts.write("x", at: StoreAddress(field: .name, locale: ".hidden")) }
  }

  @Test func keywordsAreOnePerLineWhateverIsPasted() throws {
    let root = try project()
    let texts = StoreTexts(root: root)
    try texts.write("swift, xcode,\nrelease", at: StoreAddress(field: .keywords), ready: true)
    #expect(file(root, "en-US/keywords.txt") == "swift\nxcode\nrelease\n")
  }

  @Test func versionsSortNewestFirstAcrossBothFolders() throws {
    let texts = StoreTexts(root: try project())
    try texts.write("a", at: StoreAddress(field: .changelog, version: "1.9.0"), ready: true)
    try texts.write("b", at: StoreAddress(field: .changelog, version: "1.10.0"))
    #expect(texts.versions() == ["1.10.0", "1.9.0"])
  }

  // MARK: Resolving

  @Test func theMostSpecificTextWins() throws {
    let root = try project()
    let texts = StoreTexts(root: root)
    var settings = StoreSettings()
    settings.locales = ["de-DE"]
    try texts.save(settings)
    let base = StoreAddress(field: .description)
    try texts.write("Base", at: base)
    #expect(texts.resolved(.description, destination: .appStore).text == "Base")
    #expect(texts.resolved(.description, destination: .appStore).origin == .base)
    #expect(texts.resolved(.description, locale: "de-DE").origin == .base)

    try texts.write("Apple", at: StoreAddress(field: .description, destination: .appStore))
    #expect(texts.resolved(.description, destination: .appStore).text == "Apple")
    #expect(texts.resolved(.description, destination: .github).text == "Base")
    #expect(texts.resolved(.description, destination: .appStore, locale: "de-DE").origin == .baseOverride)

    // A translation of the base text beats the English override.
    try texts.write("Deutsch", at: StoreAddress(field: .description, locale: "de-DE"))
    #expect(texts.resolved(.description, destination: .appStore, locale: "de-DE").text == "Deutsch")
    try texts.write("Apfel", at: StoreAddress(field: .description, destination: .appStore, locale: "de-DE"))
    #expect(texts.resolved(.description, destination: .appStore, locale: "de-DE").text == "Apfel")
    #expect(texts.resolved(.description, destination: .googlePlay, locale: "de-DE").text == "Deutsch")
  }

  @Test func aChangedSourceMakesATranslationOutdatedAndHandTextIsLeftAlone() throws {
    let texts = StoreTexts(root: try project())
    var settings = StoreSettings()
    settings.locales = ["de-DE"]
    try texts.save(settings)
    try texts.write("Hello", at: StoreAddress(field: .description), ready: true)
    try texts.write("Sub", at: StoreAddress(field: .subtitle), ready: true)
    let german = StoreAddress(field: .description, locale: "de-DE")
    #expect(StoreTranslator.work(in: texts, locale: "de-DE", version: nil).map(\.address.field).sorted { $0.rawValue < $1.rawValue } == [.description, .subtitle])

    try texts.writeTranslation("Hallo", at: german, sourceText: "Hello", sourceIsPrivate: false)
    #expect(texts.translationState(of: german) == .current)
    #expect(StoreTranslator.work(in: texts, locale: "de-DE", version: nil).map(\.address.field) == [.subtitle])

    try texts.write("Hello there", at: StoreAddress(field: .description))
    #expect(texts.translationState(of: german) == .outdated)
    #expect(StoreTranslator.work(in: texts, locale: "de-DE", version: nil).contains { $0.address == german })

    try texts.forgetTranslationSource(of: german)
    #expect(texts.translationState(of: german) == .manual)
    #expect(!StoreTranslator.work(in: texts, locale: "de-DE", version: nil).contains { $0.address == german })
  }

  // MARK: Limits

  @Test func limitsCountAsTheDestinationReceives() {
    let keywords = StoreDestination.appStore.slot(.keywords)?.limit
    // Commas count, a line break doesn't, and ü is two bytes.
    let count = keywords?.count("für\nswift", field: .keywords)
    #expect(count?.used == 10)
    #expect(count?.unit == "bytes")
    #expect(StoreDestination.appStore.slot(.name)?.limit?.count(String(repeating: "a", count: 31), field: .name).isOver == true)
    #expect(StoreDestination.appStore.slot(.name)?.limit?.count(String(repeating: "a", count: 30), field: .name).isOver == false)
    #expect(StoreDestination.googlePlay.slot(.subtitle)?.limit == .characters(80))
    #expect(StoreDestination.googlePlay.slot(.changelog)?.limit == .characters(500))
    #expect(StoreDestination.microsoftStore.slot(.description)?.limit == .characters(10_000))
    let topics = StoreDestination.github.slot(.keywords)?.limit?.count(
      StoreLists.text((0..<21).map { "t\($0)" }), field: .keywords)
    #expect(topics?.used == 21)
    #expect(topics?.isOver == true)
    let longTopic = StoreDestination.github.slot(.keywords)?.limit?.count(String(repeating: "a", count: 51), field: .keywords)
    #expect(longTopic?.isOver == true)
    #expect(longTopic?.longItem != nil)
  }

  @Test func aReportCoversEveryDestinationAndLocale() throws {
    let texts = StoreTexts(root: try project())
    var settings = StoreSettings()
    settings.locales = ["ja"]
    settings.destinations = [.appStore, .github]
    try texts.save(settings)
    try texts.write(String(repeating: "x", count: 40), at: StoreAddress(field: .subtitle))
    let rows = texts.report(version: nil, field: .subtitle)
    #expect(rows.map(\.destination) == [.appStore, .appStore, .github])
    #expect(rows[0].count?.isOver == true)
    #expect(rows[2].count?.isOver == false)
  }

  // MARK: Publish and import plans

  @Test func aPlanShowsOnlyWhatDiffersAndNeverClears() throws {
    let texts = StoreTexts(root: try project())
    var settings = StoreSettings()
    settings.locales = ["de-DE"]
    try texts.save(settings)
    try texts.write("Dev", at: StoreAddress(field: .name))
    try texts.write("New description", at: StoreAddress(field: .description))
    try texts.write("a\nb", at: StoreAddress(field: .keywords))
    var live = StoreLive()
    live.locales = ["en-US", "de"]
    live.texts = [
      .init(field: .name, locale: "en-US"): "Dev",
      .init(field: .description, locale: "en-US"): "Old description",
      .init(field: .keywords, locale: "en-US"): "a,b",
      .init(field: .subtitle, locale: "en-US"): "Live only",
    ]
    let plan = texts.publishPlan(destination: .appStore, live: live, version: nil)
    let base = plan.changes.filter { $0.locale == "en-US" }
    #expect(base.map(\.field) == [.description])
    #expect(base.first?.old == "Old description")
    #expect(base.first?.new == "New description")
    #expect(base.first?.liveLocale == "en-US")
    // A name isn't translated: every locale gets it, under the service's own code.
    let german = plan.changes.filter { $0.locale == "de-DE" }
    #expect(german.map(\.field) == [.name])
    #expect(german.first?.liveLocale == "de")
    // The German listing keeps what it has rather than getting English.
    #expect(plan.skipped.contains { $0.hasPrefix("Description · de-DE") })
    #expect(plan.overLimit.isEmpty)
  }

  @Test func aDocumentedLimitStopsAPublishAndAnEstimateDoesNot() throws {
    let texts = StoreTexts(root: try project())
    try texts.write(String(repeating: "x", count: 31), at: StoreAddress(field: .name))
    try texts.write(String(repeating: "y", count: 400), at: StoreAddress(field: .subtitle, destination: .github))
    #expect(texts.publishPlan(destination: .appStore, live: StoreLive(), version: nil).overLimit.count == 1)
    let github = texts.publishPlan(destination: .github, live: StoreLive(), version: nil)
    #expect(github.overLimit.isEmpty)
    #expect(github.changes.count == 1)
  }

  @Test func fieldsTheServiceWontTakeAreListedNotSent() throws {
    let texts = StoreTexts(root: try project())
    try texts.write("https://example.com/privacy", at: StoreAddress(field: .privacyURL))
    try texts.write("Notes", at: StoreAddress(field: .changelog, version: "1.0"))
    var live = StoreLive()
    live.readOnly[.changelog] = "No release yet"
    let plan = texts.publishPlan(destination: .googlePlay, live: live, version: "1.0")
    #expect(plan.changes.isEmpty)
    #expect(plan.manual.map(\.field) == [.privacyURL])
    #expect(plan.skipped == ["Release Notes: No release yet"])
  }

  @Test func importFillsWhatsEmptyAndOverridesWhatDiffers() throws {
    let root = try project()
    let texts = StoreTexts(root: root)
    try texts.write("Mine", at: StoreAddress(field: .description), ready: true)
    try texts.write("Same", at: StoreAddress(field: .subtitle), ready: true)
    var live = StoreLive()
    live.version = "1.2"
    live.locales = ["en-US", "fr-FR"]
    live.texts = [
      .init(field: .name, locale: "en-US"): "Dev",
      .init(field: .subtitle, locale: "en-US"): "Same",
      .init(field: .description, locale: "en-US"): "Theirs",
      .init(field: .keywords, locale: "en-US"): "a,b",
      .init(field: .description, locale: "fr-FR"): "Le leur",
      .init(field: .changelog, locale: "en-US"): "Fixed",
      .init(field: .reviewNotes, locale: nil): "Reviewer note",
    ]
    let items = texts.importPlan(destination: .appStore, live: live)
    #expect(!items.contains { $0.address.field == .subtitle })
    try texts.apply(items)

    #expect(file(root, "en-US/description.txt") == "Mine\n")
    #expect(file(root, "en-US/description.appstore.txt") == "Theirs\n")
    #expect(file(root, "en-US/name.txt") == "Dev\n")
    #expect(file(root, "en-US/keywords.txt") == "a\nb\n")
    #expect(file(root, "fr-FR/description.txt") == "Le leur\n")
    #expect(file(root, "en-US/versions/1.2/changelog.txt") == "Fixed\n")
    // What's live is public, but review notes stay private.
    #expect(file(root, "private/en-US/review-notes.txt") == "Reviewer note\n")
    #expect(StoreTexts(root: root).settings().locales == ["fr-FR"])

    // A second import has nothing left to say.
    #expect(StoreTexts(root: root).importPlan(destination: .appStore, live: live).isEmpty)
  }

  @Test func publishedTextJoinsTheRepository() throws {
    let root = try project()
    let texts = StoreTexts(root: root)
    try texts.write("Notes", at: StoreAddress(field: .changelog, version: "1.0"))
    try texts.write("Try it", at: StoreAddress(field: .testers, version: "1.0"))
    let changes = [
      StoreChange(field: .changelog, title: "", new: "Notes"), StoreChange(field: .testers, title: "", new: "Try it"),
    ]
    try texts.markPublished(changes, destination: .appStore, version: "1.0")
    #expect(file(root, "en-US/versions/1.0/changelog.txt") == "Notes\n")
    #expect(file(root, "private/en-US/versions/1.0/testers.txt") == "Try it\n")
  }

  @Test func localeCodesMatchAcrossServices() {
    #expect(StoreLocale.match("de-DE", in: ["de", "en-US"]) == "de")
    #expect(StoreLocale.match("en-us", in: ["en-GB", "en-US"]) == "en-US")
    #expect(StoreLocale.match("ja", in: ["en-US"]) == nil)
  }

  // MARK: Services, stubbed

  /// Answers by "METHOD path" and records everything sent.
  final class Stub: @unchecked Sendable {
    let lock = NSLock()
    var answers: [String: (Int, Any)]
    var sent: [(line: String, body: [String: Any])] = []

    init(_ answers: [String: (Int, Any)]) { self.answers = answers }

    var send: StoreHTTP.Send {
      { [self] request in
        let query = request.url?.query.map { "?" + ($0.removingPercentEncoding ?? $0) } ?? ""
        let path = (request.url?.path ?? "") + query
        let line = "\(request.httpMethod ?? "GET") \(path)"
        let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        return lock.withLock {
          sent.append((line, body))
          let answer = answers[line] ?? (404, ["message": "No stub for \(line)"])
          let data = (try? JSONSerialization.data(withJSONObject: answer.1)) ?? Data()
          return (data, answer.0)
        }
      }
    }

    func writes() -> [(line: String, body: [String: Any])] {
      lock.withLock { sent.filter { !$0.line.hasPrefix("GET") } }
    }
  }

  private func attributes(_ id: String, _ attributes: [String: Any]) -> [String: Any] {
    ["id": id, "attributes": attributes]
  }

  private func appStoreStub() -> Stub {
    Stub([
      "GET /v1/apps?filter[bundleId]=dev.v57.app": (200, ["data": [["id": "A1"]]]),
      "GET /v1/apps/A1/appInfos": (200, ["data": [attributes("I1", ["state": "PREPARE_FOR_SUBMISSION"])]]),
      "GET /v1/appInfos/I1/appInfoLocalizations?limit=50": (200, ["data": [
        attributes("IL1", ["locale": "en-US", "name": "Old Name", "subtitle": "Old Sub"]),
      ]]),
      "GET /v1/appInfos/I1/primaryCategory": (200, ["data": ["id": "UTILITIES"]]),
      "GET /v1/apps/A1/appStoreVersions?filter[platform]=IOS&limit=20": (200, ["data": [
        attributes("V2", ["versionString": "1.2", "appVersionState": "PREPARE_FOR_SUBMISSION", "copyright": "2025 Me"]),
        attributes("V1", ["versionString": "1.1", "appVersionState": "READY_FOR_DISTRIBUTION"]),
      ]]),
      "GET /v1/appStoreVersions/V2/appStoreVersionLocalizations?limit=50": (200, ["data": [
        attributes("VL1", ["locale": "en-US", "description": "Old description", "keywords": "a,b", "whatsNew": "Old notes"]),
      ]]),
      "GET /v1/appStoreVersions/V1/appStoreVersionLocalizations?limit=50": (200, ["data": [
        attributes("VL0", ["locale": "en-US", "promotionalText": "Promo"]),
      ]]),
      "GET /v1/appStoreVersions/V2/appStoreReviewDetail": (200, ["data": attributes("R1", ["notes": "Old notes for review"])]),
      "GET /v1/builds?filter[app]=A1&filter[preReleaseVersion.version]=1.2&sort=-uploadedDate&limit=1": (200, ["data": [["id": "B1"]]]),
      "GET /v1/builds/B1/betaBuildLocalizations?limit=50": (200, ["data": [attributes("BL1", ["locale": "en-US", "whatsNew": "Old test"])]]),
      "PATCH /v1/appInfoLocalizations/IL1": (200, ["data": []]),
      "POST /v1/appInfoLocalizations": (201, ["data": []]),
      "PATCH /v1/appStoreVersionLocalizations/VL1": (200, ["data": []]),
      "POST /v1/appStoreVersionLocalizations": (201, ["data": []]),
      "PATCH /v1/appInfos/I1": (200, ["data": []]),
      "PATCH /v1/appStoreVersions/V2": (200, ["data": []]),
      "PATCH /v1/appStoreReviewDetails/R1": (200, ["data": []]),
      "PATCH /v1/betaBuildLocalizations/BL1": (200, ["data": []]),
    ])
  }

  private func appStore(_ stub: Stub) -> AppStoreConnectText {
    AppStoreConnectText(
      api: AppStoreConnectAPI(keyID: "K", issuerID: "I", privateKey: P256.Signing.PrivateKey(), send: stub.send),
      bundleID: "dev.v57.app", platform: "ios")
  }

  @Test func appStoreConnectReadsEveryField() async throws {
    let live = try await appStore(appStoreStub()).fetch(version: "1.2")
    #expect(live.version == "1.2")
    #expect(live.texts[.init(field: .name, locale: "en-US")] == "Old Name")
    #expect(live.texts[.init(field: .description, locale: "en-US")] == "Old description")
    #expect(live.texts[.init(field: .changelog, locale: "en-US")] == "Old notes")
    #expect(live.texts[.init(field: .testers, locale: "en-US")] == "Old test")
    #expect(live.texts[.init(field: .category, locale: nil)] == "UTILITIES")
    #expect(live.texts[.init(field: .copyright, locale: nil)] == "2025 Me")
    #expect(live.texts[.init(field: .reviewNotes, locale: nil)] == "Old notes for review")
    #expect(live.readOnly.isEmpty)
  }

  @Test func aLiveVersionOnlyTakesItsPromotionalText() async throws {
    let stub = appStoreStub()
    stub.answers["GET /v1/builds?filter[app]=A1&filter[preReleaseVersion.version]=1.1&sort=-uploadedDate&limit=1"] = (200, ["data": []])
    let live = try await appStore(stub).fetch(version: "1.1")
    #expect(live.readOnly[.description] != nil)
    #expect(live.readOnly[.changelog] != nil)
    #expect(live.readOnly[.promotionalText] == nil)
    #expect(live.readOnly[.testers] != nil)
  }

  @Test func aVersionTheServiceDoesntHaveWritesNothingOfIts() async throws {
    let stub = appStoreStub()
    stub.answers["GET /v1/builds?filter[app]=A1&filter[preReleaseVersion.version]=9.9&sort=-uploadedDate&limit=1"] = (200, ["data": []])
    let live = try await appStore(stub).fetch(version: "9.9")
    #expect(live.readOnly[.changelog]?.contains("9.9") == true)
    #expect(live.readOnly[.testers] != nil)
  }

  @Test func appStoreConnectSendsOnlyTheChangesAndCreatesMissingLocales() async throws {
    let stub = appStoreStub()
    let changes = [
      StoreChange(field: .name, title: "", locale: "en-US", liveLocale: "en-US", new: "Dev"),
      StoreChange(field: .keywords, title: "", locale: "en-US", liveLocale: "en-US", new: "a\nb\nc"),
      StoreChange(field: .description, title: "", locale: "de-DE", liveLocale: "de-DE", new: "Beschreibung"),
      StoreChange(field: .category, title: "", new: "DEVELOPER_TOOLS"),
      StoreChange(field: .copyright, title: "", new: "2026 Me"),
      StoreChange(field: .reviewNotes, title: "", new: "Notes"),
      StoreChange(field: .testers, title: "", locale: "en-US", liveLocale: "en-US", new: "Try it"),
    ]
    try await appStore(stub).publish(changes, version: "1.2") { _ in }
    let writes = Dictionary(stub.writes().map { ($0.line, $0.body) }, uniquingKeysWith: { first, _ in first })
    #expect(writes.count == 7)
    let attribute = { (line: String, key: String) in
      ((writes[line]?["data"] as? [String: Any])?["attributes"] as? [String: Any])?[key] as? String
    }
    #expect(attribute("PATCH /v1/appInfoLocalizations/IL1", "name") == "Dev")
    #expect(attribute("PATCH /v1/appStoreVersionLocalizations/VL1", "keywords") == "a,b,c")
    #expect(attribute("POST /v1/appStoreVersionLocalizations", "locale") == "de-DE")
    #expect(attribute("POST /v1/appStoreVersionLocalizations", "description") == "Beschreibung")
    #expect(attribute("PATCH /v1/appStoreVersions/V2", "copyright") == "2026 Me")
    #expect(attribute("PATCH /v1/appStoreReviewDetails/R1", "notes") == "Notes")
    #expect(attribute("PATCH /v1/betaBuildLocalizations/BL1", "whatsNew") == "Try it")
    let category = ((writes["PATCH /v1/appInfos/I1"]?["data"] as? [String: Any])?["relationships"] as? [String: Any])?["primaryCategory"] as? [String: Any]
    #expect((category?["data"] as? [String: Any])?["id"] as? String == "DEVELOPER_TOOLS")
  }

  @Test func gitHubFindsADraftReleaseAndSendsTopicsWhole() async throws {
    let stub = Stub([
      "GET /repos/v57/Dev": (200, ["description": "Old", "homepage": "https://old"]),
      "GET /repos/v57/Dev/topics": (200, ["names": ["swift", "xcode"]]),
      "GET /repos/v57/Dev/releases?per_page=30": (200, [
        ["id": 7, "tag_name": "v1.2.0", "draft": true, "body": "Old notes"] as [String: Any],
      ]),
      "PATCH /repos/v57/Dev": (200, [:]),
      "PUT /repos/v57/Dev/topics": (200, [:]),
      "PATCH /repos/v57/Dev/releases/7": (200, [:]),
    ])
    let service = GitHubStoreText(repository: "v57/Dev", token: "t", send: stub.send)
    let live = try await service.fetch(version: "1.2.0")
    #expect(live.texts[.init(field: .changelog, locale: nil)] == "Old notes")
    #expect(live.texts[.init(field: .keywords, locale: nil)] == "swift\nxcode")
    #expect(live.summary.contains("draft"))

    try await service.publish([
      StoreChange(field: .subtitle, title: "", new: "New"),
      StoreChange(field: .keywords, title: "", new: "swift\nmacos"),
      StoreChange(field: .changelog, title: "", new: "Notes"),
    ], version: "1.2.0") { _ in }
    let writes = Dictionary(stub.writes().map { ($0.line, $0.body) }, uniquingKeysWith: { first, _ in first })
    #expect(writes["PATCH /repos/v57/Dev"]?["description"] as? String == "New")
    #expect(writes["PUT /repos/v57/Dev/topics"]?["names"] as? [String] == ["swift", "macos"])
    #expect(writes["PATCH /repos/v57/Dev/releases/7"]?["body"] as? String == "Notes")
  }

  @Test func gitHubTopicsCompareWithoutOrderOrCase() {
    #expect(StoreDestination.github.isSame("Swift\nDev Tools", "dev-tools\nswift", field: .keywords))
    #expect(!StoreDestination.appStore.isSame("a\nb", "b\na", field: .keywords))
  }

  @Test func aMissingReleaseIsReadOnlyOnGitHub() async throws {
    let stub = Stub([
      "GET /repos/v57/Dev": (200, ["description": "Old"]),
      "GET /repos/v57/Dev/topics": (200, ["names": []]),
      "GET /repos/v57/Dev/releases?per_page=30": (200, [Any]()),
    ])
    let live = try await GitHubStoreText(repository: "v57/Dev", token: "t", send: stub.send).fetch(version: "2.0")
    #expect(live.readOnly[.changelog]?.contains("v2.0") == true)
  }

  private func playKey() throws -> Data {
    try JSONSerialization.data(withJSONObject: ["client_email": "a@b", "private_key": "pem", "token_uri": "https://oauth2.googleapis.com/token"])
  }

  @Test func googlePlayMergesListingsCommitsOnceAndLeavesNoEditFromARead() async throws {
    let base = "/androidpublisher/v3/applications/dev.v57.app/edits"
    let stub = Stub([
      "POST /token": (200, ["access_token": "T"]),
      "POST \(base)": (200, ["id": "E"]),
      "DELETE \(base)/E": (200, [:]),
      "GET \(base)/E/listings": (200, ["listings": [["language": "en-US", "title": "Old", "fullDescription": "Long"]]]),
      "GET \(base)/E/details": (200, ["contactWebsite": "https://old", "defaultLanguage": "en-US"]),
      "GET \(base)/E/tracks/production": (200, ["track": "production", "releases": [
        ["name": "12 (1.2.0)", "releaseNotes": [["language": "en-US", "text": "Old notes"]]] as [String: Any],
      ]]),
      "GET \(base)/E/tracks/internal": (200, ["track": "internal", "releases": [[String: Any]]()]),
      "GET \(base)/E/listings/en-US": (200, ["language": "en-US", "title": "Old", "fullDescription": "Long"]),
      "PUT \(base)/E/listings/en-US": (200, [:]),
      "PUT \(base)/E/tracks/production": (200, [:]),
      "POST \(base)/E:commit?changesInReviewBehavior=ERROR_IF_IN_REVIEW": (200, [:]),
    ])
    var service = try GooglePlayStoreText(package: "dev.v57.app", serviceAccount: try playKey(), testTrack: "internal")
    service.send = stub.send
    service.sign = { _, _ in Data([1, 2, 3]) }

    let live = try await service.fetch(version: "1.2.0")
    #expect(live.texts[.init(field: .name, locale: "en-US")] == "Old")
    #expect(live.texts[.init(field: .changelog, locale: "en-US")] == "Old notes")
    #expect(live.readOnly[.testers] != nil)
    #expect(stub.sent.last?.line == "DELETE \(base)/E")

    stub.sent = []
    try await service.publish([
      StoreChange(field: .name, title: "", locale: "en-US", liveLocale: "en-US", new: "Dev"),
      StoreChange(field: .changelog, title: "", locale: "en-US", liveLocale: "en-US", new: "Notes"),
    ], version: "1.2.0") { _ in }
    let writes = Dictionary(stub.writes().map { ($0.line, $0.body) }, uniquingKeysWith: { first, _ in first })
    let listing = writes["PUT \(base)/E/listings/en-US"]
    #expect(listing?["title"] as? String == "Dev")
    // A listing is replaced whole, so the rest of it goes along.
    #expect(listing?["fullDescription"] as? String == "Long")
    let release = (writes["PUT \(base)/E/tracks/production"]?["releases"] as? [[String: Any]])?.first
    #expect((release?["releaseNotes"] as? [[String: String]])?.first?["text"] == "Notes")
    #expect(stub.sent.last?.line == "POST \(base)/E:commit?changesInReviewBehavior=ERROR_IF_IN_REVIEW")
  }

  @Test func googlePlayDropsItsEditWhenAPublishFails() async throws {
    let base = "/androidpublisher/v3/applications/dev.v57.app/edits"
    let stub = Stub([
      "POST /token": (200, ["access_token": "T"]),
      "POST \(base)": (200, ["id": "E"]),
      "DELETE \(base)/E": (200, [:]),
      "PUT \(base)/E/listings/en-US": (500, ["error": ["message": "Nope"]]),
    ])
    var service = try GooglePlayStoreText(package: "dev.v57.app", serviceAccount: try playKey(), testTrack: "internal")
    service.send = stub.send
    service.sign = { _, _ in Data([1]) }
    await #expect(throws: StoreTextError.self) {
      try await service.publish(
        [StoreChange(field: .name, title: "", locale: "en-US", liveLocale: "en-US", new: "Dev")], version: nil) { _ in }
    }
    #expect(stub.sent.last?.line == "DELETE \(base)/E")
    #expect(!stub.sent.contains { $0.line.contains(":commit") })
  }

  @Test func theMicrosoftStoreSavesOnASubmissionAndNeverCommits() async throws {
    let base = "/v1.0/my/applications/9N"
    let submission: [String: Any] = [
      "id": "S1", "notesForCertification": "Old",
      "listings": ["en-us": ["baseListing": [
        "title": "Old", "description": "Long", "keywords": ["a"], "images": [["fileName": "x.png"]],
      ] as [String: Any]]],
    ]
    let stub = Stub([
      "POST /tenant/oauth2/token": (200, ["access_token": "T"]),
      "GET \(base)": (200, ["lastPublishedApplicationSubmission": ["id": "S0"]]),
      "GET \(base)/submissions/S0": (200, submission),
      "POST \(base)/submissions": (200, submission),
      "PUT \(base)/submissions/S1": (200, submission),
    ])
    let service = MicrosoftStoreText(appID: "9N", tenant: "tenant", client: "c", secret: "s", send: stub.send)
    let live = try await service.fetch(version: nil)
    #expect(live.locales == ["en-us"])
    #expect(live.texts[.init(field: .keywords, locale: "en-us")] == "a")
    #expect(live.texts[.init(field: .reviewNotes, locale: nil)] == "Old")

    try await service.publish([
      StoreChange(field: .description, title: "", locale: "en-US", liveLocale: "en-us", new: "New"),
      StoreChange(field: .keywords, title: "", locale: "en-US", liveLocale: "en-us", new: "a\nb"),
      StoreChange(field: .reviewNotes, title: "", new: "Notes"),
    ], version: nil) { _ in }
    let put = stub.writes().first { $0.line == "PUT \(base)/submissions/S1" }?.body
    #expect(put?["notesForCertification"] as? String == "Notes")
    let listing = ((put?["listings"] as? [String: Any])?["en-us"] as? [String: Any])?["baseListing"] as? [String: Any]
    #expect(listing?["description"] as? String == "New")
    #expect(listing?["keywords"] as? [String] == ["a", "b"])
    // What Dev doesn't edit goes back untouched.
    #expect(listing?["images"] != nil)
    #expect(!stub.sent.contains { $0.line.contains("/commit") })
  }

  // MARK: Credentials

  @Test func noCredentialsMeansAClearMessageAndNoRequest() {
    #expect(StoreCredentials.missing(.appStore, config: nil, accountID: "none")?.contains("release.env") == true)
    #expect(StoreCredentials.missing(.appStore, config: ReleaseConfig(), accountID: "none")?.contains("API key") == true)
    #expect(StoreCredentials.missing(.github, config: ReleaseConfig(), accountID: "none")?.contains("GITHUB_REPO") == true)
    #expect(StoreCredentials.missing(.googlePlay, config: ReleaseConfig(), accountID: "none")?.contains("service account") == true)
    #expect(StoreCredentials.missing(.microsoftStore, config: ReleaseConfig(), accountID: "none")?.contains("Store ID") == true)
  }

  @Test func storeJSONReadsWithMissingKeysAndNeverHoldsCredentialKeys() throws {
    let settings = try JSONDecoder().decode(StoreSettings.self, from: Data("{}".utf8))
    #expect(settings.baseLocale == "en-US")
    #expect(settings.used == StoreDestination.allCases)
    let root = try project()
    try StoreTexts(root: root).save(settings)
    let saved = file(root, "store.json") ?? ""
    #expect(!saved.lowercased().contains("key"))
    #expect(!saved.lowercased().contains("secret"))
  }
}
