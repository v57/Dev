import Foundation

/// A project's screenshots, in `.dev/screenshots.json` at its root: which scenes there are, how the app reaches each
/// one (its own launch arguments), and the devices, locales and appearances to capture them on. The same file serves
/// every v57 app, Dev's Screenshots tool, `dev-screenshots` and agents.
///
/// ```json
/// {
///   "build": { "scheme": "Git", "project": "Git.xcodeproj" },
///   "locales": ["en-US", "de-DE"],
///   "variables": { "DEMO": "$ROOT/Tools/screenshots" },
///   "mac": { "window": [1440, 900] },
///   "ios": { "devices": ["iPhone 17 Pro Max"] },
///   "framing": { "width": 2880, "height": 1800, "backgrounds": { "01-history": "#0A5FC2" } },
///   "scenes": [
///     { "id": "01-history", "arguments": ["--add-folder", "$DEMO/Repo", "--mode", "history"],
///       "caption": "Every branch at a glance" }
///   ]
/// }
/// ```
public struct ScreenshotConfig: Codable, Hashable, Sendable {
  /// Where the pictures and `manifest.json` go, relative to the project root.
  public var output: String
  public var locales: [String]
  public var appearances: [Appearance]
  /// `$NAME` and `${NAME}` in a scene's arguments and environment. `$ROOT` is always the project root, and a value can
  /// use it (`"$ROOT/Tools/screenshots"`).
  public var variables: [String: String]
  /// How to build the app. Without it, `mac.app` / `ios.app` must point at a built app.
  public var build: Build?
  public var mac: Mac?
  public var ios: IOS?
  /// Paths whose commits outdate the screenshots (`["Git", "Sources"]`). Without it, any commit does.
  public var watch: [String]?
  /// How the pictures are framed for the App Store; nil until the project frames them.
  public var framing: Framing?
  public var scenes: [Scene]

  public static let path = ".dev/screenshots.json"

  public init(
    output: String = ".build/screenshots", locales: [String] = ["en-US"], appearances: [Appearance] = [.light],
    variables: [String: String] = [:], build: Build? = nil, mac: Mac? = Mac(), ios: IOS? = nil,
    watch: [String]? = nil, framing: Framing? = nil, scenes: [Scene] = []
  ) {
    self.output = output
    self.locales = locales
    self.appearances = appearances
    self.variables = variables
    self.build = build
    self.mac = mac
    self.ios = ios
    self.watch = watch
    self.framing = framing
    self.scenes = scenes
  }

  public enum Appearance: String, Codable, Hashable, Sendable, CaseIterable {
    case light, dark
  }

  public struct Build: Codable, Hashable, Sendable {
    public var scheme: String
    /// One of `project` and `workspace`, relative to the root; neither lets xcodebuild find the one in the root.
    public var project: String?
    public var workspace: String?
    public var configuration: String
    /// Xcode's build folder, relative to the root.
    public var derivedData: String

    public init(
      scheme: String, project: String? = nil, workspace: String? = nil, configuration: String = "Debug",
      derivedData: String = ".build/xcode"
    ) {
      self.scheme = scheme
      self.project = project
      self.workspace = workspace
      self.configuration = configuration
      self.derivedData = derivedData
    }
  }

  public struct Mac: Codable, Hashable, Sendable {
    /// The window's content size in points; a Retina capture is twice that in pixels (1440×900 → 2880×1800, an App
    /// Store size). Only apps that call `Screenshots.prepare()` resize; the others are captured as they open.
    public var window: [Int]?
    /// The active-window look App Store pictures want: the app is brought to the front once, and every picture
    /// waits until it is focused (a capture pauses while the reader is in another app). `false` keeps it in the
    /// background, with the inactive look.
    public var activate: Bool
    /// A built app, relative to the root, instead of building `build`.
    public var app: String?

    public init(window: [Int]? = [1440, 900], activate: Bool = true, app: String? = nil) {
      self.window = window
      self.activate = activate
      self.app = app
    }
  }

