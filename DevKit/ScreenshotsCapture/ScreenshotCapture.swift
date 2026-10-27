  import DevScreenshots
  import Foundation
  #if os(macOS)
    import ImageIO
  #endif

  /// Captures a project's scenes as `.dev/screenshots.json` describes them, into its output folder:
  /// `<output>/<mac|device>/<locale>/<scene>[-dark].png`, and `manifest.json` with the commit each picture was
  /// taken at. Pictures of scenes left out of this run stay, so capturing one scene keeps the others.
  public struct ScreenshotCapture: Sendable {
    public var root: URL
    public var config: ScreenshotConfig
    public var options: Options

    public struct Options: Sendable {
      /// Only these scenes, locales, platforms; empty for all.
      public var scenes: [String] = []
      public var locales: [String] = []
      public var platforms: [ScreenshotConfig.Platform] = []
      /// Simulators instead of `ios.devices`.
      public var devices: [String] = []
      /// Built apps instead of building `build`.
      public var macApp: URL?
      public var iosApp: URL?
      /// Use the last build in the build folder instead of building.
      public var skipBuild = false

      public init() {}
    }

    public init(root: URL, config: ScreenshotConfig, options: Options = Options()) {
      self.root = root
      self.config = config
      self.options = options
    }

    /// Reads the project's config.
    public init(root: URL, options: Options = Options()) throws {
      guard let config = try ScreenshotConfig.load(in: root) else {
        throw CaptureError("\(root.lastPathComponent) has no \(ScreenshotConfig.path)")
      }
      self.init(root: root, config: config, options: options)
    }

    /// Whether this system captures pictures (the Mac: its apps and the iOS simulators).
    public static var isAvailable: Bool {
      #if os(macOS)
        true
      #else
        false
      #endif
    }

  #if os(macOS)
    /// Takes the pictures and saves the merged manifest. A scene that fails is listed in the manifest's failures and
    /// the others go on; a missing app or simulator throws.
    @discardableResult
    public func run(log: @escaping (String) -> Void = { print($0) }) throws -> ScreenshotManifest {
      let problems = config.problems()
      guard problems.isEmpty else { throw CaptureError(problems.joined(separator: "\n")) }
      let output = config.outputURL(in: root)
      let version = ProjectVersion.current(in: root, watch: config.watch)
      if version.dirty { log("Note: the watched files have uncommitted changes; the pictures count as that commit.") }

      let scenes = config.scenes.filter { options.scenes.isEmpty || options.scenes.contains($0.id) }
      guard !scenes.isEmpty else { throw CaptureError("no scene is called \(options.scenes.joined(separator: ", "))") }
      let locales = config.locales.filter { options.locales.isEmpty || options.locales.contains($0) }
      guard !locales.isEmpty else { throw CaptureError("the config has no locale \(options.locales.joined(separator: ", "))") }
      func wanted(_ platform: ScreenshotConfig.Platform) -> Bool {
        options.platforms.isEmpty || options.platforms.contains(platform)
      }

      var manifest = ScreenshotManifest()
      func taken(_ scene: ScreenshotConfig.Scene, _ platform: ScreenshotConfig.Platform) -> ScreenshotManifest.Taken {
        ScreenshotManifest.Taken(
          build: version.build, commit: version.commit, dirty: version.dirty, date: Date(),
          fingerprint: config.fingerprint(of: scene, on: platform))
      }

      // MARK: Mac
      func record(
        _ shot: CaptureShot, _ error: Error?, platform: ScreenshotConfig.Platform, device: String?, locale: String
      ) {
        let id = shot.scene.id
        let scene = scenes.first { $0.id == id } ?? shot.scene
        if let error {
          log("  \(id) \(shot.appearance.rawValue) failed: \(error.localizedDescription)")
          manifest.failures.append(
            .init(
              scene: id, platform: platform, device: device, locale: locale, appearance: shot.appearance,
              reason: error.localizedDescription))
        } else {
          log("  \(id) \(shot.appearance.rawValue)")
          let size = Self.pixelSize(of: shot.file)
          manifest.shots.append(
            .init(
              scene: id, platform: platform, device: device, locale: locale, appearance: shot.appearance,
              file: shot.file.path.replacingOccurrences(of: output.path + "/", with: ""), width: size.width,
              height: size.height, taken: taken(scene, platform)))
        }
      }
      func shots(on platform: ScreenshotConfig.Platform, target: String, locale: String) -> [CaptureShot] {
        scenes.filter { $0.runs(on: platform) }.flatMap { scene in
          config.appearances.map { appearance in
            CaptureShot(
              scene: config.expanded(scene, root: root), appearance: appearance,
              file: output.appendingPathComponent(
                Self.file(scene: scene.id, target: target, locale: locale, appearance: appearance)))
          }
        }
      }

      if let mac = config.mac, wanted(.mac), scenes.contains(where: { $0.runs(on: .mac) }) {
        let app = try macApp(mac, log: log)
        let capturer = MacCapturer(app: app, settings: mac, log: log)
        for locale in locales {
          log("Mac, \(locale)")
          capturer.capture(shots(on: .mac, target: "mac", locale: locale), locale: locale) {
            record($0, $1, platform: .mac, device: nil, locale: locale)
          }
        }
      }

      // MARK: Simulators
      if let ios = config.ios {
        let names = options.devices.isEmpty ? ios.devices : options.devices
        let devices = try names.map { (name: $0, device: try SimulatorCapturer.find($0)) }
          .filter { wanted($0.device.platform) }
        if !devices.isEmpty, scenes.contains(where: { s in devices.contains { s.runs(on: $0.device.platform) } }) {
          let app = try iosApp(ios, log: log)
          guard let bundleID = AppBuilder.bundleIdentifier(of: app) else {
            throw CaptureError("\(app.lastPathComponent) has no bundle identifier")
          }
          for (name, device) in devices {
            let capturer = SimulatorCapturer(device: device, app: app, bundleID: bundleID, settings: ios, log: log)
            let bootedHere = try capturer.prepare()
            defer { capturer.finish(shutDown: bootedHere) }
            for locale in locales {
              log("\(device.name), \(locale)")
              capturer.capture(shots(on: device.platform, target: Self.slug(device.name), locale: locale), locale: locale) {
                record($0, $1, platform: device.platform, device: name, locale: locale)
              }
            }
          }
        }
      }

      let merged = (ScreenshotManifest.load(in: output) ?? ScreenshotManifest()).merging(manifest)
      try merged.save(in: output)
      log("\(manifest.shots.count) pictures in \(output.path)" + (manifest.failures.isEmpty ? "" : ", \(manifest.failures.count) failed"))
      return manifest
    }

    // MARK: - Apps

    private func macApp(_ mac: ScreenshotConfig.Mac, log: (String) -> Void) throws -> URL {
      if let app = options.macApp ?? mac.app.map({ root.appendingPathComponent($0) }) {
        guard FileManager.default.fileExists(atPath: app.path) else { throw CaptureError("there is no app at \(app.path)") }
        return app
      }
      guard let build = config.build else { throw CaptureError("the config has neither build nor mac.app") }
      if options.skipBuild {
        let products = root.appendingPathComponent(build.derivedData).appendingPathComponent("Build/Products/\(build.configuration)")
        if let app = AppBuilder.findApp(in: products, named: build.scheme) { return app }
      }
      return try AppBuilder.build(build, for: .mac, root: root, log: log)
    }

    private func iosApp(_ ios: ScreenshotConfig.IOS, log: (String) -> Void) throws -> URL {
      if let app = options.iosApp ?? ios.app.map({ root.appendingPathComponent($0) }) {
        guard FileManager.default.fileExists(atPath: app.path) else { throw CaptureError("there is no app at \(app.path)") }
        return app
      }
      guard let build = config.build else { throw CaptureError("the config has neither build nor ios.app") }
      if options.skipBuild {
        let products = root.appendingPathComponent(build.derivedData)
          .appendingPathComponent("Build/Products/\(build.configuration)-iphonesimulator")
        if let app = AppBuilder.findApp(in: products, named: build.scheme) { return app }
      }
      return try AppBuilder.build(build, for: .simulator, root: root, log: log)
    }

    // MARK: - Files

    static func file(scene: String, target: String, locale: String, appearance: ScreenshotConfig.Appearance) -> String {
      "\(target)/\(locale)/\(scene)\(appearance == .dark ? "-dark" : "").png"
    }

    /// `iPhone 17 Pro Max` → `iphone-17-pro-max`.
    static func slug(_ name: String) -> String {
      let parts = name.lowercased().split { !$0.isLetter && !$0.isNumber }
      return parts.joined(separator: "-")
    }

    static func pixelSize(of file: URL) -> (width: Int, height: Int) {
      guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
      else { return (0, 0) }
      return (properties[kCGImagePropertyPixelWidth] as? Int ?? 0, properties[kCGImagePropertyPixelHeight] as? Int ?? 0)
    }
  #else
    /// Off the Mac there is nothing to capture with: throws.
    @discardableResult
    public func run(log: @escaping (String) -> Void = { print($0) }) throws -> ScreenshotManifest {
      throw CaptureError("capturing screenshots needs macOS (its apps and the iOS simulators)")
    }
  #endif
  }
