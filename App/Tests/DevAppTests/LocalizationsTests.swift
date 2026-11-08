import Foundation
import Testing

@testable import DevApp

/// The translations repository's pure half: the merge into a source's catalog, the sources the scanned apps make, the
/// keys a build's derived data holds, and a catalog's progress.
@Suite struct LocalizationsTests {
  // MARK: merge

  @Test func mergeAddsKeysKeepsTranslationsAndStalesRemovedOnes() throws {
    let existing = try JSONDecoder().decode(
      StringCatalog.self,
      from: Data(
        """
        {"sourceLanguage":"en","version":"1.0","strings":{
          "Keep":{"comment":"Old","localizations":{"de":{"stringUnit":{"state":"translated","value":"Behalten"}}}},
          "Gone":{"localizations":{"de":{"stringUnit":{"state":"needs_review","value":"Weg"}}}},
          "Back":{"extractionState":"stale"},
          "Mine":{"extractionState":"manual"}
        }}
        """.utf8))
    let (catalog, counts) = SourceCatalogMerge.merge(
      existing, keys: ["Keep": ["Saves it"], "Back": [], "New %@": ["Shown when"], "%lld": []])
    #expect(counts.added == 2)
    #expect(counts.revived == 1)
    #expect(counts.staled == 1)
    #expect(counts.commented == 1)
    #expect(catalog.strings["Keep"]?.comment == "Saves it")
    #expect(catalog.strings["Keep"]?.localizations?["de"]?.stringUnit?.value == "Behalten")
    #expect(catalog.strings["Gone"]?.extractionState == "stale")
    #expect(catalog.strings["Gone"]?.localizations?["de"]?.stringUnit?.value == "Weg")
    #expect(catalog.strings["Back"]?.extractionState == nil)
    #expect(catalog.strings["Mine"]?.extractionState == "manual")
    #expect(catalog.strings["New %@"]?.comment == "Shown when")
    #expect(catalog.strings["New %@"]?.shouldTranslate == nil)
    #expect(catalog.strings["%lld"]?.shouldTranslate == false)

    let (_, again) = SourceCatalogMerge.merge(
      catalog, keys: ["Keep": ["Saves it"], "Back": [], "New %@": ["Shown when"], "%lld": []])
    #expect(!again.changed)
  }

  @Test func formatSpecifiersAreNotWords() {
    #expect(!SourceCatalogMerge.hasLetters("%lld"))
    #expect(!SourceCatalogMerge.hasLetters("+%lld"))
    #expect(!SourceCatalogMerge.hasLetters("%1$@ – %2$@"))
    #expect(!SourceCatalogMerge.hasLetters("%lld%%"))
    #expect(SourceCatalogMerge.hasLetters("%lld files"))
    #expect(SourceCatalogMerge.hasLetters("Öffnen"))
  }

  // MARK: plan

