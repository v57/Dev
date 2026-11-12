//
//  Workflow.swift
//  Dev
//

import DevDesktop
import DevRunners
import Foundation

// MARK: - Workflow

/// One CI workflow of a project: what starts it and the steps it runs, in
/// `.dev/workflows/<id>.json` at the project root. The file is the source of
/// truth, so the Workflows tab, an agent over MCP and a text editor all edit the
/// same thing; the build number of every run is the commit count.
nonisolated struct Workflow: Codable, Hashable, Identifiable, Sendable {
  /// The file name without `.json`.
  var id: String
  var name: String
  var trigger = Trigger()
  var steps: [Step] = []
  /// Keep going after a step fails (the run still ends as failed).
  var continueOnFailure = false

  /// What starts a run besides the Run button. Dev checks these while it is
  /// open: there is no server, so nothing runs while the Mac sleeps or Dev is quit.
  struct Trigger: Codable, Hashable, Sendable {
    /// A new commit on this branch (checked every few minutes), or nil.
    var branch: String?
    /// A new tag matching this glob (`v*`), or nil.
    var tag: String?
    /// Every day at this time (`02:00`), or nil.
    var daily: String?

    /// Whether anything starts the workflow besides the Run button.
    var isSet: Bool {
      !(branch ?? "").isEmpty || !(tag ?? "").isEmpty || !(daily ?? "").isEmpty
    }

    var summary: String {
      var parts: [String] = []
      if let branch, !branch.isEmpty { parts.append(String(localized: "Every commit on \(branch)")) }
      if let tag, !tag.isEmpty { parts.append(String(localized: "Tags matching \(tag)")) }
      if let daily, !daily.isEmpty { parts.append(String(localized: "Every day at \(daily)")) }
      return parts.isEmpty ? String(localized: "Run by hand") : parts.joined(separator: " · ")
    }
  }

  /// One step: a release.sh step for a platform (on this Mac, or on a UTM virtual machine for Windows and
  /// Linux), a screenshot capture, or a shell command on this Mac or a VM.
  struct Step: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var kind: Kind
    /// For `.release`: the release.sh step (`build`, `test`, `archive`…).
    var releaseStep: String?
    /// For `.release`: the platform it builds or ships (`macos`, `ios`, `windows`, `linux`, `android`); nil is
    /// release.env's PLATFORM.
    var platform: String?
    /// For `.command`: what runs in the project folder.
    var command: String?
    /// `mac`, or `vm:<name>` for a UTM machine (commands, and release steps for Windows and Linux, which build
    /// there and bring their packages back), or `hub` / `hub:<system>` (`hub:macos`, `hub:linux-arm64`) for a
    /// command on the runners of the user's Hub (dev-runner), which run it at the pushed commit.
    var runner: String = "mac"
    /// Runs at the same time as the step before it.
    var parallel = false
    /// For a Hub command: how many jobs it splits into, each on its own runner (`DEV_SHARD_INDEX` of
    /// `DEV_SHARD_COUNT`; `dev-shard swift test` splits a package's tests).
    var shards: Int?
    /// For a Hub command: what its runner needs beyond `runner` (Xcode or Swift version, a free simulator).
    var requires: RunnerRequirement?

    enum Kind: String, Codable, Sendable, CaseIterable {
      case release, screenshots, command
    }

    var runsOnVM: Bool { runner.hasPrefix("vm:") }
    /// What a Hub runner needs for this step, nil when it doesn't run on Hub runners.
    var hubRequirement: RunnerRequirement? {
      kind == .command ? RunnerRequirement(runner: runner, requires: requires) : nil
    }
    /// The jobs it splits into on Hub runners.
    var jobCount: Int { hubRequirement == nil ? 1 : min(max(shards ?? 1, 1), 64) }
    var vmName: String? { runsOnVM ? String(runner.dropFirst(3)) : nil }

    var releasePlatform: ReleasePlatform? { platform.flatMap(ReleasePlatform.init) }

    var runnerTitle: String {
      if let vmName { return String(localized: "\(vmName) (VM)") }
      if let requirement = hubRequirement {
        let needs = requirement.summary
        let base = needs.isEmpty ? String(localized: "Hub runners") : String(localized: "Hub runners · \(needs)")
        return jobCount > 1 ? String(localized: "\(base) · \(jobCount) shards") : base
      }
      return DevDesktop.thisComputer
    }

    /// What the step will run, for the inspector.
    var commandLine: String {
      switch kind {
      case .release:
        let platform = platform.map { "--platform \($0) " } ?? ""
        let host = vmName.map { "--host <\($0)> " } ?? ""
        return "release.sh \(platform)\(host)\(releaseStep ?? "")"
      case .screenshots: return "release.sh screenshots, then the framing"
      case .command: return command ?? ""
      }
    }

    /// True for the steps that send something out of this Mac. A run asks
    /// before it starts one of these, whoever started it.
    var publishes: Bool {
      guard kind == .release, let step = releaseStep.flatMap(ReleaseStep.init) else { return false }
      return step.publishes != nil
    }
  }

  // MARK: - files

  static func folder(in root: URL) -> URL {
    root.appendingPathComponent(".dev/workflows", isDirectory: true)
  }

  static func url(_ id: String, in root: URL) -> URL {
    folder(in: root).appendingPathComponent(id + ".json")
  }

  /// The project's workflows, by name. A project without the folder gets the
  /// defaults, not yet written (they land on disk the first time one is saved).
  static func load(in root: URL) -> [Workflow] {
    let folder = folder(in: root)
    let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    let loaded = names.filter { $0.hasSuffix(".json") }.compactMap { name -> Workflow? in
      guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)),
            var workflow = try? JSONDecoder().decode(Workflow.self, from: data)
      else { return nil }
      workflow.id = (name as NSString).deletingPathExtension
      return workflow
    }
    if loaded.isEmpty { return defaults(for: root) }
    return loaded.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  func save(in root: URL) throws {
    let folder = Self.folder(in: root)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(self).write(to: Self.url(id, in: root), options: .atomic)
  }

  static func delete(_ id: String, in root: URL) {
    try? FileManager.default.removeItem(at: url(id, in: root))
  }

  /// The starting workflows, from what the project has: a Release workflow over
  /// the release.sh steps its release.env enables (an archive per Apple platform the
  /// app supports, then the result archive), and a Pull Request check. Windows and
  /// Linux steps are added from the step menu, which knows the VMs.
  static func defaults(for root: URL) -> [Workflow] {
    let config = ReleaseConfig.load(from: root)
    let hasTests = !(config?["TEST_SCHEME"] ?? "").isEmpty
    let hasScreenshots = !(config?["SCREENSHOT_TEST"] ?? "").isEmpty
    var release = Workflow(id: "release", name: "Release", trigger: Trigger(tag: "v*"))
    func add(_ step: ReleaseStep, _ platform: ReleasePlatform? = nil, to workflow: inout Workflow) {
      workflow.steps.append(Step(
        id: step.rawValue + (platform.map { "-" + $0.rawValue } ?? ""),
        name: step.title + (platform.map { " · " + $0.title } ?? ""), kind: .release, releaseStep: step.rawValue,
        platform: platform?.rawValue))
    }
    add(.build, to: &release)
    if hasTests { add(.test, to: &release) }
    if hasScreenshots {
      release.steps.append(Step(id: "screenshots", name: "Screenshots", kind: .screenshots))
    }
    add(.archive, to: &release)
    if config?["PLATFORM"] ?? "macos" == "macos", supportsIOS(root, project: config?["PROJECT"]) {
      add(.archive, .ios, to: &release)
    }
    if !(config?["DIRECT_DOWNLOAD"] ?? "").isEmpty { add(.direct, to: &release) }
    add(.bundle, to: &release)
    if !(config?["GITHUB_REPO"] ?? "").isEmpty { add(.github, to: &release) }
    if config?["APP_STORE"] == "yes" { add(.appstore, to: &release) }

    var check = Workflow(id: "pull-request", name: "Pull Request", trigger: Trigger(branch: "main"))
    add(.build, to: &check)
    if hasTests { add(.test, to: &check) }
    return [check, release]
  }

  /// A Mac app whose Xcode project builds for iOS too (SUPPORTED_PLATFORMS has iphoneos).
  private static func supportsIOS(_ root: URL, project: String?) -> Bool {
    let name = project?.nilIfEmpty
      ?? (try? FileManager.default.contentsOfDirectory(atPath: root.path))?.first { $0.hasSuffix(".xcodeproj") }
    guard let name,
          let text = try? String(contentsOf: root.appendingPathComponent(name).appendingPathComponent("project.pbxproj"),
                                 encoding: .utf8)
    else { return false }
    return text.contains("iphoneos")
  }
}

