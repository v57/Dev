#if os(macOS)
  import DevScreenshots
  import Foundation

  /// Whether a project's pictures still show its code: per scene, against the current commit and config.
  public struct ScreenshotStatus: Hashable, Sendable {
    public var scenes: [Scene]
    /// The project's commit now.
    public var version: ProjectVersion
    /// The oldest build any picture was taken at.
    public var oldestBuild: Int?

    public struct Scene: Hashable, Sendable, Identifiable {
      public var id: String
      public var state: State
      /// The newest picture of the scene.
      public var taken: ScreenshotManifest.Taken?
      /// The picture that stands for the scene: the Mac's, else the first device's, in the first locale.
      public var preview: String?
    }

    public enum State: Hashable, Sendable {
      /// Never captured.
      case missing
      /// Some of its devices, locales or appearances have no picture.
      case incomplete(missing: Int)
      /// The scene's arguments or the platform settings changed since.
      case changed
      /// Commits touched the watched paths since; nil when the commit is gone from the history.
      case outdated(commits: Int?)
      case current

      public var isCurrent: Bool { self == .current }
    }

    public var isCurrent: Bool { scenes.allSatisfy(\.state.isCurrent) }

    /// One line for a list: "Up to date", "3 of 5 scenes outdated".
    public var summary: String {
      let stale = scenes.filter { !$0.state.isCurrent }.count
      if scenes.isEmpty { return "No scenes" }
      if stale == 0 { return "Up to date" + (oldestBuild.map { " (build \($0))" } ?? "") }
      if scenes.allSatisfy({ $0.state == .missing }) { return "Not captured yet" }
      return "\(stale) of \(scenes.count) scenes need a new capture"
    }

    /// nil when the project has no `.dev/screenshots.json`.
    public static func check(root: URL) throws -> ScreenshotStatus? {
      guard let config = try ScreenshotConfig.load(in: root) else { return nil }
      let manifest = ScreenshotManifest.load(in: config.outputURL(in: root)) ?? ScreenshotManifest()
      return check(config: config, manifest: manifest, root: root)
    }

    public static func check(config: ScreenshotConfig, manifest: ScreenshotManifest, root: URL) -> ScreenshotStatus {
      let version = ProjectVersion.current(in: root, watch: config.watch)
      var behind: [String: Int?] = [:]
      func commits(since commit: String?) -> Int? {
        // Outside git there's nothing to compare.
        guard let commit else { return version.commit == nil ? 0 : nil }
        if commit == version.commit { return 0 }
        if let known = behind[commit] { return known }
        let count = ProjectVersion.commits(since: commit, in: root, watch: config.watch)
        behind[commit] = count
        return count
      }

      let byScene = Dictionary(grouping: manifest.shots, by: \.scene)
      let scenes = config.scenes.map { scene -> Scene in
        let shots = byScene[scene.id] ?? []
        let newest = shots.max { $0.taken.date < $1.taken.date }
        let preview = (shots.first { $0.platform == .mac } ?? shots.first)?.file
        func done(_ state: State) -> Scene { Scene(id: scene.id, state: state, taken: newest?.taken, preview: preview) }

        let expected = expectedKeys(for: scene, in: config)
        let present = Set(shots.map(\.key))
        let missing = expected.subtracting(present).count
        if shots.isEmpty || present.isDisjoint(with: expected) { return done(.missing) }
        let current = shots.filter { expected.contains($0.key) }
        if current.contains(where: { $0.taken.fingerprint != config.fingerprint(of: scene, on: $0.platform) }) {
          return done(.changed)
        }
        var most = 0
        for shot in current {
          guard let count = commits(since: shot.taken.commit) else { return done(.outdated(commits: nil)) }
          most = max(most, count)
        }
        if most > 0 { return done(.outdated(commits: most)) }
        if missing > 0 { return done(.incomplete(missing: missing)) }
        return done(.current)
      }
      return ScreenshotStatus(
        scenes: scenes, version: version, oldestBuild: manifest.shots.compactMap(\.taken.build).min())
    }

    /// The pictures a full capture of the scene takes, as manifest keys.
    static func expectedKeys(for scene: ScreenshotConfig.Scene, in config: ScreenshotConfig) -> Set<String> {
      var targets: [(ScreenshotConfig.Platform, String?)] = []
      if config.mac != nil, scene.runs(on: .mac) { targets.append((.mac, nil)) }
      for device in config.ios?.devices ?? [] {
        let platform = DeviceFamily.platform(ofName: device)
        if scene.runs(on: platform) { targets.append((platform, device)) }
      }
      var keys = Set<String>()
      for (platform, device) in targets {
        for locale in config.locales {
          for appearance in config.appearances {
            keys.insert([scene.id, platform.rawValue, device ?? "", locale, appearance.rawValue].joined(separator: "|"))
          }
        }
      }
      return keys
    }
  }

  enum DeviceFamily {
    /// From a simulator's name; a UDID counts as an iPhone.
    static func platform(ofName name: String) -> ScreenshotConfig.Platform {
      name.localizedCaseInsensitiveContains("ipad") ? .ipad : .iphone
    }
  }
#endif
