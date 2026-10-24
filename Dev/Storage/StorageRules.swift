//
//  StorageRules.swift
//  Dev
//

import Foundation

/// The known places developer tools keep their bulk, category by category.
/// A path that does not exist on this Mac is dropped by `add`, so the lists can
/// name every tool's default location without checking first.
nonisolated extension StorageDiscovery {
  // MARK: Swift & Xcode

  mutating func addSwift() {
    let xcode = "Library/Developer/Xcode"
    eachChild(.xcode, "DerivedData", of: "\(xcode)/DerivedData", .rebuildable,
      detail: "Xcode build products and index", include: { $0 != "ModuleCache.noindex" },
      title: StorageNames.derivedData)
    folder(.xcode, "DerivedData", "Module cache", "\(xcode)/DerivedData/ModuleCache.noindex", .cache)

    addSimulators()

    for platform in ["iOS", "watchOS", "tvOS", "visionOS", "macOS"] {
      eachChild(.xcode, "Device Support", of: "\(xcode)/\(platform) DeviceSupport", .cache,
        detail: "\(platform) symbols, copied again when the device next connects")
    }
    eachChild(.xcode, "Archives", of: "\(xcode)/Archives", .data,
      detail: "Xcode archives — keep the ones whose dSYMs you still need")

    folder(.xcode, "Xcode Caches", "Xcode cache", "Library/Caches/com.apple.dt.Xcode", .cache)
    folder(.xcode, "Xcode Caches", "SwiftUI previews", "\(xcode)/UserData/Previews", .cache)
    folder(.xcode, "Xcode Caches", "Documentation cache", "\(xcode)/DocumentationCache", .cache)
    folder(.xcode, "Xcode Caches", "Built products", "\(xcode)/Products", .rebuildable)
    folder(.xcode, "Xcode Caches", "Device logs", "\(xcode)/DeviceLogs", .cache)
    folder(.xcode, "Xcode Caches", "Xcode logs", "Library/Logs/Xcode", .cache)
    folder(.xcode, "Xcode Caches", "Simulator caches", "Library/Developer/CoreSimulator/Caches", .cache)
    folder(.xcode, "Xcode Caches", "Simulator logs", "Library/Logs/CoreSimulator", .cache)
    folder(.xcode, "Xcode Caches", "Test devices", "Library/Developer/XCTestDevices", .rebuildable)
    folder(.xcode, "Xcode Caches", "Playground devices", "Library/Developer/XCPGDevices", .rebuildable)

    folder(.xcode, "Swift Package Manager", "Package cache", "Library/Caches/org.swift.swiftpm", .cache)
    eachChild(.xcode, "Swift Package Manager", of: "Library/org.swift.swiftpm/swift-sdks", .rebuildable,
      detail: "Swift SDK (cross-compilation)")
    eachChild(.xcode, "Swift Package Manager", of: ".swiftpm/swift-sdks", .rebuildable,
      detail: "Swift SDK (cross-compilation)")
    folder(.xcode, "Swift Package Manager", "CocoaPods cache", "Library/Caches/CocoaPods", .cache)
    folder(.xcode, "Swift Package Manager", "Carthage cache", "Library/Caches/org.carthage.CarthageKit", .cache)

    eachChild(.xcode, "Toolchains", of: "Library/Developer/Toolchains", .rebuildable,
      detail: "Swift toolchain")
    eachChild(.xcode, "Toolchains", of: ".swiftly/toolchains", .rebuildable, detail: "swiftly toolchain")
  }

  /// Simulators through simctl, which owns their bookkeeping. A runtime and
  /// the simulators on it are one uninstall: picking the runtime picks them,
  /// and they are deleted before it, so none is left behind unavailable. A
  /// simulator picked on its own is erased (it stays in Xcode's list).
  private mutating func addSimulators() {
    let xcrun = "/usr/bin/xcrun"
    let devicesRoot = h("Library/Developer/CoreSimulator/Devices")

    var runtimes: [SimRuntime] = []
    let listedRuntimes = ScanShell.run(xcrun, arguments: ["simctl", "runtime", "list", "-j"],
      currentDirectory: nil, timeout: 30)
    if listedRuntimes.succeeded, let data = listedRuntimes.stdout.data(using: .utf8),
      let list = try? JSONDecoder.storage.decode([String: SimRuntime].self, from: data) {
      runtimes = list.values.sorted { $0.version ?? "" < $1.version ?? "" }
    }
    // A runtime owns its simulators only while it is the one build of its
    // version: with two installed, deleting one moves them to the other.
    let builds = Dictionary(grouping: runtimes, by: \.platformVersion)
    func owner(of runtime: String) -> SimRuntime? {
      guard let matching = builds[runtime], matching.count == 1 else { return nil }
      return matching[0]
    }

    let listed = ScanShell.run(xcrun, arguments: ["simctl", "list", "devices", "-j"],
      currentDirectory: nil, timeout: 30)
    var simulatorCounts: [String: Int] = [:]
    var bootedRuntimes = Set<String>()
    var unavailable: [String] = []
    var shutDown: [String] = []
    if listed.succeeded, let data = listed.stdout.data(using: .utf8),
      let list = try? JSONDecoder.storage.decode(SimDeviceList.self, from: data) {
      for (runtime, devices) in list.devices.sorted(by: { $0.key < $1.key }) {
        let parent = owner(of: runtime).map { "runtime:" + $0.identifier }
        for device in devices {
          let path = devicesRoot + "/" + device.udid
          guard device.isAvailable ?? true else {
            unavailable.append(path)
            continue
          }
          simulatorCounts[runtime, default: 0] += 1
          let booted = device.state == "Booted"
          if booted { bootedRuntimes.insert(runtime) } else { shutDown.append(path) }
          let detail = [StorageNames.simRuntime(runtime), device.state,
            StorageNames.relative(device.lastUsedAt).map { "used \($0)" }]
            .compactMap { $0 }.joined(separator: " · ")
          var item = StorageItem(
            id: "sim:" + device.udid, category: .xcode, group: "Simulators",
            title: device.name, detail: detail, paths: [path], safety: .data,
            cleanup: booted
              ? .revealOnly(reason: "Booted — shut it down to erase it")
              : .command(executable: xcrun, arguments: ["simctl", "erase", device.udid],
                verb: "Erase content"))
          if let parent {
            // Even an empty one is listed: its runtime cannot go without it.
            item.minBytes = 0
            item.parent = parent
            item.cleanupWithParent = .command(executable: xcrun, arguments: ["simctl", "delete", device.udid],
              verb: "Delete")
          }
          add(item)
        }
      }
    }
    // Every device renders the same wallpapers and downloads the same system
    // assets; a booted one is writing to them, so it is left out.
    if !shutDown.isEmpty {
      add(StorageItem(
        id: "sim:clones", category: .xcode, group: "Simulators",
        title: "Identical files in simulators", paths: [], safety: .lossless,
        cleanup: .cloneDuplicates(roots: shutDown), reportedSize: true))
    }
    if !unavailable.isEmpty {
      add(StorageItem(
        id: "sim:unavailable", category: .xcode, group: "Simulators",
        title: "Unavailable simulators",
        detail: "\(unavailable.count) devices whose runtime is no longer installed",
        paths: unavailable, safety: .rebuildable,
        cleanup: .command(executable: xcrun, arguments: ["simctl", "delete", "unavailable"],
          verb: "Delete")))
    }

    for runtime in runtimes {
      let key = runtime.platformVersion
      let name = StorageNames.simRuntime(key)
      let owns = owner(of: key) != nil
      let used = simulatorCounts[key] ?? 0
      let count = owns ? used : 0
      let simulators = used == 0 ? "no simulator uses it" : owns ? "\(used) simulator\(used == 1 ? "" : "s")" : nil
      let detail = [runtime.build, simulators, StorageNames.relative(runtime.lastUsedAt).map { "used \($0)" }]
        .compactMap { $0 }.joined(separator: " · ")
      var item = StorageItem(
        id: "runtime:" + runtime.identifier, category: .xcode, group: "Simulators",
        title: "\(name) runtime", detail: detail, paths: [runtime.path ?? runtime.mountPath ?? ""],
        safety: .rebuildable,
        cleanup: runtime.deletable ?? false
          ? .command(executable: xcrun, arguments: ["simctl", "runtime", "delete", runtime.identifier],
            verb: count > 0 ? "Delete with simulators" : "Delete")
          : .revealOnly(reason: "simctl reports this runtime as not deletable"),
        bytes: runtime.sizeBytes ?? 0, reportedSize: true)
      if owns, bootedRuntimes.contains(key) {
        item.lockReason = "A simulator on it is booted"
      }
      add(item)
    }
  }

  /// `roots` without the data folders of simulators booted now: checked again
  /// right before cloning, since a device may have booted after the scan.
  static func excludingBootedSimulators(_ roots: [String]) -> [String] {
    let listed = ScanShell.run("/usr/bin/xcrun", arguments: ["simctl", "list", "devices", "booted", "-j"],
      currentDirectory: nil, timeout: 30)
    guard listed.succeeded, let data = listed.stdout.data(using: .utf8),
      let list = try? JSONDecoder.storage.decode(SimDeviceList.self, from: data)
    else { return [] }
    let booted = Set(list.devices.values.flatMap { $0 }.filter { $0.state == "Booted" }.map(\.udid))
    return roots.filter { !booted.contains(($0 as NSString).lastPathComponent) }
  }

  // MARK: Android & Gradle

  mutating func addAndroid() {
    addEmulators()

    let environment = ProcessInfo.processInfo.environment
    let sdk = environment["ANDROID_HOME"] ?? environment["ANDROID_SDK_ROOT"] ?? h("Library/Android/sdk")
    for api in children(of: sdk + "/system-images") {
      let apiName = (api as NSString).lastPathComponent
      eachChild(.android, "Android SDK", of: api, .rebuildable, detail: "System image",
        title: { "\(apiName) · \($0)" })
    }
    eachChild(.android, "Android SDK", of: sdk + "/ndk", .rebuildable, title: { "NDK \($0)" })
    eachChild(.android, "Android SDK", of: sdk + "/build-tools", .rebuildable, title: { "Build tools \($0)" })
    eachChild(.android, "Android SDK", of: sdk + "/platforms", .rebuildable, title: { "Platform \($0)" })
    eachChild(.android, "Android SDK", of: sdk + "/sources", .rebuildable, title: { "Sources \($0)" })
    eachChild(.android, "Android SDK", of: sdk + "/cmake", .rebuildable, title: { "CMake \($0)" })
    folder(.android, "Android SDK", "Emulator", sdk + "/emulator", .rebuildable)
    folder(.android, "Android SDK", "Platform tools", sdk + "/platform-tools", .rebuildable)
    folder(.android, "Android SDK", "SDK cache", ".android/cache", .cache)
    folder(.android, "Android SDK", "Build cache", ".android/build-cache", .cache)

    let gradleNames: [String: String] = [
      "build-cache-1": "Build cache", "modules-2": "Dependency cache",
      "transforms-3": "Transforms", "transforms-4": "Transforms", "jars-9": "Jar cache",
    ]
    eachChild(.android, "Gradle", of: ".gradle/caches", .cache,
      title: { name in
        gradleNames[name] ?? (name.first?.isNumber == true ? "Gradle \(name) caches" : name)
      })
    eachChild(.android, "Gradle", of: ".gradle/wrapper/dists", .rebuildable,
      detail: "Gradle distribution", title: { $0.replacingOccurrences(of: "gradle-", with: "Gradle ") })
    folder(.android, "Gradle", "Daemon logs", ".gradle/daemon", .cache)
    folder(.android, "Gradle", "Native libraries", ".gradle/native", .cache)
    eachChild(.android, "Gradle", of: ".gradle/jdks", .rebuildable, detail: "Gradle-provisioned JDK")
    folder(.android, "Gradle", "Maven repository", ".m2/repository", .cache)
    folder(.android, "Gradle", "Kotlin/Native", ".konan", .cache)

    eachChild(.android, "JDKs", of: "Library/Java/JavaVirtualMachines", .rebuildable)
    eachChild(.android, "JDKs", of: ".sdkman/candidates/java", .rebuildable)
    eachChild(.android, "JDKs", of: ".jdks", .rebuildable)
    eachChild(.android, "JDKs", of: "/Library/Java/JavaVirtualMachines", .rebuildable,
      cleanup: .revealOnly(reason: "Installed for all users — remove it with administrator rights"))

    for (parent, safety, detail) in [
      ("Library/Caches/Google", StorageSafety.cache, "Caches"),
      ("Library/Logs/Google", .cache, "Logs"),
      ("Library/Application Support/Google", .data, "Settings and plugins"),
    ] {
      eachChild(.android, "Android Studio", of: parent, safety, detail: detail,
        include: { $0.hasPrefix("AndroidStudio") || $0.hasPrefix("IntelliJ") })
    }
  }

  /// One item per AVD: the `.avd` folder plus the `.ini` that points at it.
  private mutating func addEmulators() {
    let avdRoot = h(".android/avd")
    for path in children(of: avdRoot) where path.hasSuffix(".avd") {
      let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
      let config = Self.iniValues(at: path + "/config.ini")
      let image = config["image.sysdir.1"]?.split(separator: "/").dropFirst().prefix(2)
        .joined(separator: " · ")
      // Lock files outlive a crashed emulator, so ask for the process itself.
      let running = ScanShell.run("/usr/bin/pgrep", arguments: ["-f", "qemu-system.*-avd \(name)"],
        currentDirectory: nil, timeout: 5).succeeded
      let detail = [config["hw.device.name"], image, running ? "Running" : nil]
        .compactMap { $0 }.joined(separator: " · ")
      add(StorageItem(
        id: path, category: .android, group: "Emulators",
        title: name.replacingOccurrences(of: "_", with: " "), detail: detail,
        paths: [path, avdRoot + "/" + name + ".ini"], safety: .data,
        cleanup: running ? .revealOnly(reason: "Running — close the emulator first") : .trash))
    }
  }

  /// npm's global prefixes beyond the defaults: `NPM_CONFIG_PREFIX` and the
  /// `prefix=` line of `~/.npmrc`, where people move `npm install -g`.
  static func npmPrefixes(home: String) -> [String] {
    var prefixes: [String] = []
    if let prefix = ProcessInfo.processInfo.environment["NPM_CONFIG_PREFIX"] { prefixes.append(prefix) }
    if let prefix = iniValues(at: home + "/.npmrc")["prefix"] { prefixes.append(prefix) }
    prefixes.append(home + "/.local")
    var seen = Set<String>()
    return prefixes
      .map { ($0 as NSString).expandingTildeInPath }
      .filter { seen.insert($0).inserted }
  }

  static func iniValues(at path: String) -> [String: String] {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
    var values: [String: String] = [:]
    for line in text.split(separator: "\n") {
      let pair = line.split(separator: "=", maxSplits: 1)
      guard pair.count == 2 else { continue }
      values[pair[0].trimmingCharacters(in: .whitespaces)] = pair[1].trimmingCharacters(in: .whitespaces)
    }
    return values
  }

  // MARK: Virtual machines

  mutating func addVirtualMachines() {
    eachChild(.virtualMachines, "UTM", of: "Library/Containers/com.utmapp.UTM/Data/Documents", .data,
      detail: "UTM virtual machine", include: { $0.hasSuffix(".utm") },
      title: { ($0 as NSString).deletingPathExtension })
    eachChild(.virtualMachines, "Parallels", of: "Parallels", .data, detail: "Parallels virtual machine",
      include: { $0.hasSuffix(".pvm") }, title: { ($0 as NSString).deletingPathExtension })
    eachChild(.virtualMachines, "VMware", of: "Virtual Machines.localized", .data,
      detail: "VMware virtual machine", title: { ($0 as NSString).deletingPathExtension })
    eachChild(.virtualMachines, "VirtualBox", of: "VirtualBox VMs", .data, detail: "VirtualBox virtual machine")

    folder(.virtualMachines, "Containers", "Docker Desktop disk",
      "Library/Containers/com.docker.docker/Data/vms", .data,
      detail: "Every image, container and volume — Docker recreates an empty one")
    folder(.virtualMachines, "Containers", "OrbStack data",
      "Library/Group Containers/HUAQ24HBR6.dev.orbstack/data", .data)
    folder(.virtualMachines, "Containers", "OrbStack", ".orbstack", .data)
    folder(.virtualMachines, "Containers", "Colima", ".colima", .data)
    folder(.virtualMachines, "Containers", "Lima", ".lima", .data)
    folder(.virtualMachines, "Containers", "Podman machines", ".local/share/containers/podman/machine", .data)
    eachChild(.virtualMachines, "Tart", of: ".tart/vms", .data, detail: "Tart virtual machine")
    folder(.virtualMachines, "Tart", "Tart image cache", ".tart/cache", .cache)
    eachChild(.virtualMachines, "Vagrant", of: ".vagrant.d/boxes", .rebuildable, detail: "Vagrant box")
    addDockerPrune()
    addDiskCompaction()
  }

  /// What `docker system prune -af` would free: stopped containers, unused
  /// images and the build cache (never volumes). Only while Docker answers.
  private mutating func addDockerPrune() {
    let docker = ["/opt/homebrew/bin/docker", "/usr/local/bin/docker"].first { fileManager.isExecutableFile(atPath: $0) }
    guard let docker else { return }
    let result = ScanShell.run(docker, arguments: ["system", "df", "--format", "{{json .}}"], currentDirectory: nil, timeout: 20)
    guard result.succeeded else { return }
    var bytes: Int64 = 0
    for line in result.stdout.split(separator: "\n") {
      guard let data = line.data(using: .utf8),
            let row = try? JSONSerialization.jsonObject(with: data) as? [String: String],
            row["Type"] != "Local Volumes",
            let reclaimable = row["Reclaimable"]?.split(separator: " ").first
      else { continue }
      bytes += Self.dockerBytes(String(reclaimable))
    }
    guard bytes > 50_000_000 else { return }
    add(StorageItem(
      id: "docker:prune", category: .virtualMachines, group: "Containers",
      title: "Unused Docker images and build cache",
      detail: "Images pull and layers build again; volumes stay", paths: [],
      safety: .rebuildable,
      cleanup: .command(executable: docker, arguments: ["system", "prune", "-af"], verb: "Prune"),
      bytes: bytes, reportedSize: true))
  }

  /// `1.626GB`, `180.2kB`, `0B` → bytes (Docker's decimal units).
  static func dockerBytes(_ text: String) -> Int64 {
    let units: [(String, Double)] = [("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("kB", 1e3), ("KB", 1e3), ("B", 1)]
    for (unit, scale) in units where text.hasSuffix(unit) {
      return Int64((Double(text.dropLast(unit.count)) ?? 0) * scale)
    }
    return 0
  }

  /// Space a UTM disk holds for blocks the guest already deleted: the image's
  /// size on disk minus what `qemu-img measure` says a rewritten copy needs.
  /// Compacting rewrites the image, so a running machine is locked.
  private mutating func addDiskCompaction() {
    let qemuImg = ["/opt/homebrew/bin/qemu-img", "/usr/local/bin/qemu-img"]
      .first { fileManager.isExecutableFile(atPath: $0) }
    guard let qemuImg else { return }
    var running = Set<String>()
    // A closed UTM runs no machine; asking utmctl would open it.
    if VMStore.isUTMRunning,
       let utmctl = VMStore.utmctlPaths.first(where: { fileManager.isExecutableFile(atPath: $0) }) {
      let list = ScanShell.run(utmctl, arguments: ["list"], currentDirectory: nil, timeout: 20)
      for vm in VMStore.parseList(list.stdout) where vm.status != .stopped { running.insert(vm.name) }
    }
    // UTM keeps machines in its container, or anywhere the reader saved them:
    // Spotlight knows both.
    let found = ScanShell.run("/usr/bin/mdfind", arguments: ["kMDItemFSName == '*.utm'"], currentDirectory: nil, timeout: 20)
    let bundles = Set(children(of: h("Library/Containers/com.utmapp.UTM/Data/Documents"))
      + found.stdout.split(separator: "\n").map(String.init)).filter { $0.hasSuffix(".utm") }
    for bundle in bundles.sorted() {
      let name = ((bundle as NSString).lastPathComponent as NSString).deletingPathExtension
      for image in children(of: bundle + "/Data") where image.hasSuffix(".qcow2") {
        // -U reads without the write lock, so a running machine is measured too
        // (and shown locked).
        let measured = ScanShell.run(qemuImg, arguments: ["measure", "-U", "--output=json", "-O", "qcow2", image],
                                     currentDirectory: nil, timeout: 60)
        guard measured.succeeded, let data = measured.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let required = (json["required"] as? NSNumber)?.int64Value,
              let actual = (try? URL(fileURLWithPath: image).resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?
                .totalFileAllocatedSize
        else { continue }
        let reclaimable = Int64(actual) - required
        guard reclaimable > 500_000_000 else { continue }
        let temporary = image + ".compacting"
        // A failed rewrite leaves the image as it was and removes the partial copy.
        let script = "\"$0\" convert -O qcow2 \"$1\" \"$2\" || { rm -f \"$2\"; exit 1; }; mv -f \"$2\" \"$1\""
        var item = StorageItem(
          id: "compact:" + image, category: .virtualMachines, group: "Free Space Inside Disks",
          title: "Compact \(name)", detail: "Gives back space the guest already deleted", paths: [],
          safety: .cache,
          cleanup: .command(executable: "/bin/bash", arguments: ["-c", script, qemuImg, image, temporary], verb: "Compact"),
          bytes: reclaimable, reportedSize: true)
        if running.contains(name) { item.lockReason = "Running: stop the machine first" }
        add(item)
      }
    }
  }

  // MARK: AI

  mutating func addAI() {
    for candidate in ["ComfyUI", "Documents/ComfyUI", "Library/Application Support/ComfyUI"]
    where isDirectory(h(candidate) + "/models") {
      addComfyUI(at: h(candidate))
    }
    addOllama()

    for model in children(of: h(".cache/huggingface/hub")) {
      let name = (model as NSString).lastPathComponent
      let isModel = name.hasPrefix("models--")
      guard isModel || name.hasPrefix("datasets--") || name.hasPrefix("spaces--") else { continue }
      let title = name.components(separatedBy: "--").dropFirst().joined(separator: "/")
      add(StorageItem(
        id: model, category: .aiModels, group: isModel ? "Hugging Face models" : "Hugging Face datasets",
        title: title, paths: [model], safety: .data, cleanup: .trash))
    }
    folder(.aiModels, "Hugging Face models", "Xet cache", ".cache/huggingface/xet", .cache)

    for root in [".lmstudio/models", ".cache/lm-studio/models"] {
      for publisher in children(of: h(root)) {
        let publisherName = (publisher as NSString).lastPathComponent
        eachChild(.aiModels, "LM Studio", of: publisher, .data, title: { "\(publisherName)/\($0)" })
      }
    }
    eachChild(.aiModels, "Draw Things", of: "Library/Containers/com.liuliu.draw-things/Data/Documents/Models",
      .data)
    folder(.aiModels, "Local models", "DiffusionBee", ".diffusionbee", .data)
    folder(.aiModels, "Local models", "Whisper models", ".cache/whisper", .data)
    folder(.aiModels, "Local models", "PyTorch hub", ".cache/torch", .data)
    folder(.aiModels, "Local models", "Ollama cache", "Library/Caches/ollama", .cache)

    let claude = "Library/Application Support/Claude"
    folder(.claude, "Claude desktop", "Claude desktop VM", "\(claude)/vm_bundles", .rebuildable,
      detail: "The sandbox VM image — downloaded again when needed")
    folder(.claude, "Claude desktop", "Claude Code (desktop)", "\(claude)/claude-code", .rebuildable)
    folder(.claude, "Claude desktop", "Claude Code VM (desktop)", "\(claude)/claude-code-vm", .rebuildable)
    for cache in ["Cache", "Code Cache", "GPUCache"] {
      folder(.claude, "Claude desktop", "Claude desktop \(cache.lowercased())", "\(claude)/\(cache)", .cache)
    }
    folder(.claude, "Claude Code", "Claude Code transcripts", ".claude/projects", .data,
      detail: "Session history for --resume")
    eachChild(.claude, "Claude Code", of: ".local/share/claude/versions", .rebuildable,
      title: { "Claude Code \($0)" })
    folder(.hermes, "Hermes", "Hermes cache", ".hermes/cache", .cache)
    folder(.hermes, "Hermes", "Hermes temp", ".hermes-tmp", .cache)
    folder(.hermes, "Hermes", "Hermes", ".hermes", .data)
    folder(.codex, "Codex", "Codex", ".codex", .data)
    folder(.aiTools, "Cursor", "Cursor", ".cursor", .data)
    folder(.aiTools, "Gemini CLI", "Gemini CLI", ".gemini", .data)
  }

  /// A ComfyUI install, split the way ComfyUI itself splits models: one group
  /// per model type (checkpoints, diffusion models, text encoders, VAE, LoRA…),
  /// one item per model file. Its Python env, custom nodes and outputs follow.
  mutating func addComfyUI(at root: String) {
    let install = (root as NSString).lastPathComponent
    let models = root + "/models"
    comfyRoots.insert(root)
    for typeFolder in children(of: models) where isDirectory(typeFolder) {
      let type = Self.comfyModelType((typeFolder as NSString).lastPathComponent)
      guard let enumerator = fileManager.enumerator(
        at: URL(fileURLWithPath: typeFolder),
        includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
        options: [.skipsHiddenFiles])
      else { continue }
      for case let url as URL in enumerator {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values?.isRegularFile == true, (values?.fileSize ?? 0) >= 1_000_000 else { continue }
        let relative = String(url.path.dropFirst(models.count + 1))
        add(StorageItem(
          id: url.path, category: .aiModels, group: "ComfyUI · \(type)",
          title: url.deletingPathExtension().lastPathComponent,
          detail: "\(install) · \(relative)", paths: [url.path], safety: .data, cleanup: .trash))
      }
    }
    for venv in ["venv", ".venv"] {
      folder(.aiModels, "ComfyUI", "\(install) Python environment", root + "/" + venv, .rebuildable)
    }
    folder(.aiModels, "ComfyUI", "\(install) custom nodes", root + "/custom_nodes", .rebuildable, minBytes: 10_000_000)
    folder(.aiModels, "ComfyUI", "\(install) outputs", root + "/output", .data)
    folder(.aiModels, "ComfyUI", "\(install) inputs", root + "/input", .data)
    folder(.aiModels, "ComfyUI", "\(install) temp", root + "/temp", .cache)
  }

  static func comfyModelType(_ folder: String) -> String {
    switch folder.lowercased() {
    case "checkpoints": "Checkpoints"
    case "unet", "diffusion_models": "Diffusion models"
    case "clip", "text_encoders": "Text encoders"
    case "vae", "vae_approx": "VAE"
    case "loras", "lora", "lycoris": "LoRA"
    case "controlnet", "t2i_adapter": "ControlNet"
    case "upscale_models", "latent_upscale_models": "Upscalers"
    case "embeddings": "Embeddings"
    case "clip_vision": "CLIP vision"
    case "ipadapter": "IP-Adapter"
    case "hypernetworks": "Hypernetworks"
    case "style_models": "Style models"
    default: folder.replacingOccurrences(of: "_", with: " ").capitalized
    }
  }

  /// Ollama models from their manifests: the layers name the blobs a model
  /// uses and their sizes, and `ollama rm` removes the blobs no other model
  /// shares.
  private mutating func addOllama() {
    let models = ProcessInfo.processInfo.environment["OLLAMA_MODELS"] ?? h(".ollama/models")
    let manifests = models + "/manifests"
    guard let enumerator = fileManager.enumerator(atPath: manifests) else { return }
    let ollama = StorageNames.tool("ollama", extra: ["/Applications/Ollama.app/Contents/Resources/ollama"])
    while let relative = enumerator.nextObject() as? String {
      let path = manifests + "/" + relative
      guard !isDirectory(path), let data = fileManager.contents(atPath: path),
        let manifest = try? JSONDecoder.storage.decode(OllamaManifest.self, from: data)
      else { continue }
      // registry/namespace/model/tag
      let parts = relative.split(separator: "/").map(String.init)
      guard parts.count >= 4 else { continue }
      let namespace = parts[parts.count - 3], model = parts[parts.count - 2], tag = parts[parts.count - 1]
      let name = (namespace == "library" ? "" : namespace + "/") + model + ":" + tag
      let layers = manifest.layers + [manifest.config].compactMap { $0 }
      add(StorageItem(
        id: "ollama:" + name, category: .aiModels, group: "Ollama", title: name, detail: "Ollama model",
        paths: [path], safety: .data,
        cleanup: ollama.map { .command(executable: $0, arguments: ["rm", name], verb: "Remove model") }
          ?? .revealOnly(reason: "Install the ollama CLI to remove models"),
        bytes: layers.reduce(0) { $0 + $1.size }, reportedSize: true))
    }
  }

  // MARK: Bun & Node

  mutating func addJavaScript() {
    folder(.javascript, "Package Caches", "Bun install cache", ".bun/install/cache", .cache)
    folder(.javascript, "Package Caches", "Bun cache", "Library/Caches/bun", .cache)
    folder(.javascript, "Package Caches", "npm cache", ".npm/_cacache", .cache)
    folder(.jsGlobal, "npx", "npx packages", ".npm/_npx", .cache)
    folder(.javascript, "Package Caches", "pnpm store", "Library/pnpm/store", .cache)
    folder(.javascript, "Package Caches", "pnpm self-install store", "Library/pnpm/package-manager-store", .cache)
    folder(.javascript, "Package Caches", "pnpm store", ".local/share/pnpm/store", .cache)
    folder(.javascript, "Package Caches", "pnpm cache", "Library/Caches/pnpm", .cache)
    folder(.javascript, "Package Caches", "Yarn cache", "Library/Caches/Yarn", .cache)
    folder(.javascript, "Package Caches", "Yarn Berry cache", ".yarn/berry/cache", .cache)
    folder(.javascript, "Package Caches", "node-gyp headers", "Library/Caches/node-gyp", .cache)
    folder(.javascript, "Package Caches", "Deno cache", "Library/Caches/deno", .cache)
    folder(.javascript, "Package Caches", "Turborepo cache", "Library/Caches/turbo", .cache)
    eachChild(.jsGlobal, "Node Versions", of: ".nvm/versions/node", .rebuildable, detail: "nvm",
      title: { "Node \($0)" })
    folder(.jsGlobal, "Node Versions", "nvm download cache", ".nvm/.cache", .cache)
    eachChild(.jsGlobal, "Node Versions", of: ".volta/tools/image/node", .rebuildable, detail: "Volta",
      title: { "Node \($0)" })
    eachChild(.jsGlobal, "Node Versions", of: ".local/share/fnm/node-versions", .rebuildable,
      detail: "fnm", title: { "Node \($0)" })
    // Global installs are installed tools; the same packages anywhere else are
    // a project's dependencies (the folder walk files those under Bun & Node).
    // These rules run before the walk, so a global folder inside a walked
    // folder is never mistaken for a project's.
    for prefix in Self.npmPrefixes(home: home) {
      folder(.jsGlobal, "Global Packages", "Global npm packages", prefix + "/lib/node_modules", .rebuildable,
        detail: "npm install -g · \(prefix.abbreviatingHome)")
    }
    folder(.jsGlobal, "Global Packages", "Global npm packages (Homebrew Node)", "/opt/homebrew/lib/node_modules",
      .rebuildable, detail: "npm install -g")
    folder(.jsGlobal, "Global Packages", "Global npm packages", "/usr/local/lib/node_modules", .rebuildable,
      detail: "npm install -g")
    folder(.jsGlobal, "Global Packages", "Global Bun packages", ".bun/install/global", .rebuildable,
      detail: "bun install -g")
    folder(.jsGlobal, "Global Packages", "Global pnpm packages", "Library/pnpm/global", .rebuildable,
      detail: "pnpm add -g")
    folder(.jsGlobal, "Global Packages", "Global pnpm packages", ".local/share/pnpm/global", .rebuildable,
      detail: "pnpm add -g")
    folder(.jsGlobal, "Global Packages", "Global Yarn packages", ".config/yarn/global", .rebuildable,
      detail: "yarn global add")
    folder(.jsGlobal, "Global Packages", "Volta packages", ".volta/tools/image/packages", .rebuildable,
      detail: "volta install")
  }

  // MARK: Web & browsers

  mutating func addWeb() {
    let caches = "Library/Caches"
    folder(.web, "Browser Caches", "Chrome", "\(caches)/Google/Chrome", .cache)
    folder(.web, "Browser Caches", "Chrome Canary", "\(caches)/Google/Chrome Canary", .cache)
    folder(.web, "Browser Caches", "Brave", "\(caches)/BraveSoftware", .cache)
    folder(.web, "Browser Caches", "Microsoft Edge", "\(caches)/Microsoft Edge", .cache)
    folder(.web, "Browser Caches", "Arc", "\(caches)/company.thebrowser.Browser", .cache)
    folder(.web, "Browser Caches", "Firefox", "\(caches)/Firefox", .cache)
    folder(.web, "Browser Caches", "Vivaldi", "\(caches)/com.vivaldi.Vivaldi", .cache)
    folder(.web, "Browser Caches", "Opera", "\(caches)/com.operasoftware.Opera", .cache)
    folder(.web, "Browser Caches", "Safari", "\(caches)/com.apple.Safari", .cache)

    eachChild(.web, "Test Browsers", of: "\(caches)/ms-playwright", .rebuildable, detail: "Playwright")
    eachChild(.web, "Test Browsers", of: ".cache/puppeteer", .rebuildable, detail: "Puppeteer")
    folder(.web, "Test Browsers", "Cypress", "\(caches)/Cypress", .rebuildable)
    folder(.web, "Test Browsers", "Chrome for Testing", "Library/Application Support/Google/Chrome for Testing",
      .rebuildable)
    folder(.web, "Test Browsers", "agent-browser", ".agent-browser", .rebuildable)
    folder(.web, "Test Browsers", "Electron downloads", "\(caches)/electron", .cache)
    folder(.web, "Test Browsers", "electron-builder", "\(caches)/electron-builder", .cache)
  }

  // MARK: Python

  mutating func addPython() {
    folder(.python, "Package Caches", "uv cache", ".cache/uv", .cache)
    folder(.python, "Package Caches", "pip cache", "Library/Caches/pip", .cache)
    folder(.python, "Package Caches", "pip cache", ".cache/pip", .cache)
    folder(.python, "Package Caches", "Poetry cache", "Library/Caches/pypoetry", .cache)
    folder(.pythonTools, "pipx", "pipx tools", ".local/pipx", .rebuildable)
    for conda in ["miniconda3", "anaconda3", "miniforge3", ".conda"] {
      folder(.python, "Package Caches", "\(conda) packages", "\(conda)/pkgs", .cache)
      eachChild(.python, "Environments", of: "\(conda)/envs", .data, detail: conda)
    }
    eachChild(.pythonTools, "Python Versions", of: ".local/share/uv/python", .rebuildable, detail: "uv")
    eachChild(.pythonTools, "uv Tools", of: ".local/share/uv/tools", .rebuildable, detail: "uv tool install")
    eachChild(.pythonTools, "Python Versions", of: ".pyenv/versions", .rebuildable, detail: "pyenv")
    eachChild(.pythonTools, "pip Packages", of: "Library/Python", .rebuildable, detail: "pip install --user",
      title: { "Python \($0) user packages" })
    for python in children(of: "/opt/homebrew/lib") where (python as NSString).lastPathComponent.hasPrefix("python") {
      folder(.pythonTools, "pip Packages", "\((python as NSString).lastPathComponent) site-packages",
        python + "/site-packages", .rebuildable, detail: "pip install into Homebrew's Python", minBytes: 20_000_000)
    }
  }

  // MARK: Other toolchains

  mutating func addToolchains() {
    folder(.homebrew, "Downloads", "Homebrew downloads", "Library/Caches/Homebrew", .cache)
    // One item per formula and cask, removed by brew so its links and
    // receipts go too; brew refuses a formula something else still needs.
    let brew = StorageNames.tool("brew")
    for (folder, cask) in [("Cellar", false), ("Caskroom", true)] {
      for path in children(of: "/opt/homebrew/\(folder)") + children(of: "/usr/local/\(folder)") {
        let name = (path as NSString).lastPathComponent
        let versions = children(of: path).map { ($0 as NSString).lastPathComponent }
        let arguments = ["uninstall"] + (cask ? ["--cask"] : []) + [name]
        add(StorageItem(
          id: path, category: .homebrew, group: cask ? "Casks" : "Formulae",
          title: name, detail: versions.isEmpty ? nil : versions.joined(separator: ", "),
          paths: [path], safety: .rebuildable,
          cleanup: brew.map { .command(executable: $0, arguments: arguments, verb: "brew uninstall") }
            ?? .revealOnly(reason: "brew is not installed where Dev looks for it"),
          minBytes: 20_000_000))
      }
    }

    folder(.languages, "Rust", "Cargo registry", ".cargo/registry", .cache)
    folder(.toolchains, "Rust", "cargo install binaries", ".cargo/bin", .rebuildable,
      detail: "Tools installed with cargo install")
    folder(.languages, "Rust", "Cargo git checkouts", ".cargo/git", .cache)
    eachChild(.toolchains, "Rust", of: ".rustup/toolchains", .rebuildable, detail: "Rust toolchain")

    let go = StorageNames.tool("go")
    folder(.toolchains, "Go", "go install binaries", "go/bin", .rebuildable,
      detail: "Tools installed with go install")
    folder(.languages, "Go", "Go modules", "go/pkg/mod", .cache,
      cleanup: go.map { .command(executable: $0, arguments: ["clean", "-modcache"], verb: "go clean") }
        ?? .trash)
    folder(.languages, "Go", "Go build cache", "Library/Caches/go-build", .cache)
    folder(.languages, "Go", "gopls cache", "Library/Caches/gopls", .cache)

    folder(.languages, ".NET", "NuGet packages", ".nuget/packages", .cache)
    folder(.languages, ".NET", "NuGet caches", ".local/share/NuGet", .cache)
    folder(.toolchains, ".NET", ".NET global tools", ".dotnet/tools", .rebuildable, detail: "dotnet tool install -g")
    folder(.toolchains, ".NET", ".NET SDK", ".dotnet", .rebuildable)

    folder(.toolchains, "Dart & Flutter", "dart pub global packages", ".pub-cache/global_packages", .rebuildable,
      detail: "dart pub global activate")
    folder(.languages, "Dart & Flutter", "Pub cache", ".pub-cache", .cache)
    folder(.languages, "Dart & Flutter", "Dart analysis server", ".dartServer", .cache)

    folder(.toolchains, "Ruby", "User-installed gems", ".gem", .rebuildable, detail: "gem install --user-install")
    eachChild(.toolchains, "Ruby", of: ".rbenv/versions", .rebuildable, detail: "rbenv")

    folder(.languages, "Other", "Zig cache", ".cache/zig", .cache)
    folder(.languages, "Other", "Haskell Stack", ".stack", .cache)
    folder(.languages, "Other", "Cabal packages", ".cabal/packages", .cache)
    folder(.languages, "Other", "Hex", ".hex", .cache)
    folder(.languages, "Other", "Mix", ".mix", .cache)
    folder(.languages, "Other", "Bazel", "Library/Caches/bazel", .cache)
    folder(.languages, "Other", "ccache", "Library/Caches/ccache", .cache)
  }

  // MARK: Databases

  mutating func addDatabases() {
    let engines = ["postgres", "mysql", "mariadb", "mongodb", "redis", "valkey", "clickhouse"]
    eachChild(.databases, "Homebrew services", of: "/opt/homebrew/var", .data,
      include: { name in engines.contains { name.lowercased().hasPrefix($0) } })
    eachChild(.databases, "Homebrew services", of: "/opt/homebrew/var/lib", .data,
      include: { name in engines.contains { name.lowercased().hasPrefix($0) } })
    folder(.databases, "Apps", "Postgres.app", "Library/Application Support/Postgres", .data)
    folder(.databases, "Apps", "DBngin", "Library/Application Support/com.tinyapp.DBngin", .data)
  }
}

// MARK: - Tool JSON

nonisolated extension JSONDecoder {
  static var storage: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}

nonisolated private struct SimDeviceList: Decodable {
  struct Device: Decodable {
    let udid: String
    let name: String
    let state: String
    let isAvailable: Bool?
    let lastUsedAt: Date?
  }
  let devices: [String: [Device]]
}

nonisolated private struct SimRuntime: Decodable {
  let identifier: String
  let runtimeIdentifier: String?
  let version: String?
  let build: String?
  let deletable: Bool?
  let sizeBytes: Int64?
  let mountPath: String?
  let path: String?
  let lastUsedAt: Date?

  /// The version its simulators name (`…SimRuntime.iOS-27-0`), shared by
  /// every build of that version.
  var platformVersion: String { runtimeIdentifier ?? identifier }
}

nonisolated private struct OllamaManifest: Decodable {
  struct Layer: Decodable {
    let digest: String
    let size: Int64
  }
  let config: Layer?
  let layers: [Layer]
}
