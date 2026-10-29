//
//  Workflow.swift
//  Dev
//

import DevDesktop
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

    var summary: String {
      var parts: [String] = []
      if let branch, !branch.isEmpty { parts.append("Every commit on \(branch)") }
      if let tag, !tag.isEmpty { parts.append("Tags matching \(tag)") }
      if let daily, !daily.isEmpty { parts.append("Every day at \(daily)") }
      return parts.isEmpty ? "Run by hand" : parts.joined(separator: " · ")
    }
  }

  /// One step: a release.sh step on this Mac, a screenshot capture, or a shell
  /// command on this Mac or a UTM virtual machine.
  struct Step: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var kind: Kind
    /// For `.release`: the release.sh step (`build`, `test`, `archive`…).
    var releaseStep: String?
    /// For `.command`: what runs in the project folder.
    var command: String?
    /// `mac`, or `vm:<name>` for a UTM machine (commands only).
    var runner: String = "mac"
    /// Runs at the same time as the step before it.
    var parallel = false

    enum Kind: String, Codable, Sendable, CaseIterable {
      case release, screenshots, command
    }

    var runsOnVM: Bool { runner.hasPrefix("vm:") }
    var vmName: String? { runsOnVM ? String(runner.dropFirst(3)) : nil }

    var runnerTitle: String {
      if let vmName { return "\(vmName) (VM)" }
      return DevDesktop.thisComputer
    }

    /// What the step will run, for the inspector.
    var commandLine: String {
      switch kind {
      case .release: return "release.sh \(releaseStep ?? "")"
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
  /// the release.sh steps its release.env enables, and a Pull Request check.
  static func defaults(for root: URL) -> [Workflow] {
    let config = ReleaseConfig.load(from: root)
    let hasTests = !(config?["TEST_SCHEME"] ?? "").isEmpty
    let hasScreenshots = !(config?["SCREENSHOT_TEST"] ?? "").isEmpty
    var release = Workflow(id: "release", name: "Release", trigger: Trigger(tag: "v*"))
    func add(_ step: ReleaseStep, to workflow: inout Workflow) {
      workflow.steps.append(Step(id: step.rawValue, name: step.title, kind: .release, releaseStep: step.rawValue))
    }
    add(.build, to: &release)
    if hasTests { add(.test, to: &release) }
    if hasScreenshots {
      release.steps.append(Step(id: "screenshots", name: "Screenshots", kind: .screenshots))
    }
    add(.archive, to: &release)
    if !(config?["DIRECT_DOWNLOAD"] ?? "").isEmpty { add(.direct, to: &release) }
    if !(config?["GITHUB_REPO"] ?? "").isEmpty { add(.github, to: &release) }
    if config?["APP_STORE"] == "yes" { add(.appstore, to: &release) }

    var check = Workflow(id: "pull-request", name: "Pull Request", trigger: Trigger(branch: "main"))
    add(.build, to: &check)
    if hasTests { add(.test, to: &check) }
    return [check, release]
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
