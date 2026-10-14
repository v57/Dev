import DevScreenshots
import Foundation
import Testing

@testable import DevScreenshotsCapture

struct ScreenshotConfigTests {
  @Test func missingKeysTakeTheirDefaults() throws {
    let json = #"{ "scenes": [{ "id": "01-main" }] }"#
    let config = try JSONDecoder().decode(ScreenshotConfig.self, from: Data(json.utf8))
    #expect(config.output == ".build/screenshots")
    #expect(config.locales == ["en-US"])
    #expect(config.appearances == [.light])
    #expect(config.mac == ScreenshotConfig.Mac(window: [1440, 900]))
    #expect(config.ios == nil)
    #expect(config.scenes == [ScreenshotConfig.Scene(id: "01-main", delay: 2)])
    #expect(config.problems().isEmpty)
  }

  @Test func anIOSOnlyConfigCapturesNoMac() throws {
    let json = #"{ "ios": { "devices": ["iPhone 17 Pro Max"] }, "scenes": [{ "id": "a" }] }"#
    let config = try JSONDecoder().decode(ScreenshotConfig.self, from: Data(json.utf8))
    #expect(config.mac == nil)
    #expect(config.ios?.cleanStatusBar == true)
  }

  @Test func aNullWindowKeepsTheAppsSize() throws {
    let json = #"{ "mac": { "window": null }, "scenes": [{ "id": "a" }] }"#
    let config = try JSONDecoder().decode(ScreenshotConfig.self, from: Data(json.utf8))
    #expect(config.mac?.window == nil)
  }

  @Test func problemsAreReported() {
    var config = ScreenshotConfig(scenes: [.init(id: "a"), .init(id: "a"), .init(id: "b/c"), .init(id: "d e")])
    config.mac?.window = [1440]
    config.ios = .init(devices: [])
    #expect(config.problems().count == 5)
  }

