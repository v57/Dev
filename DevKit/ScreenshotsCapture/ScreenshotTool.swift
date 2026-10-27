  import DevScreenshots
  import Foundation

  /// `dev-screenshots`, also run by Dev as `Dev --screenshots …`.
  public enum ScreenshotTool {
    public static let usage = """
      usage: dev-screenshots <command> [--project <folder>] [options]

        capture   take the pictures .dev/screenshots.json describes
                    --scene <id>  --locale <code>  --platform mac|iphone|ipad  (each repeatable)
                    --device <simulator>  --app <Mac .app>  --ios-app <simulator .app>  --no-build
        status    which scenes the commits or the config have outdated (--json)
        check     read the config and list its problems

      The project is the current folder unless --project names one.
      """

    /// Runs a command; the exit status.
    public static func run(_ arguments: [String], log: @escaping (String) -> Void = { print($0) }) -> Int32 {
      var arguments = arguments
      guard let command = arguments.first, !command.hasPrefix("-") else {
        log(usage)
        return arguments.contains("--help") || arguments.contains("-h") ? 0 : 64
      }
      arguments.removeFirst()

      var root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      var options = ScreenshotCapture.Options()
      var json = false
      var i = 0
      func value() -> String? {
        i += 1
        return i < arguments.count ? arguments[i] : nil
      }
      while i < arguments.count {
        let argument = arguments[i]
        switch argument {
        case "--project": if let v = value() { root = URL(fileURLWithPath: (v as NSString).expandingTildeInPath) }
        case "--scene": if let v = value() { options.scenes.append(v) }
        case "--locale": if let v = value() { options.locales.append(v) }
        case "--platform":
          guard let v = value(), let platform = ScreenshotConfig.Platform(rawValue: v) else {
            log("--platform is mac, iphone or ipad")
            return 64
          }
          options.platforms.append(platform)
        case "--device": if let v = value() { options.devices.append(v) }
        case "--app": if let v = value() { options.macApp = URL(fileURLWithPath: (v as NSString).expandingTildeInPath) }
        case "--ios-app": if let v = value() { options.iosApp = URL(fileURLWithPath: (v as NSString).expandingTildeInPath) }
        case "--no-build": options.skipBuild = true
        case "--json": json = true
        default:
          log("unknown option \(argument)\n\n\(usage)")
          return 64
        }
        i += 1
      }
      root = root.standardizedFileURL

      do {
        switch command {
        case "capture":
          let manifest = try ScreenshotCapture(root: root, options: options).run(log: log)
          return manifest.failures.isEmpty ? 0 : 1
        case "status":
          guard let status = try ScreenshotStatus.check(root: root) else {
            log("\(root.lastPathComponent) has no \(ScreenshotConfig.path)")
            return 1
          }
          log(json ? statusJSON(status) : statusText(status))
          return status.isCurrent ? 0 : 2
        case "check":
          guard let config = try ScreenshotConfig.load(in: root) else {
            log("\(root.lastPathComponent) has no \(ScreenshotConfig.path)")
            return 1
          }
          let problems = config.problems()
          log(problems.isEmpty ? "\(config.scenes.count) scenes, no problems" : problems.joined(separator: "\n"))
          return problems.isEmpty ? 0 : 1
        default:
          log("unknown command \(command)\n\n\(usage)")
          return 64
        }
      } catch {
        log("error: \(error.localizedDescription)")
        return 1
      }
    }

    static func statusText(_ status: ScreenshotStatus) -> String {
      var lines = [
        status.summary + (status.version.build.map { " — the project is at build \($0)" } ?? "")
          + (status.version.dirty ? " with uncommitted changes" : "")
      ]
      for scene in status.scenes {
        let state: String
        switch scene.state {
        case .missing: state = "not captured"
        case .incomplete(let missing): state = "\(missing) pictures missing"
        case .changed: state = "the config changed"
        case .outdated(let commits): state = commits.map { "\($0) commits behind" } ?? "its commit is gone"
        case .current: state = "up to date"
        }
        let build = scene.taken?.build.map { " (build \($0))" } ?? ""
        lines.append("  \(scene.id): \(state)\(build)")
      }
      return lines.joined(separator: "\n")
    }

    static func statusJSON(_ status: ScreenshotStatus) -> String {
      let scenes: [[String: Any]] = status.scenes.map { scene in
        var entry: [String: Any] = ["id": scene.id]
        switch scene.state {
        case .missing: entry["state"] = "missing"
        case .incomplete(let missing): entry["state"] = "incomplete"; entry["missing"] = missing
        case .changed: entry["state"] = "changed"
        case .outdated(let commits): entry["state"] = "outdated"; entry["commits"] = commits ?? NSNull()
        case .current: entry["state"] = "current"
        }
        if let build = scene.taken?.build { entry["build"] = build }
        if let preview = scene.preview { entry["preview"] = preview }
        return entry
      }
      var object: [String: Any] = ["current": status.isCurrent, "summary": status.summary, "scenes": scenes]
      if let build = status.version.build { object["build"] = build }
      let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
      return String(decoding: data, as: UTF8.self)
    }
  }
