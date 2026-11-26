#if os(macOS)
  import CoreGraphics
  import DevScreenshots
  import Foundation
  import ImageIO

  /// Takes pictures of an iOS app in a simulator with `simctl`: installs it, sets the appearance and a clean status
  /// bar, launches it with the scene's arguments and takes the whole screen once the app says it is ready (or, for
  /// apps without `Screenshots.prepare()`, a moment after launch plus the scene's delay).
  struct SimulatorCapturer {
    var device: Device
    var app: URL
    var bundleID: String
    var settings: ScreenshotConfig.IOS
    var log: (String) -> Void

    var timeout: TimeInterval = 60

    struct Device: Hashable {
      var udid: String
      var name: String
      var platform: ScreenshotConfig.Platform
      var booted: Bool
    }

    /// A simulator by name or UDID; with several of one name, the booted one, else the newest runtime's.
    static func find(_ nameOrUDID: String) throws -> Device {
      let result = Shell.run("xcrun", ["simctl", "list", "devices", "available", "-j"])
      guard result.succeeded, let json = try? JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any],
        let runtimes = json["devices"] as? [String: [[String: Any]]]
      else { throw CaptureError("simctl couldn't list the simulators:\n" + result.tail()) }
      var matches: [(runtime: String, device: Device)] = []
      for (runtime, devices) in runtimes where runtime.contains("iOS") {
        for info in devices {
          guard let udid = info["udid"] as? String, let name = info["name"] as? String,
            udid == nameOrUDID || name == nameOrUDID
          else { continue }
          let type = info["deviceTypeIdentifier"] as? String ?? name
          matches.append(
            (runtime, Device(
              udid: udid, name: name, platform: type.localizedCaseInsensitiveContains("ipad") ? .ipad : .iphone,
              booted: info["state"] as? String == "Booted")))
        }
      }
      guard let best = matches.max(by: { a, b in
        a.device.booted != b.device.booted
          ? !a.device.booted : a.runtime.compare(b.runtime, options: .numeric) == .orderedAscending
      }) else { throw CaptureError("there is no simulator called “\(nameOrUDID)” (xcrun simctl list devices)") }
      return best.device
    }

    /// Boots the device, installs the app and sets the status bar; true when this call booted it.
    func prepare() throws -> Bool {
      var booted = false
      if !device.booted {
        log("Booting \(device.name)…")
        Shell.run("xcrun", ["simctl", "boot", device.udid])
        booted = true
      }
      let ready = Shell.run("xcrun", ["simctl", "bootstatus", device.udid, "-b"])
      guard ready.succeeded else { throw CaptureError("\(device.name) didn't boot:\n" + ready.tail()) }
      let install = Shell.run("xcrun", ["simctl", "install", device.udid, app.path])
      guard install.succeeded else { throw CaptureError("installing on \(device.name) failed:\n" + install.tail()) }
      if settings.cleanStatusBar {
        Shell.run(
          "xcrun",
          [
            "simctl", "status_bar", device.udid, "override", "--time", "9:41", "--dataNetwork", "wifi",
            "--wifiMode", "active", "--wifiBars", "3", "--cellularMode", "active", "--cellularBars", "4",
            "--batteryState", "charged", "--batteryLevel", "100",
          ])
      }
      return booted
    }

    func finish(shutDown: Bool) {
      if settings.cleanStatusBar { Shell.run("xcrun", ["simctl", "status_bar", device.udid, "clear"]) }
      if shutDown { Shell.run("xcrun", ["simctl", "shutdown", device.udid]) }
    }

    /// Takes the shots in order, in as few launches as the app allows (a launch per appearance change for apps
    /// without a scene handler, since the simulator's appearance is set before launch).
    func capture(_ shots: [CaptureShot], locale: String, report: (CaptureShot, Error?) -> Void) {
      var instance: Instance?
      defer { instance?.quit() }
      for shot in shots {
        do {
          if let running = instance, running.takesScenes, !shot.scene.relaunch {
            try running.send(shot)
            try running.waitForReady(scene: shot.scene.id, timeout: timeout)
          } else {
            instance?.quit()
            instance = nil
            Shell.run("xcrun", ["simctl", "ui", device.udid, "appearance", shot.appearance.rawValue])
            let launched = try Instance(capturer: self, first: shot, locale: locale)
            instance = launched
            try launched.waitForFirstReady(delay: shot.scene.delay, timeout: timeout)
            // A cold launch can say it's ready before its first frames reach the screen (a blank window).
            try steadyScreenshot(to: shot.file, screen: launched.screen)
            report(shot, nil)
            continue
          }
          try screenshot(to: shot.file, screen: instance?.screen)
          report(shot, nil)
        } catch {
          report(shot, error)
          instance?.quit()
          instance = nil
        }
      }
    }

    /// `simctl launch --console`: it runs as long as the app does. The app's stdin is `/dev/null`, so the next scenes
    /// go through a FIFO in the device's temporary folder, named by `DEV_SCREENSHOT_INPUT`.
    final class Instance {
      let process = Process()
      /// Our end of the app's input FIFO.
      let input: FileHandle
      let fifo: URL
      let follower: LineFollower
      let scratch: URL
      let started = Date()
      let udid: String
      let bundleID: String
      private(set) var usesKit = false
      private(set) var takesScenes = false
      /// The pixels of the screen the app said its window is on, in its last `ready`.
      private(set) var screen: Display.Size?
      private var quitDone = false

      init(capturer: SimulatorCapturer, first shot: CaptureShot, locale: String) throws {
        udid = capturer.device.udid
        bundleID = capturer.bundleID
        scratch = FileManager.default.temporaryDirectory
          .appendingPathComponent("dev-screenshots-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let stdout = scratch.appendingPathComponent("stdout.log")
        follower = LineFollower(stdout)

        // In the device's temporary folder, which its apps can read.
        let tmp = Shell.run("xcrun", ["simctl", "getenv", udid, "TMPDIR"])
        guard tmp.succeeded, !tmp.trimmed.isEmpty else {
          try? FileManager.default.removeItem(at: scratch)
          throw CaptureError("simctl couldn't find \(capturer.device.name)'s temporary folder:\n" + tmp.tail())
        }
        fifo = URL(fileURLWithPath: tmp.trimmed, isDirectory: true)
          .appendingPathComponent("dev-screenshots-\(UUID().uuidString)")
        // Opened read-write here first, so the app's open never waits for a writer.
        let fd = mkfifo(fifo.path, 0o600) == 0 ? open(fifo.path, O_RDWR) : -1
        guard fd >= 0 else {
          try? FileManager.default.removeItem(at: scratch)
          try? FileManager.default.removeItem(at: fifo)
          throw CaptureError("couldn't make the app's input at \(fifo.path)")
        }
        input = FileHandle(fileDescriptor: fd, closeOnDealloc: true)

        // simctl passes SIMCTL_CHILD_X to the app as X.
        let scene = shot.scene
        var environment = scene.environment
        environment[ScreenshotSignal.inputKey] = fifo.path
        environment[ScreenshotSignal.sceneKey] = scene.id
        environment[ScreenshotSignal.appearanceKey] = shot.appearance.rawValue
        environment[ScreenshotSignal.delayKey] = String(scene.delay)
        process.environment = ProcessInfo.processInfo.environment.merging(
          environment.map { ("SIMCTL_CHILD_" + $0.key, $0.value) }, uniquingKeysWith: { $1 })

        let language = locale.split(separator: "-").first.map(String.init) ?? locale
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments =
          ["simctl", "launch", "--console", "--terminate-running-process", udid, bundleID] + [
            "-AppleLanguages", "(\(locale), \(language))", "-AppleLocale",
            locale.replacingOccurrences(of: "-", with: "_"),
          ] + scene.arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = try FileHandle(forWritingTo: stdout)
        process.standardError = FileHandle.nullDevice
        do {
          try process.run()
        } catch {
          try? FileManager.default.removeItem(at: scratch)
          try? FileManager.default.removeItem(at: fifo)
          throw CaptureError("simctl launch failed: \(error.localizedDescription)")
        }
      }

      deinit { quit() }

      /// The first scene: the app's own `ready`, or for apps without the kit, a moment plus the scene's delay.
      func waitForFirstReady(delay: Double, timeout: TimeInterval) throws {
        while Date().timeIntervalSince(started) < timeout {
          if readMessages(until: nil) { return }
          if !usesKit, Date().timeIntervalSince(started) > 3 + delay { return }
          guard process.isRunning else { throw CaptureError("the app quit before the picture") }
          Thread.sleep(forTimeInterval: 0.2)
        }
        throw CaptureError("the app didn't say it was ready in \(Int(timeout)) s")
      }

      func waitForReady(scene: String, timeout: TimeInterval) throws {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
          if readMessages(until: scene) { return }
          guard process.isRunning else { throw CaptureError("the app quit before the picture") }
          Thread.sleep(forTimeInterval: 0.2)
        }
        throw CaptureError("the app didn't open “\(scene)” in \(Int(timeout)) s")
      }

      func send(_ shot: CaptureShot) throws {
        let line = ScreenshotSignal.NextScene(scene: shot.scene, appearance: shot.appearance).line
        try input.write(contentsOf: Data(line.utf8))
      }

      private func readMessages(until scene: String?) -> Bool {
        for line in follower.newLines() {
          guard let message = ScreenshotSignal.message(in: line) else { continue }
          let words = message.split(separator: " ")
          if words.first == "hello" {
            usesKit = true
            takesScenes = words.contains("scenes")
          } else if words.first == "ready" {
            if let said = words.first(where: { $0.hasPrefix("screen=") }) {
              screen = Display.Size(String(said.dropFirst("screen=".count)))
            }
            let named = words.first { $0.hasPrefix("scene=") }.map { String($0.dropFirst("scene=".count)) }
            if named == scene { return true }
          }
        }
        return false
      }

      func quit() {
        guard !quitDone else { return }
        quitDone = true
        Shell.run("xcrun", ["simctl", "terminate", udid, bundleID])
        try? input.close()
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        try? FileManager.default.removeItem(at: scratch)
        try? FileManager.default.removeItem(at: fifo)
      }
    }

    /// Shoots until two pictures in a row are the same (at most `steadyTries`, `steadyInterval` apart), so a launch
    /// still drawing its first frames isn't what's kept.
    private func steadyScreenshot(to file: URL, screen: Display.Size?) throws {
      var previous: Data?
      Thread.sleep(forTimeInterval: Self.firstFrameSettle)
      for _ in 0..<Self.steadyTries {
        try screenshot(to: file, screen: screen)
        let picture = try Data(contentsOf: file)
        if picture == previous { return }
        previous = picture
        Thread.sleep(forTimeInterval: Self.steadyInterval)
      }
    }

    /// A launch can hold a blank window for a while (Vault's iPhone list), which two quick pictures agree on.
    static let firstFrameSettle: TimeInterval = 1.5
    static let steadyTries = 8
    static let steadyInterval: TimeInterval = 0.6

    /// The whole screen. A device with two (an iPhone Duo: the outer screen and the unfolded one) makes simctl ask
    /// which: the one the app said its window is on (`screen`); for an app without the kit, the one that is lit (the
    /// other is black), the outer one first.
    private func screenshot(to file: URL, screen: Display.Size?) throws {
      try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try? FileManager.default.removeItem(at: file)
      func shoot(_ display: Display?) -> Shell.Result {
        try? FileManager.default.removeItem(at: file)
        return Shell.run(
          "xcrun",
          ["simctl", "io", device.udid, "screenshot", "--type=png"] + (display.map { ["--display=\($0.id)"] } ?? [])
            + [file.path])
      }
      var result = shoot(nil)
      if !result.succeeded {
        let displays = Display.list(in: result.output)
        if let screen, let display = displays.first(where: { $0.size.matches(screen) }) {
          result = shoot(display)
        } else {
          let outerFirst = displays.filter(\.isPrimary) + displays.filter { !$0.isPrimary }
          for display in outerFirst {
            result = shoot(display)
            if result.succeeded, !Display.isBlack(file) { break }
          }
          // Every screen black (the app's own black screen): the outer one.
          if result.succeeded, Display.isBlack(file), let outer = outerFirst.first { result = shoot(outer) }
        }
      }
      guard result.succeeded else { throw CaptureError("simctl screenshot failed:\n" + result.tail()) }
    }

    /// One of a simulator's screens, as simctl lists them when it can't choose:
    /// `--display=3  LCD-1 (primary-1) 2007x2853`.
    struct Display: Equatable {
      var id: String
      var isPrimary: Bool
      var size: Size

      struct Size: Equatable {
        var width: Int
        var height: Int

        init(width: Int, height: Int) {
          self.width = width
          self.height = height
        }

        /// `2007x2853`.
        init?(_ text: String) {
          let parts = text.split(separator: "x").compactMap { Int($0) }
          guard parts.count == 2 else { return nil }
          self.init(width: parts[0], height: parts[1])
        }

        /// The same screen whichever way it is held.
        func matches(_ other: Size) -> Bool {
          (width == other.width && height == other.height) || (width == other.height && height == other.width)
        }
      }

      static func list(in output: String) -> [Display] {
        output.split(separator: "\n").compactMap { line in
          let words = line.split(separator: " ")
          guard let first = words.first, first.hasPrefix("--display="), let last = words.last,
            let size = Size(String(last))
          else { return nil }
          return Display(
            id: String(first.dropFirst("--display=".count)), isPrimary: words.contains("(primary)"), size: size)
        }
      }

      /// Whether the picture is black all over: a screen that isn't lit. A lit one has at least its status bar.
      static func isBlack(_ file: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return false }
        let side = 64
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard
          let context = CGContext(
            data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return false }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        return !pixels.enumerated().contains { $0.offset % 4 != 3 && $0.element > 12 }
      }
    }
  }
#endif
