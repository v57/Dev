#if os(macOS)
  import AppKit
  import DevScreenshots
  import Foundation

  /// Takes a locale's pictures of a Mac app: launches a new instance in the background (`open -n -g`, so nobody's
  /// typing lands in it), waits until the scene is up and captures its window with `screencapture -l`. It stays in
  /// the background; ComponentKit apps draw the focused look anyway (`-KitAppearsActive YES`). With `mac.activate`
  /// the app is brought to the front once and every picture is taken while it is focused: the capture pauses while
  /// the reader is in another app, and a picture focus left during is taken again.
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
          let running: Instance
          if let instance, instance.takesScenes, !shot.scene.relaunch {
            running = instance
            try running.send(shot)
            window = try running.waitForReady(scene: shot.scene.id, timeout: timeout)
          } else {
            instance?.quit()
            instance = nil
            running = try Instance(app: app, first: shot, locale: locale, settings: settings, log: log)
            instance = running
            window = try running.waitForFirstReady(delay: shot.scene.delay, timeout: timeout)
          }
          try Self.screencapture(window: window, to: shot.file)
          // The reader switched away while the picture was taken: again, once they're back.
          while try running.lostFocusSinceReady() {
            try running.waitForFocus()
            try Self.screencapture(window: window, to: shot.file)
          }
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
      let activates: Bool
      let log: (String) -> Void
      private(set) var pid: pid_t?
      private(set) var usesKit = false
      private(set) var takesScenes = false
      /// What the app last said about its focus; apps without the kit never say.
      private(set) var focused = true
      /// The app lost focus since its last `ready`.
      private var lostFocus = false
      /// `ready` lines not waited for yet: the scene (nil: the first) and the window.
      private var readies: [(scene: String?, window: Int?)] = []
      private var quitDone = false

      init(
        app: URL, first shot: CaptureShot, locale: String, settings: ScreenshotConfig.Mac,
        log: @escaping (String) -> Void
      ) throws {
        self.app = app
        self.activates = settings.activate
        self.log = log
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
        var counted: TimeInterval = 0
        while counted < timeout {
          if let ready = try takeReady(scene: nil) { return ready }
          pid = pid ?? MacCapturer.newInstance(of: app, since: started)
          let waited = Date().timeIntervalSince(started)
          if let pid, !usesKit, waited > 3 {
            if let window = MacCapturer.largestWindow(of: pid) {
              let seen = windowSeen ?? Date()
              windowSeen = seen
              if Date().timeIntervalSince(seen) >= delay {
                if activates {
                  // Without the kit nothing says when the app is focused: bring it forward and let it redraw.
                  Shell.run("/usr/bin/open", [app.path])
                  Thread.sleep(forTimeInterval: 1)
                }
                return window
              }
            } else if !reopened, waited > 4 {
              // A background launch doesn't present SwiftUI's first window; a reopen event does, still unfocused.
              reopened = true
              Shell.run("/usr/bin/open", ["-g", app.path])
            }
          }
          try checkAlive()
          Thread.sleep(forTimeInterval: 0.2)
          // Time the reader spends in another app doesn't count.
          if focused { counted += 0.2 }
        }
        throw CaptureError(
          pid == nil
            ? "the app didn't start in \(Int(timeout)) s"
            : usesKit ? "the app didn't say it was ready in \(Int(timeout)) s" : "no window appeared in \(Int(timeout)) s")
      }

      /// A later scene, after `send`.
      func waitForReady(scene: String, timeout: TimeInterval) throws -> Int {
        var counted: TimeInterval = 0
        while counted < timeout {
          if let ready = try takeReady(scene: scene) { return ready }
          try checkAlive()
          Thread.sleep(forTimeInterval: 0.2)
          if focused { counted += 0.2 }
        }
        throw CaptureError("the app didn't open “\(scene)” in \(Int(timeout)) s")
      }

      /// Whether the app said it lost focus since its `ready`, so the picture may show an inactive window.
      func lostFocusSinceReady() throws -> Bool {
        try readMessages()
        defer { lostFocus = false }
        return lostFocus
      }

      /// Until the app says it is focused again, then a moment for its windows to redraw. No timeout: the reader
      /// decides when to come back (or stops the capture).
      func waitForFocus() throws {
        try readMessages()
        guard !focused else { return }
        while !focused {
          try checkAlive()
          Thread.sleep(forTimeInterval: 0.2)
          try readMessages()
        }
        Thread.sleep(forTimeInterval: 0.6)
        try readMessages()
      }

      func send(_ shot: CaptureShot) throws {
        let line = ScreenshotSignal.NextScene(scene: shot.scene, appearance: shot.appearance).line
        try input.write(contentsOf: Data(line.utf8))
      }

      /// The window of the scene's (nil: the first one's) `ready`, once the app has said it.
      private func takeReady(scene: String?) throws -> Int? {
        try readMessages()
        guard let index = readies.firstIndex(where: { $0.scene == scene }) else { return nil }
        let ready = readies.remove(at: index)
        guard let window = ready.window ?? pid.flatMap(MacCapturer.largestWindow) else {
          throw CaptureError("the app was ready but has no window")
        }
        return window
      }

      /// Handles the app's new messages.
      private func readMessages() throws {
        for line in follower.newLines() {
          guard let message = ScreenshotSignal.message(in: line) else { continue }
          let fields = Self.fields(message)
          let words = message.split(separator: " ")
          switch words.first {
          case "hello":
            usesKit = true
            takesScenes = message.split(separator: " ").contains("scenes")
            pid = fields["pid"].flatMap { pid_t($0) } ?? pid
          case "reopen":
            Shell.run("/usr/bin/open", ["-g", app.path])
          case "activate":
            Shell.run("/usr/bin/open", [app.path])
          case "focus":
            let active = words.dropFirst().first == "active"
            guard active != focused else { continue }
            focused = active
            if active {
              log("  Going on: \(app.deletingPathExtension().lastPathComponent) is focused again.")
            } else {
              lostFocus = true
              log("  Paused: switch back to \(app.deletingPathExtension().lastPathComponent) (⌘-Tab or the Dock) to go on.")
            }
          case "ready":
            lostFocus = false
            readies.append((fields["scene"], fields["window"].flatMap { Int($0) }))
          default: continue
          }
        }
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
        // ComponentKit draws the focused window's look (accent selections) though the app stays in the background.
        "-KitAppearsActive", "YES",
        // `Light`, not `NSRequiresAquaSystemAppearance`: that opts the app out of dark mode for the whole launch, so
        // a later scene switched to dark in place keeps light text views.
        "-AppleInterfaceStyle", appearance == .dark ? "Dark" : "Light",
      ]
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
