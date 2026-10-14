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
      var arguments: [String] = []
      if let workspace = build.workspace { arguments += ["-workspace", workspace] }
      if let project = build.project { arguments += ["-project", project] }
      arguments += [
        "-scheme", build.scheme, "-configuration", build.configuration, "-destination", target.destination,
        "-derivedDataPath", build.derivedData, "-quiet", "build",
      ]
      log("Building \(build.scheme) (\(build.configuration), \(target == .mac ? "Mac" : "Simulator"))…")
      let result = Shell.run("xcodebuild", arguments, in: root)
      guard result.succeeded else {
        throw CaptureError("xcodebuild failed:\n" + result.tail())
      }
      let products = root.appendingPathComponent(build.derivedData)
        .appendingPathComponent("Build/Products/\(build.configuration)\(target.productsFolder)")
      guard let app = findApp(in: products, named: build.scheme) else {
        throw CaptureError("xcodebuild built no app in \(products.path)")
      }
      return app
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