// MARK: - Runs

/// One run of a workflow, kept in the run history.
nonisolated struct WorkflowRun: Codable, Hashable, Identifiable, Sendable {
  var id = UUID()
  var workflowID: String
  var workflowName: String
  /// `git rev-list --count HEAD` when the run started: the build number.
  var buildNumber: Int?
  var commit: String?
  var version: String?
  var startedAt = Date()
  var finishedAt: Date?
  /// "you", "schedule", "commit on main", "Claude through MCP"…
  var startedBy: String
  var steps: [StepRun] = []
  var state: State = .running
  /// The folder the run's release.sh steps write to (`--output`): `build/release/runs/<date>-<build>` in the project.
  var output: String?
  /// The files its steps made, in the order they came (nil in runs from before Dev kept them).
  var artifacts: [Artifact]?

  var files: [Artifact] { artifacts ?? [] }

  /// One file a step made, from release.sh's `::artifact KIND PLATFORM PATH` line.
  struct Artifact: Codable, Hashable, Identifiable, Sendable {
    var path: String
    /// `archive` (.xcarchive), `package` (.zip, .dmg, .tar.gz, .apk), `bundle` (the result archive: a zip, or the
    /// folder Export makes),
    /// `manifest`, `tests`, `screenshots`.
    var kind: String
    /// `macos`, `ios`, `windows`, `linux`, `android`, or `all` for the result archive and its manifest.
    var platform: String
    var stepID: String
    /// Bytes on disk (a folder's total), once the step has finished.
    var size: Int64?

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
    var name: String { url.lastPathComponent }
    var platformTitle: String { ReleasePlatform(rawValue: platform)?.title ?? String(localized: "All platforms") }
    var isFolder: Bool {
      kind == "archive" || kind == "tests" || kind == "screenshots" || (kind == "bundle" && url.pathExtension != "zip")
    }

    init(path: String, kind: String, platform: String, stepID: String, size: Int64? = nil) {
      self.path = path
      self.kind = kind
      self.platform = platform
      self.stepID = stepID
      self.size = size
    }

    /// An artifact marker line, or nil for any other line.
    init?(marker line: String, stepID: String) {
      guard line.hasPrefix("::artifact ") else { return nil }
      let parts = line.dropFirst("::artifact ".count).split(separator: " ", maxSplits: 2).map(String.init)
      guard parts.count == 3, parts[2].hasPrefix("/") else { return nil }
      self.init(path: parts[2], kind: parts[0], platform: parts[1], stepID: stepID)
    }

    /// The size on disk of a file or a folder's files.
    static func size(of url: URL) -> Int64? {
      let fm = FileManager.default
      var isFolder: ObjCBool = false
      guard fm.fileExists(atPath: url.path, isDirectory: &isFolder) else { return nil }
      guard isFolder.boolValue else {
        return (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
      }
      var total: Int64 = 0
      let files = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
      while let file = files?.nextObject() as? URL {
        let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
      }
      return total
    }
  }

  /// The result archive, if the run made one.
  var bundle: Artifact? { files.last { $0.kind == "bundle" } }

  /// The platforms the run made files for, in release order.
  var platforms: [ReleasePlatform] {
    ReleasePlatform.allCases.filter { platform in files.contains { $0.platform == platform.rawValue } }
  }

  var totalSize: Int64 { files.filter { $0.kind != "bundle" && $0.kind != "manifest" }.compactMap(\.size).reduce(0, +) }

  enum State: String, Codable, Sendable {
    case running, passed, failed, cancelled
  }

  struct StepRun: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var runner: String
    var state: StepState = .waiting
    var startedAt: Date?
    var finishedAt: Date?
    /// Why a step failed or was skipped.
    var note: String?
    /// The last lines of the step's output (the full log lives with the run).
    var logTail: [String] = []
    /// A Hub step's jobs (one per shard), each with its runner and its own log (nil for other steps).
    var jobs: [Job]?

    /// The runners a Hub step's jobs ran on, for its row ("This Mac, ubuntu").
    var jobRunners: String? {
      let names = (jobs ?? []).compactMap(\.runner)
      guard !names.isEmpty else { return nil }
      var seen: Set<String> = []
      return names.filter { seen.insert($0).inserted }.joined(separator: ", ")
    }

    /// One job of a step on a Hub runner.
    struct Job: Codable, Hashable, Identifiable, Sendable {
      /// The key of its log in the run's logs: `<step>#<shard>`
      var id: String
      /// "Shard 1 of 2", or the step's name
      var title: String
      /// The runner that took it, once one did
      var runner: String?
      var state: StepState = .waiting
      var startedAt: Date?
      var finishedAt: Date?
      var note: String?

      var duration: TimeInterval? {
        guard let startedAt else { return nil }
        return (finishedAt ?? Date()).timeIntervalSince(startedAt)
      }
    }

    var duration: TimeInterval? {
      guard let startedAt else { return nil }
      return (finishedAt ?? Date()).timeIntervalSince(startedAt)
    }
  }

  enum StepState: String, Codable, Sendable {
    case waiting, running, passed, failed, skipped
  }

  var title: String {
    [buildNumber.map(String.init), version].compactMap { $0 }.joined(separator: " · ")
  }
}

