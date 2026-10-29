//
//  WorkflowStore.swift
//  Dev
//

import CryptoKit
import Foundation
import Observation
import VaultKit

/// Every project's workflows, their run history, the run in flight and the
/// triggers that start runs on their own. Owned once by ContentView.
///
/// A run executes its steps in order; a step marked `parallel` runs together
/// with the one before it (Test on this Mac and on two VMs at once). release.sh
/// steps run through the bundled script, a Windows or Linux one with the VM as
/// its `--host` (release.sh copies the sources there and brings the packages
/// back); commands run in a login shell in the project folder, and VM commands
/// through `VMRunner.process`, which copies the project into the VM first. Every
/// release.sh step of a run writes to the run's own folder, and the files they
/// report are the run's artifacts, kept in the history until deleted. Steps that
/// publish (notarize, GitHub, App Store Connect, the stores) ask before they
/// start unless the reader started the run and confirmed it up front.
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
  /// The window's vault; set by ContentView.
  @ObservationIgnored var vault: Vault?
  /// The account each run in flight releases with (`VaultProjects.account(of:)`), by project folder.
  @ObservationIgnored private var accounts: [URL: String] = [:]

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
    // Taken at the start, so switching the window's account doesn't change a run in flight.
    accounts[root] = VaultProjects.of(vault ?? .shared).account(of: root)
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
      $0.output = Self.outputFolder(for: $0, in: root).path
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
      trimHistory(root)
    }
    active[root] = nil
    tasks[root] = nil
    processes[root] = nil
    accounts[root] = nil
    saveHistory()
  }

  /// Runs one step and answers whether it passed.
  private func run(_ step: Workflow.Step, runID: UUID, root: URL) async -> Bool {
    setStep(root, step.id) { $0.state = .running; $0.startedAt = Date() }
    let version = active[root]?.version
    var passed: Bool
    switch step.kind {
    case .release:
      passed = await runRelease(step, step.releaseStep ?? "", runID: runID, root: root, version: version)
    case .screenshots:
      passed = await runRelease(step, "screenshots", runID: runID, root: root, version: version)
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

  private func runRelease(_ step: Workflow.Step, _ name: String, runID: UUID, root: URL, version: String?) async -> Bool {
    let stepID = step.id
    guard let script = ReleaseRunner.scriptURL else {
      setStep(root, stepID) { $0.note = "release.sh is missing from the app" }
      return false
    }
    var arguments = [script.path, "--project", root.path]
    if let output = active[root]?.output { arguments += ["--output", output] }
    if let platform = step.platform { arguments += ["--platform", platform] }
    // Windows and Linux build on their VM: release.sh copies the sources there and brings the packages back.
    if let vmName = step.vmName {
      guard let target = await vmTarget(vmName, stepID: stepID, runID: runID, root: root) else { return false }
      arguments += ["--host", target.target]
    }
    if let version { arguments += ["--version", version] }
    arguments.append(name)
    // The GitHub step publishes with the sign-in of the project's account.
    let environment = ReleaseRunner.environment(forAccount: accounts[root] ?? VaultAccount.personal.id)
    let process = LineProcess("/bin/bash", arguments, directory: root, environment: environment)
    let status = await stream(process, stepID: stepID, runID: runID, root: root) { [weak self] line in
      // release.sh's markers: a skipped step passes, a failed one says why, an artifact joins the run.
      guard line.hasPrefix("::") else { return }
      if let artifact = WorkflowRun.Artifact(marker: line, stepID: stepID) {
        self?.update(root) { run in
          var files = run.files.filter { $0.path != artifact.path }
          files.append(artifact)
          run.artifacts = files
        }
        return
      }
      let parts = line.dropFirst(2).split(separator: " ", maxSplits: 2).map(String.init)
      if parts.first == "skip" {
        self?.setStep(root, stepID) { $0.state = .skipped; $0.note = parts.count > 2 ? parts[2] : nil }
      } else if parts.first == "fail" {
        self?.setStep(root, stepID) { $0.note = parts.count > 2 ? parts[2] : nil }
      }
    }
    await measureArtifacts(of: stepID, in: root)
    return status == 0
  }

  /// The sizes of a step's files, read off the main thread once it has finished.
  private func measureArtifacts(of stepID: String, in root: URL) async {
    let files = active[root]?.files.filter { $0.stepID == stepID } ?? []
    guard !files.isEmpty else { return }
    let sizes = await Task.detached(priority: .utility) {
      Dictionary(files.map { ($0.path, WorkflowRun.Artifact.size(of: $0.url)) }, uniquingKeysWith: { a, _ in a })
    }.value
    update(root) { run in
      run.artifacts = run.files.map { file in
        var file = file
        if let size = sizes[file.path] { file.size = size }
        return file
      }
    }
  }

  private func runOnVM(_ step: Workflow.Step, vmName: String, runID: UUID, root: URL) async -> Bool {
    guard let target = await vmTarget(vmName, stepID: step.id, runID: runID, root: root) else { return false }
    let process = VMRunner.process(
      project: root, on: target.target, system: target.system,
      command: step.command ?? VMRunner.defaultCommand(for: root, system: target.system))
    return await stream(process, stepID: step.id, runID: runID, root: root) == 0
  }

  /// Where a step reaches a UTM machine over SSH (`user@address`) and its system, starting it first when it is
  /// off; nil, with the step's note saying why, when it can't be reached.
  private func vmTarget(
    _ vmName: String, stepID: String, runID: UUID, root: URL
  ) async -> (target: String, system: VirtualMachine.System)? {
    guard let store = vms else { return nil }
    if store.machines.isEmpty { await store.refresh() }
    guard let vm = store.machines.first(where: { $0.name == vmName }) else {
      setStep(root, stepID) { $0.note = "no UTM machine named \(vmName)" }
      return nil
    }
    if !vm.status.isRunning {
      append(runID, stepID, root, "Starting \(vm.name)…")
      await store.start(vm)
    }
    var address: String?
    for _ in 0..<30 {
      address = await store.address(of: vm)
      if address != nil { break }
      try? await Task.sleep(for: .seconds(4))
      if Task.isCancelled { return nil }
    }
    guard let address else {
      setStep(root, stepID) { $0.note = "no address for \(vm.name)" }
      return nil
    }
    let settings = VMSettings.load(vm.id)
    let user = settings.user.isEmpty ? VMStore.sshUser(for: vm) : settings.user
    return ("\(user)@\(address)", settings.system ?? vm.guessedSystem)
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

  // MARK: - Release history

  /// A run's own folder for release.sh's `--output`: `build/release/runs/<date>-<build>` in the project.
  static func outputFolder(for run: WorkflowRun, in root: URL) -> URL {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd-HHmmss"
    let name = formatter.string(from: run.startedAt) + (run.buildNumber.map { "-\($0)" } ?? "")
    return root.appendingPathComponent("build/release/runs/\(name)", isDirectory: true)
  }

  /// A finished run, by id.
  func run(_ id: UUID, in root: URL) -> WorkflowRun? {
    history[root]?.first { $0.id == id }
  }

  /// Whether Dev may delete an artifact: a file in the run's own folder (screenshots, say, live in the project).
  static func canDelete(_ artifact: WorkflowRun.Artifact, of run: WorkflowRun) -> Bool {
    guard let output = run.output else { return false }
    return artifact.path.hasPrefix(output + "/")
  }

  /// Moves a finished run's folder (every file it made there) to the Trash and drops the run from the history.
  func deleteRun(_ id: UUID, in root: URL) throws {
    guard let run = run(id, in: root) else { return }
    if let output = run.output, FileManager.default.fileExists(atPath: output) {
      try FileManager.default.trashItem(at: URL(fileURLWithPath: output), resultingItemURL: nil)
    }
    history[root]?.removeAll { $0.id == id }
    logs[id] = nil
    saveHistory()
  }

  /// Moves one artifact of a finished run to the Trash.
  func deleteArtifact(_ artifact: WorkflowRun.Artifact, of id: UUID, in root: URL) throws {
    guard let index = history[root]?.firstIndex(where: { $0.id == id }) else { return }
    if FileManager.default.fileExists(atPath: artifact.path) {
      try FileManager.default.trashItem(at: artifact.url, resultingItemURL: nil)
    }
    history[root]![index].artifacts = history[root]![index].files.filter { $0.path != artifact.path }
    saveHistory()
  }

  /// The run's result archive, made now (release.sh's bundle step over its folder) when its workflow had no
  /// Result Archive step; nil, with the reason in `notice`, when it can't be made.
  func makeBundle(for id: UUID, in root: URL) async -> WorkflowRun.Artifact? {
    guard let run = run(id, in: root) else { return nil }
    if let bundle = run.bundle, FileManager.default.fileExists(atPath: bundle.path) { return bundle }
    guard let script = ReleaseRunner.scriptURL, let output = run.output else { return nil }
    var arguments = [script.path, "--project", root.path, "--output", output]
    if let version = run.version { arguments += ["--version", version] }
    arguments.append("bundle")
    let process = LineProcess("/bin/bash", arguments, directory: root)
    var made: [WorkflowRun.Artifact] = []
    var failure: String?
    do {
      for try await line in process.lines() {
        if let artifact = WorkflowRun.Artifact(marker: line, stepID: "bundle") { made.append(artifact) }
        if line.hasPrefix("::fail ") { failure = line.split(separator: " ", maxSplits: 2).dropFirst(2).first.map(String.init) }
      }
    } catch {
      failure = error.localizedDescription
    }
    guard process.status == 0, !made.isEmpty else {
      notice = "No result archive: \(failure ?? "release.sh bundle failed")."
      return nil
    }
    let sized = await Task.detached(priority: .utility) {
      made.map { file in
        var file = file
        file.size = WorkflowRun.Artifact.size(of: file.url)
        return file
      }
    }.value
    guard let index = history[root]?.firstIndex(where: { $0.id == id }) else { return nil }
    let paths = Set(sized.map(\.path))
    history[root]![index].artifacts = history[root]![index].files.filter { !paths.contains($0.path) } + sized
    saveHistory()
    return sized.first { $0.kind == "bundle" }
  }

  /// Keeps the newest 50 runs, and every older one that still has files (they go when the reader deletes them).
  private func trimHistory(_ root: URL) {
    guard var runs = history[root], runs.count > 50 else { return }
    var kept = 0
    runs = runs.filter { run in
      kept += 1
      return kept <= 50 || !run.files.isEmpty
    }
    history[root] = runs
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
