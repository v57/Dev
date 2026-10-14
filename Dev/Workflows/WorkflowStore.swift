//
//  WorkflowStore.swift
//  Dev
//

import CryptoKit
import Foundation
import Observation

/// Every project's workflows, their run history, the run in flight and the
/// triggers that start runs on their own. Owned once by ContentView.
///
/// A run executes its steps in order; a step marked `parallel` runs together
/// with the one before it (Test on this Mac and on two VMs at once). release.sh
/// steps run through the bundled script, commands in a login shell in the
/// project folder, and VM commands through `VMRunner.process`, which copies the
/// project into the VM first. Steps that publish (notarize, GitHub, App Store
/// Connect) ask before they start unless the reader started the run and
/// confirmed it up front.
@Observable
final class WorkflowStore {
  /// The workflows read from each project's `.dev/workflows`.
  private(set) var workflows: [URL: [Workflow]] = [:]
  /// Each project's finished runs, newest first, and the one in flight.
  private(set) var history: [URL: [WorkflowRun]] = [:]
  /// The run in flight per project (at most one).
  private(set) var active: [URL: WorkflowRun] = [:]
  /// The full log of each step of the runs this session made: run id → step id → lines.
  private(set) var logs: [UUID: [String: [String]]] = [:]
  /// A publishing step waiting for the reader's go-ahead.
  private(set) var confirmation: Confirmation?
  /// Why the last start was refused, shown once.
  var notice: String?

  struct Confirmation: Identifiable {
    let id = UUID()
    let root: URL
    let workflowName: String
    let steps: [String]
    let startedBy: String
    fileprivate let answer: (Bool) -> Void
  }

  /// The VMs a step can run on; set by ContentView.
  @ObservationIgnored weak var vms: VMStore?
  @ObservationIgnored private var tasks: [URL: Task<Void, Never>] = [:]
  @ObservationIgnored private var processes: [URL: [LineProcess]] = [:]
  @ObservationIgnored private var triggerTimer: Timer?
  /// The project folders the triggers watch; set from the sidebar's projects.
  @ObservationIgnored var watchedRoots: [URL] = []