  @Test func kitsAreSharedAndAKeyIsInOnePlace() {
    let apps = [
      LocalizationsApp(name: "Markdown", folder: "/v57/Markdown", container: "", scheme: "Markdown"),
      LocalizationsApp(name: "Shell", folder: "/v57/Shell", container: "", scheme: "Shell"),
      LocalizationsApp(name: "Code", folder: "/v57/Code", container: "", scheme: "Code"),
      LocalizationsApp(name: "Off", folder: "/v57/Off", container: "", scheme: "Off", included: false),
    ]
    let kit = ModuleStrings(module: "ComponentKit", repo: "/v57/Component", keys: ["Close": [], "Done": ["Button"]])
    let actions = ModuleStrings(module: "CodeActionsUI", repo: "/v57/Code", keys: ["Notarize": []])
    let scans = [
      "Markdown": AppScan(
        app: "Markdown", date: .now,
        modules: [ModuleStrings(module: "MarkdownApp", repo: "/v57/Markdown", keys: ["Close": [], "Export": []]), kit]),
      "Shell": AppScan(
        app: "Shell", date: .now,
        modules: [ModuleStrings(module: "Shell", repo: "/v57/Shell", keys: ["Run": []]), kit, actions]),
      "Code": AppScan(
        app: "Code", date: .now,
        modules: [ModuleStrings(module: "CodeApp", repo: "/v57/Code", keys: ["Build": [], "Notarize": []]), actions, kit]),
      "Off": AppScan(app: "Off", date: .now, modules: [ModuleStrings(module: "Off", repo: "/v57/Off", keys: ["X": []])]),
    ]
    let plan = LocalizationsPlan(apps: apps, scans: scans)
    let byName = Dictionary(uniqueKeysWithValues: plan.sources.map { ($0.name, $0) })
    #expect(Set(byName.keys) == ["Markdown", "Shell", "Code", "ComponentKit", "CodeActionsUI"])
    // The kit's "Close" is not Markdown's too.
    #expect(Set(byName["Markdown"]?.keys.keys.map { $0 } ?? []) == ["Export"])
    #expect(byName["ComponentKit"]?.usedBy == ["Code", "Markdown", "Shell"])
    #expect(byName["ComponentKit"]?.keys["Done"] == ["Button"])
    // Shell links Code's CodeActionsUI, so it is a kit for Code too: Code's own source leaves its key out.
    #expect(byName["CodeActionsUI"]?.usedBy == ["Code", "Shell"])
    #expect(Set(byName["Code"]?.keys.keys.map { $0 } ?? []) == ["Build"])
    #expect(plan.lookup["Shell"] == ["Shell", "CodeActionsUI", "ComponentKit"])
    #expect(plan.lookup["Off"] == nil)
    // Apps first, then kits.
    #expect(plan.sources.prefix(3).allSatisfy { $0.kind == .app })
  }

  @Test func checkoutsElsewhereBelongToTheirApp() {
    let apps = [
      LocalizationsApp(name: "Hub", folder: "/hub/Apps/hub-app", container: "", scheme: "Hub", added: true),
      LocalizationsApp(name: "Markdown", folder: "/v57/Markdown", container: "", scheme: "Markdown"),
    ]
    let kit = ModuleStrings(module: "ComponentKit", repo: "/v57/Component", keys: ["Close": []])
    let scans = [
      "Hub": AppScan(
        app: "Hub", date: .now,
        modules: [
          ModuleStrings(module: "Hub", repo: "/hub/Apps/hub-app", keys: ["Devices": []]),
          ModuleStrings(module: "ChannelSwift", repo: "/hub/Channel", keys: ["Connected": [], "Close": []]), kit,
        ]),
      "Markdown": AppScan(
        app: "Markdown", date: .now,
        modules: [ModuleStrings(module: "MarkdownApp", repo: "/v57/Markdown", keys: ["Export": []]), kit]),
    ]
    let plan = LocalizationsPlan(apps: apps, scans: scans, kitsFolder: "/v57")
    let byName = Dictionary(uniqueKeysWithValues: plan.sources.map { ($0.name, $0) })
    #expect(Set(byName.keys) == ["Hub", "Markdown", "ComponentKit"])
    // Hub's own packages are Hub's source; v57's kit stays a kit.
    #expect(Set(byName["Hub"]?.keys.keys.map { $0 } ?? []) == ["Devices", "Connected"])
    #expect(byName["ComponentKit"]?.usedBy == ["Hub", "Markdown"])
    #expect(plan.lookup["Hub"] == ["Hub", "ComponentKit"])
  }