  public struct IOS: Codable, Hashable, Sendable {
    /// Simulator names (`"iPhone 17 Pro Max"`, `"iPad Pro 13-inch (M5)"`) or UDIDs.
    public var devices: [String]
    /// A built simulator app, relative to the root, instead of building `build`.
    public var app: String?
    /// 9:41, full battery and bars, as in Apple's pictures.
    public var cleanStatusBar: Bool

    public init(devices: [String], app: String? = nil, cleanStatusBar: Bool = true) {
      self.devices = devices
      self.app = app
      self.cleanStatusBar = cleanStatusBar
    }
  }

  public struct Scene: Codable, Hashable, Sendable, Identifiable {
    /// The picture's name, also the file name (`01-history`). The order of `scenes` is the order of the pictures.
    public var id: String
    /// The app's own launch arguments that open this screen, after variables are expanded.
    public var arguments: [String]
    public var environment: [String: String]
    /// `mac`, `iphone`, `ipad`; without it, every platform the config captures.
    public var platforms: [Platform]?
    /// Seconds to let the screen settle before the picture: after the app says it is ready, or after its window
    /// appears for apps without `Screenshots.prepare()`.
    public var delay: Double
    /// The caption key in the development language, for `framing` and App Store text. It doesn't change the capture.
    public var caption: String?
    /// Start the app afresh for this scene even when it opens scenes in one launch: for arguments that only work at
    /// launch, or state the scene handler can't undo.
    public var relaunch: Bool

    public init(
      id: String, arguments: [String] = [], environment: [String: String] = [:], platforms: [Platform]? = nil,
      delay: Double = 1, caption: String? = nil, relaunch: Bool = false
    ) {
      self.id = id
      self.arguments = arguments
      self.environment = environment
      self.platforms = platforms
      self.delay = delay
      self.caption = caption
      self.relaunch = relaunch
    }

    public func runs(on platform: Platform) -> Bool { platforms?.contains(platform) ?? true }
  }

  public enum Platform: String, Codable, Hashable, Sendable, CaseIterable {
    case mac, iphone, ipad
  }
}

// MARK: - Defaults when a key is missing

extension ScreenshotConfig {
  private enum CodingKeys: String, CodingKey {
    case output, locales, appearances, variables, build, mac, ios, watch, framing, scenes
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let defaults = ScreenshotConfig()
    output = try c.decodeIfPresent(String.self, forKey: .output) ?? defaults.output
    locales = try c.decodeIfPresent([String].self, forKey: .locales) ?? defaults.locales
    appearances = try c.decodeIfPresent([Appearance].self, forKey: .appearances) ?? defaults.appearances
    variables = try c.decodeIfPresent([String: String].self, forKey: .variables) ?? [:]
    build = try c.decodeIfPresent(Build.self, forKey: .build)
    mac = try c.decodeIfPresent(Mac.self, forKey: .mac)
    ios = try c.decodeIfPresent(IOS.self, forKey: .ios)
    watch = try c.decodeIfPresent([String].self, forKey: .watch)
    // The framing never stops a capture: a section that doesn't parse is left out.
    framing = (try? c.decodeIfPresent(Framing.self, forKey: .framing)) ?? nil
    scenes = try c.decodeIfPresent([Scene].self, forKey: .scenes) ?? []
    // A file with neither section captures on the Mac.
    if mac == nil && ios == nil { mac = Mac() }
  }

  /// Writes what differs from the defaults, so a saved file stays as short as a written one.
  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    let defaults = ScreenshotConfig()
    if output != defaults.output { try c.encode(output, forKey: .output) }
    if locales != defaults.locales { try c.encode(locales, forKey: .locales) }
    if appearances != defaults.appearances { try c.encode(appearances, forKey: .appearances) }
    if !variables.isEmpty { try c.encode(variables, forKey: .variables) }
    try c.encodeIfPresent(build, forKey: .build)
    try c.encodeIfPresent(mac, forKey: .mac)
    try c.encodeIfPresent(ios, forKey: .ios)
    try c.encodeIfPresent(watch, forKey: .watch)
    try c.encodeIfPresent(framing, forKey: .framing)
    try c.encode(scenes, forKey: .scenes)
  }
}

