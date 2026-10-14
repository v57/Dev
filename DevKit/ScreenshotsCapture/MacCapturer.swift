#if os(macOS)
  import AppKit
  import DevScreenshots
  import Foundation

  /// Takes a locale's pictures of a Mac app: launches a new instance in the background (`open -n -g`, so nobody's
  /// typing lands in it), waits until the scene is up and captures its window with `screencapture -l`.
  ///
  /// An app with a scene handler (`Screenshots.prepare { scene in … }`) takes every scene in that one launch; the
  /// others are launched again for each. Apps without `Screenshots.prepare()` are captured by their largest window
  /// once it has appeared and the scene's delay has passed.
  /// A scene in an appearance, and where its picture goes.
  struct CaptureShot {
    var scene: ScreenshotConfig.Scene
    var appearance: ScreenshotConfig.Appearance
    var file: URL
  }

  struct MacCapturer {
    var app: URL
    var settings: ScreenshotConfig.Mac
    var log: (String) -> Void

    /// How long a scene may take to come up.
    var timeout: TimeInterval = 60

    /// Takes the shots in order, in as few launches as the app allows; `report` hears each one's outcome.
    func capture(_ shots: [CaptureShot], locale: String, report: (CaptureShot, Error?) -> Void) {
      var instance: Instance?
      defer { instance?.quit() }
      for shot in shots {
        do {
          let window: Int
          if let running = instance, running.takesScenes, !shot.scene.relaunch {
            try running.send(shot)
            window = try running.waitForReady(scene: shot.scene.id, timeout: timeout)
          } else {
            instance?.quit()
            instance = nil
            let launched = try Instance(app: app, first: shot, locale: locale, settings: settings)
            instance = launched
            window = try launched.waitForFirstReady(delay: shot.scene.delay, timeout: timeout)
          }
          try Self.screencapture(window: window, to: shot.file)
          report(shot, nil)
        } catch {
          report(shot, error)
          instance?.quit()
          instance = nil
        }
      }
    }

    // MARK: - A running instance

    final class Instance {
      let app: URL
      let scratch: URL
      let stdout: URL
      let stderr: URL
      let follower: LineFollower
      /// Our end of the app's stdin (a FIFO), for the next scenes.
      let input: FileHandle
      let started = Date()
      private(set) var pid: pid_t?
      private(set) var usesKit = false
      private(set) var takesScenes = false
      private var quitDone = false

      init(app: URL, first shot: CaptureShot, locale: String, settings: ScreenshotConfig.Mac) throws {
        self.app = app
        scratch = FileManager.default.temporaryDirectory
          .appendingPathComponent("dev-screenshots-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        stdout = scratch.appendingPathComponent("stdout.log")
        stderr = scratch.appendingPathComponent("stderr.log")
        follower = LineFollower(stdout)
        let fifo = scratch.appendingPathComponent("stdin")
        // Opened read-write here first, so the app's open of its stdin never waits for a writer.
        guard mkfifo(fifo.path, 0o600) == 0 else { throw CaptureError("couldn't make the app's stdin") }
        let fd = open(fifo.path, O_RDWR)
        guard fd >= 0 else { throw CaptureError("couldn't open the app's stdin") }
        input = FileHandle(fileDescriptor: fd, closeOnDealloc: true)

        let scene = shot.scene
        var environment = scene.environment
        environment[ScreenshotSignal.sceneKey] = scene.id
        environment[ScreenshotSignal.appearanceKey] = shot.appearance.rawValue
        environment[ScreenshotSignal.delayKey] = String(scene.delay)
        if let window = settings.window, window.count == 2 {
          environment[ScreenshotSignal.windowKey] = "\(window[0])x\(window[1])"
        }
        if settings.activate { environment[ScreenshotSignal.activateKey] = "1" }

        var arguments = ["-n", "-g", "--stdin", fifo.path, "--stdout", stdout.path, "--stderr", stderr.path]
        for (key, value) in environment.sorted(by: { $0.key < $1.key }) { arguments += ["--env", "\(key)=\(value)"] }
        // The system's first: an app option whose value is optional (`--new-connection [link]`) mustn't take ours.
        arguments += [app.path, "--args"] + MacCapturer.systemArguments(locale: locale, appearance: shot.appearance)
          + scene.arguments
        let launch = Shell.run("/usr/bin/open", arguments)
        guard launch.succeeded else {
          try? FileManager.default.removeItem(at: scratch)
          throw CaptureError("open failed: \(launch.trimmed)")
        }
      }

      deinit { quit() }

      /// The first scene: the app's own `ready`, or for apps without the kit, its largest window once it has been
      /// up for the scene's delay.
      func waitForFirstReady(delay: Double, timeout: TimeInterval) throws -> Int {
        var windowSeen: Date?
        var reopened = false
        while Date().timeIntervalSince(started) < timeout {
          if let ready = try readMessages(until: nil) { return ready }
          pid = pid ?? MacCapturer.newInstance(of: app, since: started)
          let waited = Date().timeIntervalSince(started)
          if let pid, !usesKit, waited > 3 {
            if let window = MacCapturer.largestWindow(of: pid) {
              let seen = windowSeen ?? Date()
              windowSeen = seen
              if Date().timeIntervalSince(seen) >= delay { return window }
            } else if !reopened, waited > 4 {
              // A background launch doesn't present SwiftUI's first window; a reopen event does, still unfocused.
              reopened = true
              Shell.run("/usr/bin/open", ["-g", app.path])
            }
          }
          try checkAlive()
          Thread.sleep(forTimeInterval: 0.2)
        }
        throw CaptureError(
          pid == nil
            ? "the app didn't start in \(Int(timeout)) s"
            : usesKit ? "the app didn't say it was ready in \(Int(timeout)) s" : "no window appeared in \(Int(timeout)) s")
      }

      /// A later scene, after `send`.
      func waitForReady(scene: String, timeout: TimeInterval) throws -> Int {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
          if let ready = try readMessages(until: scene) { return ready }
          try checkAlive()
          Thread.sleep(forTimeInterval: 0.2)
        }
        throw CaptureError("the app didn't open “\(scene)” in \(Int(timeout)) s")
      }

      func send(_ shot: CaptureShot) throws {
        let line = ScreenshotSignal.NextScene(scene: shot.scene, appearance: shot.appearance).line
        try input.write(contentsOf: Data(line.utf8))
      }

      /// Handles the app's messages; the window number once it says the scene (nil: the first) is ready.
      private func readMessages(until scene: String?) throws -> Int? {
        for line in follower.newLines() {
          guard let message = ScreenshotSignal.message(in: line) else { continue }
          let fields = Self.fields(message)
          switch message.split(separator: " ").first {
          case "hello":
            usesKit = true
            takesScenes = message.split(separator: " ").contains("scenes")
            pid = fields["pid"].flatMap { pid_t($0) } ?? pid
          case "reopen":
            Shell.run("/usr/bin/open", ["-g", app.path])
          case "activate":
            Shell.run("/usr/bin/open", [app.path])
          case "ready":
            guard fields["scene"] == scene else { continue }
            guard let window = fields["window"].flatMap({ Int($0) }) ?? pid.flatMap(MacCapturer.largestWindow) else {
              throw CaptureError("the app was ready but has no window")
            }
            return window
          default: continue
          }
        }
        return nil
      }

      private func checkAlive() throws {
        guard let pid, kill(pid, 0) != 0, errno == ESRCH else { return }
        let output = (try? String(contentsOf: stderr, encoding: .utf8)) ?? ""
        throw CaptureError("the app quit before the picture" + (output.isEmpty ? "" : ":\n" + output.suffix(800)))
      }

      /// `ready window=12 scene=a` → `["window": "12", "scene": "a"]`.
      static func fields(_ message: String) -> [String: String] {
        var fields: [String: String] = [:]
        for part in message.split(separator: " ") {
          let pair = part.split(separator: "=", maxSplits: 1)
          if pair.count == 2 { fields[String(pair[0])] = String(pair[1]) }
        }
        return fields
      }

      func quit() {
        guard !quitDone else { return }
        quitDone = true
        if let pid = pid ?? MacCapturer.newInstance(of: app, since: started) { MacCapturer.quit(pid) }
        try? input.close()
        try? FileManager.default.removeItem(at: scratch)
      }
    }

    // MARK: - Helpers

    /// The locale and appearance through the argument domain, which overrides the Mac's own settings for this
    /// process only (the appearance for apps without `Screenshots.prepare()`); and no restored windows from an
    /// earlier run.
    static func systemArguments(locale: String, appearance: ScreenshotConfig.Appearance) -> [String] {
      let language = locale.split(separator: "-").first.map(String.init) ?? locale
      return [
        "-AppleLanguages", "(\(locale), \(language))", "-AppleLocale", locale.replacingOccurrences(of: "-", with: "_"),
        "-ApplePersistenceIgnoreState", "YES",
      ] + (appearance == .dark ? ["-AppleInterfaceStyle", "Dark"] : ["-NSRequiresAquaSystemAppearance", "YES"])
    }

    /// The process `open -n` started: an instance of this bundle launched after `date`.
    static func newInstance(of app: URL, since date: Date) -> pid_t? {
      NSWorkspace.shared.runningApplications
        .filter { $0.bundleURL?.standardizedFileURL == app.standardizedFileURL }
        .filter { ($0.launchDate ?? .distantPast) >= date.addingTimeInterval(-1) }
        .max { ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast) }?
        .processIdentifier
    }

    /// The process's largest normal window on screen.
    static func largestWindow(of pid: pid_t) -> Int? {
      guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]]
      else { return nil }
      return windows
        .filter { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
        .compactMap { info -> (Int, Double)? in
          guard let number = info[kCGWindowNumber as String] as? Int,
            let bounds = info[kCGWindowBounds as String] as? [String: Double],
            let width = bounds["Width"], let height = bounds["Height"], width > 100, height > 100
          else { return nil }
          return (number, width * height)
        }
        .max { $0.1 < $1.1 }?.0
    }

    static func screencapture(window: Int, to file: URL) throws {
      try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try? FileManager.default.removeItem(at: file)
      // -o: no shadow, framing adds its own. -x: no sound.
      let result = Shell.run("/usr/sbin/screencapture", ["-x", "-o", "-l\(window)", file.path])
      guard result.succeeded, FileManager.default.fileExists(atPath: file.path) else {
        throw CaptureError(
          "screencapture failed\(result.trimmed.isEmpty ? "" : ": " + result.trimmed). It needs Screen Recording "
            + "permission for the app that runs it (System Settings ▸ Privacy & Security).")
      }
    }

    /// Asks the instance to quit, then makes it.
    static func quit(_ pid: pid_t) {
      let app = NSRunningApplication(processIdentifier: pid)
      app?.terminate()
      for _ in 0..<25 {
        if kill(pid, 0) != 0 { return }
        Thread.sleep(forTimeInterval: 0.2)
      }
      app?.forceTerminate()
      kill(pid, SIGKILL)
    }
  }
#endif