nonisolated extension TimeInterval {
  /// "1:12", "0:09", "12:03".
  var clock: String {
    let seconds = Int(self.rounded())
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
  }
}

extension Workflow {
  /// A hand-written file may leave out what has a default: `id` (the file name sets it), the trigger, the steps and
  /// continueOnFailure. SSH's Publish libssh2 had no `id`, and Dev listed only the default workflows.
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
    name = try container.decode(String.self, forKey: .name)
    trigger = try container.decodeIfPresent(Trigger.self, forKey: .trigger) ?? Trigger()
    steps = try container.decodeIfPresent([Step].self, forKey: .steps) ?? []
    continueOnFailure = try container.decodeIfPresent(Bool.self, forKey: .continueOnFailure) ?? false
  }
}

extension Workflow.Step {
  /// A step may leave out its runner (this Mac) and parallel (false), as Dev's own files never do.
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    name = try container.decode(String.self, forKey: .name)
    kind = try container.decode(Kind.self, forKey: .kind)
    releaseStep = try container.decodeIfPresent(String.self, forKey: .releaseStep)
    platform = try container.decodeIfPresent(String.self, forKey: .platform)
    command = try container.decodeIfPresent(String.self, forKey: .command)
    runner = try container.decodeIfPresent(String.self, forKey: .runner) ?? "mac"
    parallel = try container.decodeIfPresent(Bool.self, forKey: .parallel) ?? false
    shards = try container.decodeIfPresent(Int.self, forKey: .shards)
    requires = try container.decodeIfPresent(RunnerRequirement.self, forKey: .requires)
  }
}