  @Test func theModelIsToldWhatASourceIs() {
    let apps = [
      LocalizationsApp(name: "Code", folder: "/v57/Code", container: "", scheme: "Code"),
      LocalizationsApp(name: "Git", folder: "/v57/Git", container: "", scheme: "Git"),
    ]
    let kit = ModuleStrings(module: "ComponentKit", repo: "/v57/Component", keys: ["Close": []])
    let scans = [
      "Code": AppScan(
        app: "Code", date: .now, modules: [ModuleStrings(module: "CodeApp", repo: "/v57/Code", keys: ["Run": []]), kit]),
      "Git": AppScan(
        app: "Git", date: .now, modules: [ModuleStrings(module: "GitApp", repo: "/v57/Git", keys: ["Push": []]), kit]),
    ]
    let plan = LocalizationsPlan(apps: apps, scans: scans, kitsFolder: "/v57")
    let descriptions = ["Code": "a code editor", "ComponentKit": "the shared controls"]
    #expect(LocalizationsAbout.lines(for: "Code", in: plan, descriptions: descriptions)
      == ["About: You are translating Code, a code editor."])
    #expect(LocalizationsAbout.lines(for: "Git", in: plan, descriptions: descriptions).isEmpty)
    #expect(LocalizationsAbout.lines(for: "ComponentKit", in: plan, descriptions: descriptions) == [
      "About: You are translating ComponentKit, the shared controls. Its strings appear inside these apps, so keep them fitting for all of them:",
      "About: - Code: a code editor",
      "About: - Git",
    ])
  }

  @Test func anAppIsFoundByItsLocalWorkspace() throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("LocalizationsTests-\(UUID().uuidString)/hub-app", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
    try FileManager.default.createDirectory(
      at: folder.appendingPathComponent("Hub-Local.xcworkspace"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: folder.appendingPathComponent("Hub.xcodeproj"), withIntermediateDirectories: true)
    try """
      \t\tAA /* Hub Pro */ = {
      \t\t\tisa = PBXNativeTarget;
      \t\t\tname = "Hub Pro";
      \t\t\tproductType = "com.apple.product-type.application";
      \t\t};
      \t\tBB /* Hub */ = {
      \t\t\tisa = PBXNativeTarget;
      \t\t\tname = Hub;
      \t\t\tproductType = "com.apple.product-type.application";
      \t\t};
      """.write(to: folder.appendingPathComponent("Hub.xcodeproj/project.pbxproj"), atomically: true, encoding: .utf8)
    let app = try #require(LocalizationsApps.app(at: folder))
    #expect(app.name == "Hub")
    #expect(app.container == "Hub-Local.xcworkspace")
    #expect(app.scheme == "Hub")
    // Discovery next to the repository wants the folder's own name.
    #expect(LocalizationsApps.app(at: folder, requireFolderName: true) == nil)
  }

  @Test func applicationTargetsComeFromTheProject() {
    let pbxproj = """
      \t\tAA /* Remote */ = {
      \t\t\tisa = PBXNativeTarget;
      \t\t\tname = Remote;
      \t\t\tproductType = "com.apple.product-type.application";
      \t\t};
      \t\tBB /* Ext */ = {
      \t\t\tisa = PBXNativeTarget;
      \t\t\tname = RemoteExtension;
      \t\t\tproductType = "com.apple.product-type.app-extension";
      \t\t};
      \t\tCC /* iOS */ = {
      \t\t\tisa = PBXNativeTarget;
      \t\t\tname = "Remote iOS";
      \t\t\tproductType = "com.apple.product-type.application";
      \t\t};
      """
    #expect(LocalizationsApps.applicationTargets(pbxproj: pbxproj) == ["Remote", "Remote iOS"])
  }

  // MARK: the build's keys

  @Test func scanReadsTheModulesTheAppLinks() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("LocalizationsTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = FileManager.default
    func repo(_ name: String) throws -> URL {
      let url = root.appendingPathComponent("v57/\(name)")
      try manager.createDirectory(at: url.appendingPathComponent(".git"), withIntermediateDirectories: true)
      return url
    }
    func source(_ repo: URL, _ path: String) throws -> URL {
      let url = repo.appendingPathComponent(path)
      try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data("// swift".utf8).write(to: url)
      return url
    }
    let app = try repo("Notes")
    let kit = try repo("Component")
    let other = try repo("Other")
    let appFile = try source(app, "App/Main.swift")
    let kitFile = try source(kit, "Sources/ComponentKit/Button.swift")
    let otherFile = try source(other, "Sources/OtherKit/Thing.swift")
    let derived = root.appendingPathComponent("Derived")
    let intermediates = derived.appendingPathComponent("Build/Intermediates.noindex")
    func target(_ project: String, _ folder: String, _ files: [(String, URL, [(String, String)])]) throws -> URL {
      let arch = intermediates.appendingPathComponent("\(project).build/Debug/\(folder)/Objects-normal/arm64")
      try manager.createDirectory(at: arch, withIntermediateDirectories: true)
      for (name, source, keys) in files {
        let entries = keys.map { ["key": $0.0, "comment": $0.1] }
        let json: [String: Any] = ["version": 1, "source": source.path, "tables": ["Localizable": entries]]
        try JSONSerialization.data(withJSONObject: json).write(to: arch.appendingPathComponent("\(name).stringsdata"))
      }
      return arch
    }
    let appArch = try target("Notes", "Notes.build", [("Main", appFile, [("Hello", ""), ("%lld notes", "Count")])])
    try "\(appArch.path)/Main.o\n\(derived.path)/Build/Products/Debug/ComponentKit.o\n"
      .write(to: appArch.appendingPathComponent("Notes.LinkFileList"), atomically: true, encoding: .utf8)
    _ = try target("Component", "ComponentKit-t.build", [("Button", kitFile, [("Close", ""), ("Hello", "")])])
    // Built into the same folder by something else, not linked: left out.
    _ = try target("Other", "OtherKit-t.build", [("Thing", otherFile, [("Other", "")])])

    let scan = StringsDataScan.read(
      derivedData: derived,
      app: LocalizationsApp(name: "Notes", folder: app.path, container: "", scheme: "Notes"))
    #expect(scan.modules.map(\.module) == ["ComponentKit", "Notes"])
    #expect(scan.modules.first { $0.module == "Notes" }?.keys["%lld notes"] == ["Count"])
    #expect(scan.modules.first { $0.module == "ComponentKit" }?.repo == kit.standardizedFileURL.path)

    // A source edited after the compiler last wrote its keys says nothing current.
    try manager.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: kitFile.path)
    let later = StringsDataScan.read(
      derivedData: derived,
      app: LocalizationsApp(name: "Notes", folder: app.path, container: "", scheme: "Notes"))
    #expect(later.modules.map(\.module) == ["Notes"])
  }

  // MARK: progress

  @Test func progressCountsWhatIsTranslatable() throws {
    let catalog = try JSONDecoder().decode(
      StringCatalog.self,
      from: Data(
        """
        {"sourceLanguage":"en","strings":{
          "A":{"localizations":{"de":{"stringUnit":{"state":"translated","value":"A"}},
                                "fr":{"stringUnit":{"state":"needs_review","value":"A"}}}},
          "%lld B":{"localizations":{"de":{"variations":{"plural":{"one":{"stringUnit":{"state":"needs_review","value":"%lld B"}},
                                                                  "other":{"stringUnit":{"state":"needs_review","value":"%lld Bs"}}}}}}},
          "C":{},
          "%lld":{"shouldTranslate":false},
          "Old":{"extractionState":"stale","localizations":{"de":{"stringUnit":{"state":"translated","value":"Alt"}}}}
        }}
        """.utf8))
    let progress = SourceProgress(catalog)
    #expect(progress.keys == 3)
    #expect(progress.stale == 1)
    #expect(progress.translated == ["de": 2, "fr": 1])
    #expect(progress.needsReview == ["de": 1, "fr": 1])
    #expect(abs(progress.fraction("de") - 2.0 / 3.0) < 0.001)
  }
}
