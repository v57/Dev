#if os(macOS)
  import DevScreenshots
  import Foundation

  /// Builds the app a capture launches, with xcodebuild, into the config's build folder.
  enum AppBuilder {
    enum Target {
      case mac, simulator

      var destination: String { self == .mac ? "platform=macOS" : "generic/platform=iOS Simulator" }
      var productsFolder: String { self == .mac ? "" : "-iphonesimulator" }
    }

    static func build(
      _ build: ScreenshotConfig.Build, for target: Target, root: URL, log: (String) -> Void
    ) throws -> URL {
      let environment = ProcessInfo.processInfo.environment
      var arguments: [String] = []
      // DEV_SCREENSHOTS_LOCAL=1: the project's <App>-Local.xcworkspace (the sibling checkouts) when it has one.
      let local = environment["DEV_SCREENSHOTS_LOCAL"] == "1" ? localWorkspace(in: root) : nil
      if let local {
        arguments += ["-workspace", local]
      } else {
        if let workspace = build.workspace { arguments += ["-workspace", workspace] }
        if let project = build.project { arguments += ["-project", project] }
      }
      let derivedData = Self.derivedData(build)
      arguments += [
        "-scheme", build.scheme, "-configuration", build.configuration, "-destination", target.destination,
        "-derivedDataPath", derivedData, "-quiet", "build",
      ]
      // The simulators run this Mac's architecture alone, and a prebuilt library may have only that slice (SSH's
      // libssh2 for the simulator is arm64): the generic destination would build, and fail to link, the other one.
      if target != .mac { arguments.append("ARCHS=\(Self.hostArchitecture)") }
      log("Building \(build.scheme) (\(build.configuration), \(target == .mac ? "Mac" : "Simulator"))\(local.map { " from \($0)" } ?? "")…")
      // RELEASE_BUILD_LOCK: heavy builds on this Mac take turns on this lock file (lockf).
      let result = environment["RELEASE_BUILD_LOCK"].flatMap { $0.isEmpty ? nil : $0 }.map { lock in
        Shell.run("/usr/bin/lockf", [lock, "xcodebuild"] + arguments, in: root)
      } ?? Shell.run("xcodebuild", arguments, in: root)
      guard result.succeeded else {
        throw CaptureError("xcodebuild failed:\n" + result.tail())
      }
      let products = Self.products(build, for: target, root: root)
      guard let app = findApp(in: products, named: build.scheme) else {
        throw CaptureError("xcodebuild built no app in \(products.path)")
      }
      return app
    }

    /// The architecture this Mac's simulators run.
    static var hostArchitecture: String {
      #if arch(arm64)
        "arm64"
      #else
        "x86_64"
      #endif
    }

    /// DEV_SCREENSHOTS_DERIVED_DATA (a build folder of this Mac's, an absolute path), else the config's.
    static func derivedData(_ build: ScreenshotConfig.Build) -> String {
      ProcessInfo.processInfo.environment["DEV_SCREENSHOTS_DERIVED_DATA"].flatMap { $0.isEmpty ? nil : $0 } ?? build.derivedData
    }

    /// Where the build's apps land for a target.
    static func products(_ build: ScreenshotConfig.Build, for target: Target, root: URL) -> URL {
      URL(fileURLWithPath: derivedData(build), relativeTo: root).standardizedFileURL
        .appendingPathComponent("Build/Products/\(build.configuration)\(target.productsFolder)")
    }

    /// The `*-Local.xcworkspace` at the project's root, if any.
    static func localWorkspace(in root: URL) -> String? {
      (try? FileManager.default.contentsOfDirectory(atPath: root.path))?.sorted().first { $0.hasSuffix("-Local.xcworkspace") }
    }

    /// `<scheme>.app`, else the newest app in the folder.
    static func findApp(in folder: URL, named name: String) -> URL? {
      let named = folder.appendingPathComponent("\(name).app")
      if FileManager.default.fileExists(atPath: named.path) { return named }
      let apps = (try? FileManager.default.contentsOfDirectory(
        at: folder, includingPropertiesForKeys: [.contentModificationDateKey]))?.filter { $0.pathExtension == "app" }
      return apps?.max {
        let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        return a < b
      }
    }

    static func bundleIdentifier(of app: URL) -> String? {
      Bundle(url: app)?.bundleIdentifier
        ?? (NSDictionary(contentsOf: app.appendingPathComponent("Info.plist"))?["CFBundleIdentifier"] as? String)
    }
  }
#endif