extension ScreenshotConfig.Build {
  private enum CodingKeys: String, CodingKey { case scheme, project, workspace, configuration, derivedData }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      scheme: try c.decode(String.self, forKey: .scheme),
      project: try c.decodeIfPresent(String.self, forKey: .project),
      workspace: try c.decodeIfPresent(String.self, forKey: .workspace),
      configuration: try c.decodeIfPresent(String.self, forKey: .configuration) ?? "Debug",
      derivedData: try c.decodeIfPresent(String.self, forKey: .derivedData) ?? ".build/xcode")
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(scheme, forKey: .scheme)
    try c.encodeIfPresent(project, forKey: .project)
    try c.encodeIfPresent(workspace, forKey: .workspace)
    if configuration != "Debug" { try c.encode(configuration, forKey: .configuration) }
    if derivedData != ".build/xcode" { try c.encode(derivedData, forKey: .derivedData) }
  }
}

extension ScreenshotConfig.Mac {
  private enum CodingKeys: String, CodingKey { case window, activate, app }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      window: c.contains(.window) ? try c.decodeIfPresent([Int].self, forKey: .window) : [1440, 900],
      activate: try c.decodeIfPresent(Bool.self, forKey: .activate) ?? true,
      app: try c.decodeIfPresent(String.self, forKey: .app))
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    // A missing window is the default size; null keeps the app's own.
    if let window {
      if window != [1440, 900] { try c.encode(window, forKey: .window) }
    } else {
      try c.encodeNil(forKey: .window)
    }
    if !activate { try c.encode(activate, forKey: .activate) }
    try c.encodeIfPresent(app, forKey: .app)
  }
}

extension ScreenshotConfig.IOS {
  private enum CodingKeys: String, CodingKey { case devices, app, cleanStatusBar }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      devices: try c.decodeIfPresent([String].self, forKey: .devices) ?? [],
      app: try c.decodeIfPresent(String.self, forKey: .app),
      cleanStatusBar: try c.decodeIfPresent(Bool.self, forKey: .cleanStatusBar) ?? true)
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(devices, forKey: .devices)
    try c.encodeIfPresent(app, forKey: .app)
    if !cleanStatusBar { try c.encode(cleanStatusBar, forKey: .cleanStatusBar) }
  }
}

extension ScreenshotConfig.Scene {
  private enum CodingKeys: String, CodingKey { case id, arguments, environment, platforms, delay, caption, relaunch }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      id: try c.decode(String.self, forKey: .id),
      arguments: try c.decodeIfPresent([String].self, forKey: .arguments) ?? [],
      environment: try c.decodeIfPresent([String: String].self, forKey: .environment) ?? [:],
      platforms: try c.decodeIfPresent([ScreenshotConfig.Platform].self, forKey: .platforms),
      delay: try c.decodeIfPresent(Double.self, forKey: .delay) ?? 1,
      caption: try c.decodeIfPresent(String.self, forKey: .caption),
      relaunch: try c.decodeIfPresent(Bool.self, forKey: .relaunch) ?? false)
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(id, forKey: .id)
    if !arguments.isEmpty { try c.encode(arguments, forKey: .arguments) }
    if !environment.isEmpty { try c.encode(environment, forKey: .environment) }
    try c.encodeIfPresent(platforms, forKey: .platforms)
    if delay != 1 { try c.encode(delay, forKey: .delay) }
    try c.encodeIfPresent(caption, forKey: .caption)
    if relaunch { try c.encode(relaunch, forKey: .relaunch) }
  }
}

// MARK: - File

extension ScreenshotConfig {
  public static func url(in root: URL) -> URL { root.appendingPathComponent(path) }

