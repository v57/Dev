import Foundation

/// The app's side of a screenshot capture. `dev-screenshots` launches the app with the first scene's launch arguments
/// and `DEV_SCREENSHOT=<scene id>`; the app opens that screen from its own arguments, as it already does for scripted
/// checks. Calling `prepare()` at launch adds what the arguments can't: the appearance, the window size, bringing the
/// window to the front with focus (and waiting while the reader is in another app) and saying when the screen is
/// ready, so nothing is captured half-loaded or unfocused.
///
/// With a scene handler, the whole capture runs in this one launch (per locale): after each picture the next scene
/// arrives on stdin, the handler opens it, and the kit says when it's ready. Without one, the app is relaunched for
/// every scene.
///
/// ```swift
/// init() {
///   Screenshots.prepare { scene in               // optional: the other scenes, in this launch
///     model.open(tool: scene.value("--tool"))
///   }
/// }
/// ```
///
/// Without a scene in the environment, nothing happens, so the call can stay in release builds.
@MainActor
public enum Screenshots {
  public typealias Scene = ScreenshotConfig.Scene

  /// The first scene being captured, nil in a normal launch.
  public nonisolated static var scene: String? { ScreenshotSignal.environment(ScreenshotSignal.sceneKey) }

  public nonisolated static var isCapturing: Bool { scene != nil }

  /// Applies the capture's appearance and window size and, unless `waitsForReady`, says the screen is ready once the
  /// window is up and the scene's delay has passed. Call once, at launch.
  ///
  /// - Parameters:
  ///   - waitsForReady: the app loads its first scene asynchronously (connects, opens a file) and calls `ready()`
  ///     when it is done.
  ///   - scenes: opens a later scene in this launch, from its arguments; the picture is taken once it returns and
  ///     the scene's delay has passed. Undo what the earlier scene changed that the arguments don't mention.
  public static func prepare(waitsForReady: Bool = false, scenes: (@MainActor (Scene) async -> Void)? = nil) {
    guard isCapturing, !prepared else { return }
    prepared = true
    waitsForApp = waitsForReady
    handler = scenes
    ScreenshotSignal.send("hello pid=\(ProcessInfo.processInfo.processIdentifier)" + (scenes == nil ? "" : " scenes"))
    Platform.apply(ScreenshotSignal.appearance)
    if ScreenshotSignal.activates { Platform.reportFocus() }
    Task {
      await Platform.waitForWindow()
      windowUp = true
      if !waitsForApp || appReady { await presentFirst() }
      if scenes != nil { await followScenes() }
    }
  }

  /// The first scene's screen is set up; with `prepare(waitsForReady: true)` its picture is taken after this.
  public static func ready() {
    guard isCapturing, !appReady else { return }
    appReady = true
    if prepared, waitsForApp, windowUp { Task { await presentFirst() } }
  }

  private static var prepared = false
  private static var waitsForApp = false
  private static var appReady = false
  private static var windowUp = false
  private static var presentedFirst = false
  private static var handler: (@MainActor (Scene) async -> Void)?

  private static func presentFirst() async {
    guard !presentedFirst else { return }
    presentedFirst = true
    await present(delay: ScreenshotSignal.delay, scene: nil)
  }

  private static func present(delay: Double, scene: String?) async {
    try? await Task.sleep(for: .seconds(delay))
    let window = await Platform.present()
    ScreenshotSignal.send((window.map { "ready window=\($0)" } ?? "ready") + (scene.map { " scene=\($0)" } ?? ""))
  }

  /// The next scenes, one JSON line each on stdin, sent once the picture before is taken.
  private static func followScenes() async {
    for await line in ScreenshotSignal.stdinLines() {
      guard let message = try? JSONDecoder().decode(ScreenshotSignal.NextScene.self, from: Data(line.utf8))
      else { continue }
      Platform.apply(message.appearance)
      await handler?(message.scene)
      await present(delay: message.scene.delay, scene: message.scene.id)
    }
  }
}

extension ScreenshotConfig.Scene {
  /// The argument after `option` (`scene.value("--mode")` → `"history"`).
  public func value(_ option: String) -> String? {
    guard let index = arguments.firstIndex(of: option), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
  }

  /// Every argument after an `option` that repeats (`--add-folder a --add-folder b`).
  public func values(_ option: String) -> [String] {
    arguments.indices.dropLast().filter { arguments[$0] == option }.map { arguments[$0 + 1] }
  }

  public func flag(_ option: String) -> Bool { arguments.contains(option) }
}

/// What the app and `dev-screenshots` exchange: environment variables at launch, `dev-screenshot: …` lines on stdout
/// (`hello pid=… [scenes]`, `reopen`, `activate`, `focus active|inactive`, `ready [window=…] [scene=…]`) and, for apps
/// with a scene handler,
/// the next scene as a JSON line on stdin.
public enum ScreenshotSignal {
  public static let prefix = "dev-screenshot: "
  public static let sceneKey = "DEV_SCREENSHOT"
  public static let appearanceKey = "DEV_SCREENSHOT_APPEARANCE"
  public static let windowKey = "DEV_SCREENSHOT_WINDOW"
  public static let delayKey = "DEV_SCREENSHOT_DELAY"
  public static let activateKey = "DEV_SCREENSHOT_ACTIVATE"

  /// A later scene for an app that opens scenes in one launch.
  public struct NextScene: Codable, Sendable {
    public var scene: ScreenshotConfig.Scene
    public var appearance: ScreenshotConfig.Appearance?

    public init(scene: ScreenshotConfig.Scene, appearance: ScreenshotConfig.Appearance?) {
      self.scene = scene
      self.appearance = appearance
    }

    /// One line, as the app reads it.
    public var line: String {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      return String(decoding: (try? encoder.encode(self)) ?? Data(), as: UTF8.self) + "\n"
    }
  }

  static func environment(_ key: String) -> String? {
    ProcessInfo.processInfo.environment[key].flatMap { $0.isEmpty ? nil : $0 }
  }

  static var appearance: ScreenshotConfig.Appearance? {
    environment(appearanceKey).flatMap(ScreenshotConfig.Appearance.init(rawValue:))
  }

  /// Points, from `1440x900`.
  static var windowSize: (width: Double, height: Double)? {
    guard let parts = environment(windowKey)?.split(separator: "x").compactMap({ Double($0) }), parts.count == 2
    else { return nil }
    return (parts[0], parts[1])
  }

  static var delay: Double { environment(delayKey).flatMap(Double.init) ?? 1 }

  static var activates: Bool { environment(activateKey) == "1" }

  /// Unbuffered, so `dev-screenshots` reads it while the app runs.
  static func send(_ message: String) {
    FileHandle.standardOutput.write(Data((prefix + message + "\n").utf8))
  }

  /// stdin's lines, read on a thread of their own so the blocking reads never hold up the app.
  static func stdinLines() -> AsyncStream<String> {
    AsyncStream { continuation in
      let thread = Thread {
        while let line = readLine() { continuation.yield(line) }
        continuation.finish()
      }
      thread.name = "dev-screenshot stdin"
      thread.start()
    }
  }

  /// The message of a `dev-screenshot: …` line, nil for the app's other output.
  public static func message(in line: String) -> String? {
    guard let range = line.range(of: prefix) else { return nil }
    return String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