  @Test func aSceneWritesOnlyWhatDiffersFromTheDefaults() throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let plain = String(decoding: try encoder.encode(ScreenshotConfig.Scene(id: "a")), as: UTF8.self)
    #expect(plain == #"{"id":"a"}"#)
    let scene = ScreenshotConfig.Scene(id: "a", delay: 3, relaunch: true)
    #expect(try JSONDecoder().decode(ScreenshotConfig.Scene.self, from: encoder.encode(scene)) == scene)
  }

  @Test func relaunchDoesNotOutdateThePicture() {
    var config = ScreenshotConfig(scenes: [.init(id: "a")])
    let before = config.fingerprint(of: config.scenes[0], on: .mac)
    config.scenes[0].relaunch = true
    #expect(config.fingerprint(of: config.scenes[0], on: .mac) == before)
  }

  @Test func aSceneReadsItsArguments() {
    let scene = ScreenshotConfig.Scene(
      id: "a", arguments: ["--add-folder", "/a", "--mode", "history", "--add-folder", "/b", "--light", "--tool"])
    #expect(scene.value("--mode") == "history")
    #expect(scene.values("--add-folder") == ["/a", "/b"])
    #expect(scene.flag("--light"))
    #expect(scene.value("--tool") == nil)
    #expect(scene.value("--missing") == nil)
  }

  @Test func theNextSceneIsOneLine() throws {
    let message = ScreenshotSignal.NextScene(
      scene: .init(id: "02", arguments: ["-DevTool", "icon"], environment: ["A": "b\nc"]), appearance: .dark)
    let line = message.line
    #expect(line.hasSuffix("\n") && line.dropLast().contains("\n") == false)
    let read = try JSONDecoder().decode(ScreenshotSignal.NextScene.self, from: Data(line.utf8))
    #expect(read.scene == message.scene && read.appearance == .dark)
  }

  @Test func savedConfigReadsBack() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let config = ScreenshotConfig(
      locales: ["en-US", "de-DE"], variables: ["DEMO": "$ROOT/demo"], build: .init(scheme: "Git"),
      scenes: [.init(id: "01", arguments: ["--add-folder", "$DEMO/Repo"], platforms: [.mac], caption: "Hi")])
    try config.save(in: root)
    #expect(try ScreenshotConfig.load(in: root) == config)
  }

  @Test func variablesExpandInAnyOrder() {
    let config = ScreenshotConfig(
      variables: ["REPO": "${DEMO}/Repo", "DEMO": "$ROOT/Tools/screenshots"],
      scenes: [.init(id: "a", arguments: ["--add-folder", "$REPO", "$5", "$UNKNOWN", "cost: $"], environment: ["X": "$DEMO"])])
    let scene = config.expanded(config.scenes[0], root: URL(fileURLWithPath: "/p"))
    #expect(scene.arguments == ["--add-folder", "/p/Tools/screenshots/Repo", "$5", "$UNKNOWN", "cost: $"])
    #expect(scene.environment == ["X": "/p/Tools/screenshots"])
  }

  @Test func aVariableCycleIsLeftAsWritten() {
    let config = ScreenshotConfig(variables: ["A": "$B", "B": "$A"])
    let variables = config.resolvedVariables(root: URL(fileURLWithPath: "/p"))
    #expect(variables["ROOT"] == "/p")
    #expect(variables["A"] != nil && variables["B"] != nil)
  }

  @Test func fingerprintFollowsWhatThePictureShows() {
    var config = ScreenshotConfig(
      ios: .init(devices: ["iPhone 17 Pro Max"]), scenes: [.init(id: "a", arguments: ["--mode", "history"])])
    let mac = config.fingerprint(of: config.scenes[0], on: .mac)
    let phone = config.fingerprint(of: config.scenes[0], on: .iphone)
    #expect(mac == config.fingerprint(of: config.scenes[0], on: .mac))

    // Where it is captured doesn't change the picture.
    config.ios?.devices = ["iPhone 16"]
    config.mac?.app = "build/Git.app"
    config.locales = ["fr-FR"]
    #expect(config.fingerprint(of: config.scenes[0], on: .mac) == mac)
    #expect(config.fingerprint(of: config.scenes[0], on: .iphone) == phone)

    // The Mac's window size changes only the Mac's pictures.
    config.mac?.window = [1280, 800]
    #expect(config.fingerprint(of: config.scenes[0], on: .mac) != mac)
    #expect(config.fingerprint(of: config.scenes[0], on: .iphone) == phone)

    config.scenes[0].arguments = ["--mode", "changes"]
    #expect(config.fingerprint(of: config.scenes[0], on: .iphone) != phone)
  }
}

struct ScreenshotManifestTests {
  static func shot(_ scene: String, locale: String = "en-US", build: Int, commit: String, fingerprint: String = "f")
    -> ScreenshotManifest.Shot
  {
    ScreenshotManifest.Shot(
      scene: scene, platform: .mac, device: nil, locale: locale, appearance: .light,
      file: ScreenshotCapture.file(scene: scene, target: "mac", locale: locale, appearance: .light),
      width: 2880, height: 1800,
      taken: .init(build: build, commit: commit, dirty: false, date: Date(), fingerprint: fingerprint))
  }

  @Test func aNewCaptureReplacesOnlyItsPictures() {
    let old = ScreenshotManifest(shots: [Self.shot("a", build: 1, commit: "x"), Self.shot("b", build: 1, commit: "x")])
    let new = ScreenshotManifest(shots: [Self.shot("a", build: 2, commit: "y")])
    let merged = old.merging(new)
    #expect(merged.shots.count == 2)
    #expect(merged.shots.first { $0.scene == "a" }?.taken.build == 2)
    #expect(merged.shots.first { $0.scene == "b" }?.taken.build == 1)
  }

  @Test func aFailedRetryKeepsTheOlderPicture() {
    let old = ScreenshotManifest(shots: [Self.shot("a", build: 1, commit: "x")])
    let failure = ScreenshotManifest.Failure(
      scene: "a", platform: .mac, device: nil, locale: "en-US", appearance: .light, reason: "no window")
    let merged = old.merging(ScreenshotManifest(failures: [failure]))
    #expect(merged.shots.count == 1)
    #expect(merged.failures == [failure])
    // And a later success clears the failure.
    #expect(merged.merging(ScreenshotManifest(shots: [Self.shot("a", build: 2, commit: "y")])).failures.isEmpty)
  }