  /// The project's config, or nil when it has none. A file that doesn't parse throws, so the reader learns why.
  public static func load(in root: URL) throws -> ScreenshotConfig? {
    guard let data = try? Data(contentsOf: url(in: root)) else { return nil }
    return try JSONDecoder().decode(ScreenshotConfig.self, from: data)
  }

  public func save(in root: URL) throws {
    let url = Self.url(in: root)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try ScreenshotJSON.data(self).write(to: url, options: .atomic)
  }

  public func outputURL(in root: URL) -> URL { root.appendingPathComponent(output, isDirectory: true) }

  /// Problems that stop a capture, worded for the reader.
  public func problems() -> [String] {
    var problems: [String] = []
    if scenes.isEmpty { problems.append("There are no scenes.") }
    var seen = Set<String>()
    for scene in scenes {
      if scene.id.isEmpty || scene.id.contains(where: { $0 == "/" || $0.isWhitespace }) {
        problems.append("“\(scene.id)” can't be a file name (no spaces or slashes).")
      }
      if !seen.insert(scene.id).inserted { problems.append("Two scenes are called “\(scene.id)”.") }
    }
    if let window = mac?.window, window.count != 2 || window.contains(where: { $0 <= 0 }) {
      problems.append("mac.window is [width, height] in points.")
    }
    if let ios, ios.devices.isEmpty { problems.append("ios.devices names no simulator.") }
    if locales.isEmpty { problems.append("There are no locales.") }
    if appearances.isEmpty { problems.append("There are no appearances.") }
    return problems
  }

  // MARK: - Variables

  /// `$ROOT`, then the config's variables (which may use `$ROOT` and each other, in any order).
  public func resolvedVariables(root: URL) -> [String: String] {
    var resolved = ["ROOT": root.path]
    var pending = variables
    // Each pass resolves the variables whose references are known; a cycle is left as written.
    for _ in 0...variables.count {
      for (name, value) in pending {
        let expanded = Self.expand(value, with: resolved)
        if !Self.references(in: expanded).contains(where: { pending[$0] != nil && $0 != name }) {
          resolved[name] = expanded
          pending[name] = nil
        }
      }
      if pending.isEmpty { break }
    }
    for (name, value) in pending { resolved[name] = value }
    return resolved
  }

  /// Replaces `$NAME` and `${NAME}` with known variables; unknown ones stay as written.
  public static func expand(_ text: String, with variables: [String: String]) -> String {
    guard text.contains("$") else { return text }
    var out = ""
    var i = text.startIndex
    while i < text.endIndex {
      guard text[i] == "$" else {
        out.append(text[i])
        i = text.index(after: i)
        continue
      }
      let next = text.index(after: i)
      var nameStart = next
      var braced = false
      if next < text.endIndex, text[next] == "{" {
        braced = true
        nameStart = text.index(after: next)
      }
      var end = nameStart
      while end < text.endIndex, text[end].isLetter || text[end].isNumber || text[end] == "_" { end = text.index(after: end) }
      let name = String(text[nameStart..<end])
      if braced, end < text.endIndex, text[end] == "}", let value = variables[name] {
        out += value
        i = text.index(after: end)
      } else if !braced, !name.isEmpty, let value = variables[name] {
        out += value
        i = end
      } else {
        out.append("$")
        i = next
      }
    }
    return out
  }

  static func references(in text: String) -> [String] {
    var names: [String] = []
    var rest = text[...]
    while let dollar = rest.firstIndex(of: "$") {
      var name = rest[rest.index(after: dollar)...]
      if name.first == "{" { name = name.dropFirst() }
      let id = name.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
      if !id.isEmpty { names.append(String(id)) }
      rest = name.dropFirst(id.count)
    }
    return names
  }

  /// A scene's arguments and environment with the variables filled in.
  public func expanded(_ scene: Scene, root: URL) -> Scene {
    let variables = resolvedVariables(root: root)
    var scene = scene
    scene.arguments = scene.arguments.map { Self.expand($0, with: variables) }
    scene.environment = scene.environment.mapValues { Self.expand($0, with: variables) }
    return scene
  }
}
