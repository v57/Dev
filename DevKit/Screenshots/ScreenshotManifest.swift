import Foundation

/// What a capture left in the output folder (`manifest.json` next to the pictures): every picture with the commit it
/// was taken at and a fingerprint of the scene that made it, so Dev can tell which pictures the code or the config
/// has moved past.
public struct ScreenshotManifest: Codable, Hashable, Sendable {
  public var shots: [Shot]
  /// Scenes the last capture could not take, with the reason.
  public var failures: [Failure]

  public static let fileName = "manifest.json"

  public init(shots: [Shot] = [], failures: [Failure] = []) {
    self.shots = shots
    self.failures = failures
  }

  public struct Shot: Codable, Hashable, Sendable {
    public var scene: String
    public var platform: ScreenshotConfig.Platform
    /// The simulator's name; nil on the Mac.
    public var device: String?
    public var locale: String
    public var appearance: ScreenshotConfig.Appearance
    /// Relative to the output folder.
    public var file: String
    public var width: Int
    public var height: Int
    public var taken: Taken

    public init(
      scene: String, platform: ScreenshotConfig.Platform, device: String?, locale: String,
      appearance: ScreenshotConfig.Appearance, file: String, width: Int, height: Int, taken: Taken
    ) {
      self.scene = scene
      self.platform = platform
      self.device = device
      self.locale = locale
      self.appearance = appearance
      self.file = file
      self.width = width
      self.height = height
      self.taken = taken
    }

    /// Which picture this is, whatever its version: a new capture of the same key replaces it.
    public var key: String { [scene, platform.rawValue, device ?? "", locale, appearance.rawValue].joined(separator: "|") }
  }

  /// When and from what a picture was taken.
  public struct Taken: Codable, Hashable, Sendable {
    /// The commit count (`git rev-list --count HEAD`), the build number every v57 release uses.
    public var build: Int?
    public var commit: String?
    /// The working tree had changes under the watched paths.
    public var dirty: Bool
    public var date: Date
    /// `ScreenshotConfig.fingerprint(of:on:)` when it was taken.
    public var fingerprint: String

    public init(build: Int?, commit: String?, dirty: Bool, date: Date, fingerprint: String) {
      self.build = build
      self.commit = commit
      self.dirty = dirty
      self.date = date
      self.fingerprint = fingerprint
    }
  }

  public struct Failure: Codable, Hashable, Sendable {
    public var scene: String
    public var platform: ScreenshotConfig.Platform
    public var device: String?
    public var locale: String
    public var appearance: ScreenshotConfig.Appearance
    public var reason: String

    public init(
      scene: String, platform: ScreenshotConfig.Platform, device: String?, locale: String,
      appearance: ScreenshotConfig.Appearance, reason: String
    ) {
      self.scene = scene
      self.platform = platform
      self.device = device
      self.locale = locale
      self.appearance = appearance
      self.reason = reason
    }

    public var key: String { [scene, platform.rawValue, device ?? "", locale, appearance.rawValue].joined(separator: "|") }
  }

  /// The pictures of a newer capture replace those with the same key; the others stay, so capturing one scene keeps
  /// the rest. A picture that failed again keeps its older version, and its failure is listed.
  public func merging(_ newer: ScreenshotManifest) -> ScreenshotManifest {
    let taken = Set(newer.shots.map(\.key))
    let tried = taken.union(newer.failures.map(\.key))
    return ScreenshotManifest(
      shots: shots.filter { !taken.contains($0.key) } + newer.shots,
      failures: failures.filter { !tried.contains($0.key) } + newer.failures)
  }

  // MARK: - File

  public static func url(in output: URL) -> URL { output.appendingPathComponent(fileName) }

  public static func load(in output: URL) -> ScreenshotManifest? {
    guard let data = try? Data(contentsOf: url(in: output)) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(ScreenshotManifest.self, from: data)
  }

  public func save(in output: URL) throws {
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(self).write(to: Self.url(in: output), options: .atomic)
  }
}

// MARK: - Fingerprint

extension ScreenshotConfig {
  /// What a scene's picture on a platform depends on in the config: the scene as written, the variables and the
  /// platform's settings. Editing any of them outdates that picture; paths on this Mac don't enter it.
  public func fingerprint(of scene: Scene, on platform: Platform) -> String {
    struct Inputs: Encodable {
      var scene: Scene
      var variables: [String: String]
      var mac: Mac?
      var ios: IOS?
    }
    // How the scene is reached doesn't change what it shows.
    var shown = scene
    shown.relaunch = false
    var inputs = Inputs(scene: shown, variables: variables)
    // The devices list and app paths say where to capture, not what the picture shows.
    if platform == .mac {
      inputs.mac = mac.map { Mac(window: $0.window, activate: $0.activate) }
    } else {
      inputs.ios = ios.map { IOS(devices: [], cleanStatusBar: $0.cleanStatusBar) }
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = (try? encoder.encode(inputs)) ?? Data()
    // FNV-1a: stable across runs and platforms, unlike Hasher.
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in data {
      hash ^= UInt64(byte)
      hash = hash &* 0x100_0000_01b3
    }
    return String(hash, radix: 16)
  }
}