  init() {
    loadHistory()
    triggerTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.checkTriggers() }
    }
  }

  // MARK: - Workflows

  func workflows(for root: URL) -> [Workflow] {
    if let known = workflows[root] { return known }
    let loaded = Workflow.load(in: root)
    workflows[root] = loaded
    return loaded
  }

  func reload(_ root: URL) {
    workflows[root] = Workflow.load(in: root)
  }

  /// Writes a workflow (and, the first time, the defaults beside it, so the
  /// folder always holds every workflow the tab shows).
  func save(_ workflow: Workflow, in root: URL) throws {
    var all = workflows(for: root)
    let onDisk = FileManager.default.fileExists(atPath: Workflow.folder(in: root).path)
    if let index = all.firstIndex(where: { $0.id == workflow.id }) {
      all[index] = workflow
    } else {
      all.append(workflow)
    }
    if !onDisk {
      for other in all where other.id != workflow.id { try other.save(in: root) }
    }
    try workflow.save(in: root)
    workflows[root] = all.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  func delete(_ id: String, in root: URL) {
    Workflow.delete(id, in: root)
    workflows[root]?.removeAll { $0.id == id }
  }

  // MARK: - Runs

  func runs(for root: URL) -> [WorkflowRun] {
    (active[root].map { [$0] } ?? []) + (history[root] ?? [])
  }

  func isRunning(_ root: URL) -> Bool { active[root] != nil }

  /// The last finished run of a workflow, for the Overview.
  func lastRun(of workflowID: String, in root: URL) -> WorkflowRun? {
    runs(for: root).first { $0.workflowID == workflowID }
  }

  /// Starts a run. `confirmedPublishing` is true when the reader already agreed
  /// to the publishing steps (the Run button asks before calling this).
  func start(
    _ workflow: Workflow, in root: URL, version: String? = nil, startedBy: String = "you",
    confirmedPublishing: Bool = false
  ) {
    guard active[root] == nil else {
      notice = "\(root.lastPathComponent) already has a run in flight."
      return
    }
    var run = WorkflowRun(workflowID: workflow.id, workflowName: workflow.name, startedBy: startedBy)
    run.version = version?.trimmingCharacters(in: .whitespaces).nilIfEmpty
    run.steps = workflow.steps.map {
      WorkflowRun.StepRun(id: $0.id, name: $0.name, runner: $0.runnerTitle)
    }
    active[root] = run
    logs[run.id] = [:]
    tasks[root] = Task { [weak self] in
      await self?.execute(workflow, runID: run.id, root: root, confirmedPublishing: confirmedPublishing)
    }
  }

  func cancel(_ root: URL) {
    processes[root]?.forEach { $0.terminate() }
    tasks[root]?.cancel()
  }

  private func execute(_ workflow: Workflow, runID: UUID, root: URL, confirmedPublishing: Bool) async {
    let count = await LineProcess.run("/usr/bin/git", ["rev-list", "--count", "HEAD"], directory: root)
    let commit = await LineProcess.run("/usr/bin/git", ["rev-parse", "--short", "HEAD"], directory: root)
    update(root) {
      $0.buildNumber = Int(count.output.trimmingCharacters(in: .whitespacesAndNewlines))
      $0.commit = commit.status == 0 ? commit.output.trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }

    // Stages: a step marked parallel joins the stage before it.
    var stages: [[Workflow.Step]] = []
    for step in workflow.steps {
      if step.parallel, !stages.isEmpty { stages[stages.count - 1].append(step) } else { stages.append([step]) }
    }

    var failed = false
    for stage in stages {
      if Task.isCancelled { break }
      if failed && !workflow.continueOnFailure {
        for step in stage { setStep(root, step.id) { $0.state = .skipped; $0.note = "an earlier step failed" } }
        continue
      }
      let publishing = stage.filter(\.publishes)
      if !publishing.isEmpty, !confirmedPublishing {
        let ok = await ask(root: root, workflow: workflow.name, steps: publishing.map(\.name))
        if !ok {
          for step in stage { setStep(root, step.id) { $0.state = .skipped; $0.note = "not confirmed" } }
          failed = true
          continue
        }
      }
      let results = await withTaskGroup(of: Bool.self) { group in
        for step in stage {
          group.addTask { @MainActor [weak self] in
            await self?.run(step, runID: runID, root: root) ?? false
          }
        }
        var all: [Bool] = []
        for await result in group { all.append(result) }
        return all
      }
      if results.contains(false) { failed = true }
    }

    let cancelled = Task.isCancelled
    update(root) { run in
      for index in run.steps.indices where run.steps[index].state == .waiting || run.steps[index].state == .running {
        run.steps[index].state = cancelled ? .skipped : run.steps[index].state
        if cancelled { run.steps[index].note = "cancelled" }
      }
      run.finishedAt = Date()
      run.state = cancelled ? .cancelled : (failed ? .failed : .passed)
    }
    if let finished = active[root] {
      history[root, default: []].insert(finished, at: 0)
      if history[root]!.count > 50 { history[root]!.removeLast(history[root]!.count - 50) }
    }
    active[root] = nil
    tasks[root] = nil
    processes[root] = nil
    saveHistory()
  }

  /// Runs one step and answers whether it passed.
  private func run(_ step: Workflow.Step, runID: UUID, root: URL) async -> Bool {
    setStep(root, step.id) { $0.state = .running; $0.startedAt = Date() }
    let version = active[root]?.version
    var passed: Bool
    switch step.kind {
    case .release:
      passed = await runRelease(step.releaseStep ?? "", stepID: step.id, runID: runID, root: root, version: version)
    case .screenshots:
      passed = await runRelease("screenshots", stepID: step.id, runID: runID, root: root, version: version)
      if passed {
        append(runID, step.id, root, "Framing with .dev/screenshots.json")
        let report = await ScreenshotProcessor.processLatest(in: root)
        for line in report.lines { append(runID, step.id, root, line) }
        passed = report.succeeded
      }
    case .command:
      if let vmName = step.vmName {
        passed = await runOnVM(step, vmName: vmName, runID: runID, root: root)
      } else {
        let process = LineProcess("/bin/bash", ["-lc", step.command ?? ""], directory: root)
        passed = await stream(process, stepID: step.id, runID: runID, root: root) == 0
      }
    }
    setStep(root, step.id) {
      $0.finishedAt = Date()
      if $0.state == .running { $0.state = passed ? .passed : .failed }
    }
    return passed
  }

  private func runRelease(_ name: String, stepID: String, runID: UUID, root: URL, version: String?) async -> Bool {
    guard let script = ReleaseRunner.scriptURL else {
      setStep(root, stepID) { $0.note = "release.sh is missing from the app" }
      return false
    }
    var arguments = [script.path, "--project", root.path]
    if let version { arguments += ["--version", version] }
    arguments.append(name)
    let process = LineProcess("/bin/bash", arguments, directory: root)
    let status = await stream(process, stepID: stepID, runID: runID, root: root) { [weak self] line in
      // release.sh's markers: a skipped step passes, a failed one says why.
      guard line.hasPrefix("::") else { return }
      let parts = line.dropFirst(2).split(separator: " ", maxSplits: 2).map(String.init)
      if parts.first == "skip" {
        self?.setStep(root, stepID) { $0.state = .skipped; $0.note = parts.count > 2 ? parts[2] : nil }
      } else if parts.first == "fail" {
        self?.setStep(root, stepID) { $0.note = parts.count > 2 ? parts[2] : nil }
      }
    }
    return status == 0
  }

  private func runOnVM(_ step: Workflow.Step, vmName: String, runID: UUID, root: URL) async -> Bool {
    guard let store = vms else { return false }
    if store.machines.isEmpty { await store.refresh() }
    guard let vm = store.machines.first(where: { $0.name == vmName }) else {
      setStep(root, step.id) { $0.note = "no UTM machine named \(vmName)" }
      return false
    }
    if !vm.status.isRunning {
      append(runID, step.id, root, "Starting \(vm.name)…")
      await store.start(vm)
    }
    var address: String?
    for _ in 0..<30 {
      address = await store.address(of: vm)
      if address != nil { break }
      try? await Task.sleep(for: .seconds(4))
      if Task.isCancelled { return false }
    }
    guard let address else {
      setStep(root, step.id) { $0.note = "no address for \(vm.name)" }
      return false
    }
    let settings = VMSettings.load(vm.id)
    let user = settings.user.isEmpty ? VMStore.sshUser(for: vm) : settings.user
    let system = settings.system ?? vm.guessedSystem
    let process = VMRunner.process(
      project: root, on: "\(user)@\(address)", system: system,
      command: step.command ?? VMRunner.defaultCommand(for: root, system: system))
    return await stream(process, stepID: step.id, runID: runID, root: root) == 0
  }

  /// Streams a process into the step's log; answers its exit code.
  private func stream(
    _ process: LineProcess, stepID: String, runID: UUID, root: URL, onLine: ((String) -> Void)? = nil
  ) async -> Int32 {
    processes[root, default: []].append(process)
    do {
      for try await line in process.lines() {
        append(runID, stepID, root, line)
        onLine?(line)
      }
    } catch {
      append(runID, stepID, root, "could not start: \(error.localizedDescription)")
      return -1
    }
    return process.status ?? -1
  }

  private func append(_ runID: UUID, _ stepID: String, _ root: URL, _ line: String) {
    logs[runID, default: [:]][stepID, default: []].append(line)
    if logs[runID]![stepID]!.count > 20_000 { logs[runID]![stepID]!.removeFirst(5_000) }
    setStep(root, stepID) { step in
      step.logTail.append(line)
      if step.logTail.count > 12 { step.logTail.removeFirst(step.logTail.count - 12) }
    }
  }

  private func update(_ root: URL, _ change: (inout WorkflowRun) -> Void) {
    guard var run = active[root] else { return }
    change(&run)
    active[root] = run
  }

  private func setStep(_ root: URL, _ stepID: String, _ change: (inout WorkflowRun.StepRun) -> Void) {
    update(root) { run in
      guard let index = run.steps.firstIndex(where: { $0.id == stepID }) else { return }
      change(&run.steps[index])
    }
  }

  // MARK: - Confirmation

  private func ask(root: URL, workflow: String, steps: [String]) async -> Bool {
    let startedBy = active[root]?.startedBy ?? "you"
    return await withCheckedContinuation { continuation in
      confirmation = Confirmation(root: root, workflowName: workflow, steps: steps, startedBy: startedBy) {
        continuation.resume(returning: $0)
      }
    }
  }

  func answer(_ confirmation: Confirmation, _ ok: Bool) {
    self.confirmation = nil
    confirmation.answer(ok)
  }

  // MARK: - Triggers

  /// Starts the runs whose trigger fired: a new commit on the watched branch, a
  /// new tag that matches, or the daily time passing.
  func checkTriggers() {
    guard !LaunchOptions.isScreenshotMode else { return }
    for root in watchedRoots where active[root] == nil {
      for workflow in workflows(for: root) {
        let trigger = workflow.trigger
        guard trigger.branch != nil || trigger.tag != nil || trigger.daily != nil else { continue }
        Task { [weak self] in
          guard let self, let reason = await self.firedTrigger(workflow, in: root) else { return }
          guard self.active[root] == nil else { return }
          self.start(workflow, in: root, startedBy: reason)
        }
      }
    }
  }

  private func firedTrigger(_ workflow: Workflow, in root: URL) async -> String? {
    let defaults = UserDefaults.standard
    let key = "workflow.trigger.\(Self.hash(root)).\(workflow.id)"
    if let branch = workflow.trigger.branch, !branch.isEmpty {
      let head = await LineProcess.run("/usr/bin/git", ["rev-parse", branch], directory: root)
      let sha = head.output.trimmingCharacters(in: .whitespacesAndNewlines)
      if head.status == 0, !sha.isEmpty {
        let seen = defaults.string(forKey: key + ".branch")
        defaults.set(sha, forKey: key + ".branch")
        if let seen, seen != sha { return "commit on \(branch)" }
      }
    }
    if let pattern = workflow.trigger.tag, !pattern.isEmpty {
      let tags = await LineProcess.run("/usr/bin/git", ["tag", "--list", pattern, "--sort=-creatordate"], directory: root)
      let newest = tags.output.split(separator: "\n").first.map(String.init) ?? ""
      if tags.status == 0, !newest.isEmpty {
        let seen = defaults.string(forKey: key + ".tag")
        defaults.set(newest, forKey: key + ".tag")
        if let seen, seen != newest { return "tag \(newest)" }
      }
    }
    if let daily = workflow.trigger.daily, let time = Self.time(daily) {
      let calendar = Calendar.current
      let now = Date()
      guard let due = calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: now),
            now >= due else { return nil }
      let last = defaults.object(forKey: key + ".daily") as? Date ?? .distantPast
      if last < due {
        defaults.set(now, forKey: key + ".daily")
        return "schedule"
      }
    }
    return nil
  }

  private static func time(_ text: String) -> (hour: Int, minute: Int)? {
    let parts = text.split(separator: ":").compactMap { Int($0) }
    guard parts.count == 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) else { return nil }
    return (parts[0], parts[1])
  }

  // MARK: - History

  private static func hash(_ root: URL) -> String {
    SHA256.hash(data: Data(root.standardizedFileURL.path.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
  }

  private static var historyURL: URL? {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
      .appendingPathComponent(Bundle.main.bundleIdentifier ?? "dev.v57.dev", isDirectory: true)
      .appendingPathComponent("Workflows/history.json")
  }

  private func loadHistory() {
    guard !LaunchOptions.isScreenshotMode, let url = Self.historyURL, let data = try? Data(contentsOf: url),
          let saved = try? JSONDecoder().decode([String: [WorkflowRun]].self, from: data)
    else { return }
    history = Dictionary(uniqueKeysWithValues: saved.map { (URL(fileURLWithPath: $0.key), $0.value) })
  }

  private func saveHistory() {
    // A screenshot or test launch keeps its runs to itself.
    guard !LaunchOptions.isScreenshotMode, let url = Self.historyURL else { return }
    let saved = Dictionary(uniqueKeysWithValues: history.map { ($0.key.path, $0.value) })
    Task.detached(priority: .background) {
      try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try? JSONEncoder().encode(saved).write(to: url, options: .atomic)
    }
  }
}

nonisolated extension String {
  var nilIfEmpty: String? { isEmpty ? nil : self }
}