  @Test func savedManifestReadsBack() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    var manifest = ScreenshotManifest(shots: [Self.shot("a", build: 3, commit: "abc")])
    manifest.shots[0].taken.date = Date(timeIntervalSince1970: 1_800_000_000)
    try manifest.save(in: folder)
    #expect(ScreenshotManifest.load(in: folder) == manifest)
  }

  @Test func filesAndSlugs() {
    #expect(ScreenshotCapture.file(scene: "01", target: "mac", locale: "de-DE", appearance: .dark) == "mac/de-DE/01-dark.png")
    #expect(ScreenshotCapture.slug("iPad Pro 13-inch (M5)") == "ipad-pro-13-inch-m5")
  }

  @Test func signalLinesAreFoundInTheAppsOutput() {
    #expect(ScreenshotSignal.message(in: "2026-10-14 12:00 Git[123] dev-screenshot: ready window=42\n") == "ready window=42")
    #expect(ScreenshotSignal.message(in: "some other line") == nil)
  }
}

/// Status against a real git history in a temporary folder.
struct ScreenshotStatusTests {
  let root: URL

  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("status-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("App"), withIntermediateDirectories: true)
    git("init", "-q")
    commit("App/a.swift")
  }

  func git(_ arguments: String...) {
    Shell.run("git", ["-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"] + arguments, in: root)
  }

  func commit(_ path: String) {
    let file = root.appendingPathComponent(path)
    try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? UUID().uuidString.write(to: file, atomically: true, encoding: .utf8)
    git("add", "-A")
    git("commit", "-q", "-m", path)
  }

  func capture(_ config: ScreenshotConfig, scenes: [String]? = nil) -> ScreenshotManifest {
    let version = ProjectVersion.current(in: root, watch: config.watch)
    return ScreenshotManifest(
      shots: config.scenes.filter { scenes?.contains($0.id) ?? true }.map { scene in
        var shot = ScreenshotManifestTests.shot(scene.id, build: version.build ?? 0, commit: version.commit ?? "")
        shot.taken.fingerprint = config.fingerprint(of: scene, on: .mac)
        return shot
      })
  }

  @Test func newCommitsOutdateThePictures() {
    let config = ScreenshotConfig(scenes: [.init(id: "a"), .init(id: "b")])
    let manifest = capture(config, scenes: ["a"])
    var status = ScreenshotStatus.check(config: config, manifest: manifest, root: root)
    #expect(status.version.build == 1)
    #expect(status.scenes.map(\.state) == [.current, .missing])
    #expect(status.scenes[0].taken?.build == 1)

    commit("App/b.swift")
    commit("README.md")
    status = ScreenshotStatus.check(config: config, manifest: manifest, root: root)
    #expect(status.scenes[0].state == .outdated(commits: 2))
    #expect(!status.isCurrent)
  }

  @Test func onlyWatchedPathsCount() {
    let config = ScreenshotConfig(watch: ["App"], scenes: [.init(id: "a")])
    let manifest = capture(config)
    commit("README.md")
    #expect(ScreenshotStatus.check(config: config, manifest: manifest, root: root).scenes[0].state == .current)
    commit("App/c.swift")
    #expect(ScreenshotStatus.check(config: config, manifest: manifest, root: root).scenes[0].state == .outdated(commits: 1))
  }

  @Test func editingASceneOutdatesItAlone() {
    var config = ScreenshotConfig(scenes: [.init(id: "a"), .init(id: "b")])
    let manifest = capture(config)
    config.scenes[1].arguments = ["--dark-sidebar"]
    let status = ScreenshotStatus.check(config: config, manifest: manifest, root: root)
    #expect(status.scenes.map(\.state) == [.current, .changed])
  }

  @Test func aNewLocaleLeavesScenesIncomplete() {
    var config = ScreenshotConfig(scenes: [.init(id: "a")])
    let manifest = capture(config)
    config.locales.append("de-DE")
    #expect(ScreenshotStatus.check(config: config, manifest: manifest, root: root).scenes[0].state == .incomplete(missing: 1))
  }
}
