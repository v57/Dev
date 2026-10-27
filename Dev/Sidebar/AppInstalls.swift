//
//  AppInstalls.swift
//  Dev
//

import DevDesktop
import CodeActions
import CodeWorkspace
import Foundation
import Observation
import PlatformBroadcast

/// The sidebar's Install buttons: a project's Mac app built and put in place on this Mac by Code's install action
/// (`AppInstall`: archive, quit the running copy, replace it in ~/Applications or /Applications, open it again).
///
/// Installs wait in one queue and run one at a time at low priority (`LowPriorityExecutor`), so the Mac stays usable;
/// a queued or running one can be cancelled. The button shows only while the source is newer than the installed app
/// (`InstallStatus`): an install records the fingerprint of the project and the local packages its build uses
/// (`SourceFingerprint`, `LocalDependencies`), and a change in any of those folders (watched with FSEvents) brings the
/// button back. The installed app's build number (the commit count) answers first when it's older.
@Observable final class AppInstalls {
  static let shared = AppInstalls()

  /// What a project's row shows.
  enum Phase: Equatable {
    /// No Mac app to install, or not looked at yet: nothing.
    case none
    case current
    /// The source is newer than the installed app, or there's none (`installed` false).
    case available(installed: Bool)
    /// Waiting its turn; 1 is next.
    case queued(position: Int)
    case installing(step: String?, progress: ActionProgress?)
    case failed(String)
  }

  /// A project with a Mac app to install.
  struct Project {
    var scheme: ActionScheme
    /// The folders its build reads: its own and its local packages'.
    var folders: [URL]
    /// Nil until checked.
    var status: InstallStatus?
  }

  /// By project folder path.
  private(set) var projects: [String: Project] = [:]
  /// Project folder paths waiting to install, first next.
  private(set) var queue: [String] = []
  /// The project installing now.
  private(set) var current: String?
  /// Its action: step, progress and log.
  private(set) var controller: ActionController?
  /// Why the last install of a project failed.
  private(set) var failures: [String: String] = [:]
  /// What the running install asks before it goes on (quitting the app), answered with `answer(_:)`.
  private(set) var question: String?

  @ObservationIgnored private var answerContinuation: CheckedContinuation<Bool, Never>?
  @ObservationIgnored private var store = Store.load()
  @ObservationIgnored private var watchers: [String: FileWatcher] = [:]
  /// Each watched folder's part of the fingerprints, until it changes.
  @ObservationIgnored private var folderStates: [String: SourceFingerprint] = [:]
  @ObservationIgnored private var staleFolders: Set<String> = []
  @ObservationIgnored private var staleProjects: Set<String> = []
  @ObservationIgnored private var refreshTask: Task<Void, Never>?
  @ObservationIgnored private var scanTask: Task<Void, Never>?
  @ObservationIgnored private var tracked: [URL] = []
  @ObservationIgnored private var lastCheckAll = Date.distantPast
  @ObservationIgnored private var activation: AnyObject?

  private init() {
    // Another app may have installed or removed one meanwhile.
    activation = DevDesktop.onActivation {
      Task { @MainActor in AppInstalls.shared.checkAllIfStale() }
    }
    #if DEBUG
      Task { await listenForDebugCommands() }
    #endif
  }

  #if DEBUG
    /// Debug builds take commands without a click: post the distributed notification `dev.v57.dev.install` with
    /// `install <project folder>`, `cancel <project folder>`, `answer yes|no`, `check` or `dump` (each project's
    /// phase and the queue, to /tmp/dev-installs.txt).
    private func listenForDebugCommands() async {
      for await note in Broadcast.messages(named: "dev.v57.dev.install") {
        guard let command = note[Broadcast.objectKey] else { continue }
        let parts = command.split(separator: " ", maxSplits: 1).map(String.init)
        let root = parts.count == 2 ? URL(fileURLWithPath: parts[1]) : nil
        switch parts.first {
        case "install": install(root)
        case "cancel": cancel(root)
        case "answer": answer(parts.last == "yes")
        case "check":
          staleFolders.formUnion(folderStates.keys)
          for path in projects.keys { check(path) }
        case "dump":
          var lines = projects.keys.sorted().map { path in
            "\(path)\t\(projects[path]!.scheme.name)\t\(phase(for: URL(fileURLWithPath: path)))\t"
              + projects[path]!.folders.map(\.lastPathComponent).joined(separator: ",")
          }
          lines.append("queue: \(queue) current: \(current ?? "-") question: \(question ?? "-") watchers: \(watchers.count)")
          if let root, let project = projects[root.standardizedFileURL.path] {
            let record = store.records[root.standardizedFileURL.path]
            let installed = InstalledApp(at: AppInstall.destination(of: project.scheme))
            let source = SourceFingerprint.of(project.scheme)
            var states: [String: SourceFingerprint] = [:]
            lines.append(
              "source: \(source) recorded: \(record.map { "\($0.fingerprint) \($0.app)" } ?? "-") installed: \(installed.map { "\($0)" } ?? "-")"
                + " now: \(Self.status(of: project, record: record, states: &states))")
          }
          if let controller { lines.append("state: \(controller.state) log: \(controller.log.entries.suffix(3).map(\.text))") }
          try? lines.joined(separator: "\n").write(toFile: "/tmp/dev-installs.txt", atomically: true, encoding: .utf8)
        default: break
        }
      }
    }
  #endif

  // MARK: - Projects

  /// Follows the sidebar's projects: finds each one's Mac app (once per change of its top-level files), watches its
  /// folders and checks whether the installed app is current.
  func track(_ roots: [URL]) {
    guard !LaunchOptions.isScreenshotMode else { return }
    let roots = roots.map(\.standardizedFileURL)
    guard roots != tracked else { return }
    tracked = roots
    let paths = Set(roots.map(\.path))
    for path in projects.keys where !paths.contains(path) && path != current && !queue.contains(path) {
      projects[path] = nil
    }
    let cached = store.schemes
    scanTask?.cancel()
    scanTask = Task {
      // One project at a time: `xcodebuild -list` is slow and busy.
      for root in roots {
        let found = await Task.detached(priority: .utility) { Self.installableScheme(in: root, cached: cached[root.path]) }
          .value
        guard !Task.isCancelled else { return }
        store.schemes[root.path] = found
        guard let scheme = found.scheme else {
          projects[root.path] = nil
          continue
        }
        let previous = projects[root.path]
        if previous?.scheme != scheme {
          let folders = await Task.detached(priority: .utility) { LocalDependencies.folders(of: scheme) }.value
          projects[root.path] = Project(scheme: scheme, folders: folders, status: previous?.status)
        }
        check(root.path)
      }
      store.save()
      rewatch()
      lastCheckAll = Date()
    }
  }

  /// What `root`'s row shows.
  func phase(for root: URL?) -> Phase {
    guard let path = root?.standardizedFileURL.path, let project = projects[path] else { return .none }
    if current == path { return .installing(step: controller?.stepTitle, progress: controller?.progress) }
    if let index = queue.firstIndex(of: path) { return .queued(position: index + 1) }
    if let failure = failures[path] { return .failed(failure) }
    switch project.status {
    case nil: return .none
    case .current?: return .current
    case .notInstalled?: return .available(installed: false)
    case .outdated?: return .available(installed: true)
    }
  }

  /// Whether `root` has a Mac app to install.
  func canInstall(_ root: URL?) -> Bool {
    root.map { projects[$0.standardizedFileURL.path] != nil } ?? false
  }

  /// The app's name, for menus ("Dev").
  func appName(_ root: URL?) -> String? {
    root.flatMap { projects[$0.standardizedFileURL.path] }.map {
      AppInstall.destination(of: $0.scheme).deletingPathExtension().lastPathComponent
    }
  }

  /// The scheme in `root` whose app installs: the one named after the folder, else the first (the detector ranks the
  /// main one first). Cached while the folder's top-level files are the same.
  nonisolated static func installableScheme(in root: URL, cached: CachedScheme?) -> CachedScheme {
    let folder = ProjectFolder(listing: root)
    let fingerprint = ProjectScanner.fingerprint(of: folder)
    if let cached, cached.fingerprint == fingerprint { return cached }
    let schemes = ProjectScanner.schemes(in: folder).filter { $0.supports(.install) }
    let scheme = schemes.first { $0.name == root.lastPathComponent } ?? schemes.first
    return CachedScheme(fingerprint: fingerprint, scheme: scheme)
  }

  // MARK: - Checking

  /// Checks `path`'s installed app against its source again, off the main thread, after `delay` (changes come in
  /// bursts). Checks gather into one refresh at a time, which reads each changed folder once for every project that
  /// uses it.
  private func check(_ path: String, after delay: Duration = .zero) {
    guard projects[path] != nil else { return }
    staleProjects.insert(path)
    guard refreshTask == nil else { return }
    refreshTask = Task {
      if delay > .zero { try? await Task.sleep(for: delay) }
      // Checks asked for while one runs follow it.
      while !staleProjects.isEmpty {
        let jobs = staleProjects.compactMap { path in
          projects[path].map { (path: path, project: $0, record: store.records[path]) }
        }
        staleProjects = []
        for folder in staleFolders { folderStates[folder] = nil }
        staleFolders = []
        let known = folderStates
        let (statuses, states) = await Task.detached(priority: .utility) {
          var states = known
          var statuses: [String: InstallStatus] = [:]
          for job in jobs { statuses[job.path] = Self.status(of: job.project, record: job.record, states: &states) }
          return (statuses, states)
        }.value
        // A folder that changed meanwhile is read again by the next round.
        folderStates = states.filter { !staleFolders.contains($0.key) }
        for job in jobs where projects[job.path]?.scheme == job.project.scheme {
          projects[job.path]?.status = statuses[job.path]
        }
      }
      refreshTask = nil
    }
  }

  /// Whether the app installed for `project` is its source's, reading the folders `states` doesn't know yet.
  nonisolated static func status(
    of project: Project, record: InstallRecord?, states: inout [String: SourceFingerprint]
  ) -> InstallStatus {
    InstallStatus.evaluate(
      installed: InstalledApp(at: AppInstall.destination(of: project.scheme)), record: record,
      sourceBuild: SourceFingerprint.commitCount(in: project.scheme.directory)
    ) {
      let parts = project.folders.map { folder in
        if let known = states[folder.path] { return (folder, known) }
        let state = SourceFingerprint.folder(folder)
        states[folder.path] = state
        return (folder, state)
      }
      return SourceFingerprint.combine(parts, salt: project.scheme.name)
    }
  }

  private func checkAllIfStale() {
    guard Date().timeIntervalSince(lastCheckAll) > 30 else { return }
    lastCheckAll = Date()
    for path in projects.keys { check(path) }
  }

  /// Watches every folder a project's build reads; a change checks the projects that read it again.
  private func rewatch() {
    let folders = Set(projects.values.flatMap { $0.folders.map(\.path) })
    for path in watchers.keys where !folders.contains(path) { watchers[path] = nil }
    for path in folders where watchers[path] == nil {
      watchers[path] = FileWatcher(root: URL(fileURLWithPath: path), latency: 1, fileEvents: false) { changes in
        AppInstalls.shared.changed(in: path, changes)
      }
    }
  }

  /// Folders whose changes aren't the source's: build output, Git's own files, caches.
  static let ignoredFolders: Set<String> = [".git", "build", ".build", "DerivedData", "node_modules", ".swiftpm"]

  private func changed(in folder: String, _ changes: [FileWatcher.Change]) {
    let relevant = changes.contains { change in
      !change.url.standardizedFileURL.path.dropFirst(folder.count).split(separator: "/")
        .contains { Self.ignoredFolders.contains(String($0)) }
    }
    guard relevant else { return }
    staleFolders.insert(folder)
    for (path, project) in projects where project.folders.contains(where: { $0.path == folder }) {
      check(path, after: .seconds(2))
    }
  }

  // MARK: - Installing

  /// Queues `root`'s install; it starts when the ones before it are done.
  func install(_ root: URL?) {
    guard let path = root?.standardizedFileURL.path, projects[path] != nil, current != path, !queue.contains(path)
    else { return }
    failures[path] = nil
    queue.append(path)
    startNext()
  }

  /// Takes `root` out of the queue, or stops its install.
  func cancel(_ root: URL?) {
    guard let path = root?.standardizedFileURL.path else { return }
    queue.removeAll { $0 == path }
    guard current == path else { return }
    if question != nil { answer(false) }
    if let controller {
      controller.stop()
    } else {
      current = nil
      startNext()
    }
  }

  /// Answers the running install's question.
  func answer(_ yes: Bool) {
    let continuation = answerContinuation
    answerContinuation = nil
    question = nil
    continuation?.resume(returning: yes)
  }

  private func ask(_ text: String) async -> Bool {
    if answerContinuation != nil { answer(false) }
    return await withCheckedContinuation { continuation in
      answerContinuation = continuation
      question = text
    }
  }

  private func startNext() {
    guard current == nil, !queue.isEmpty else { return }
    let path = queue.removeFirst()
    guard let project = projects[path] else { return startNext() }
    current = path
    Task {
      // The source as it is when the build starts: a change during the build shows the button again.
      let fingerprint = await Task.detached(priority: .utility) { SourceFingerprint.of(project.scheme) }.value
      guard current == path else { return }
      let controller = ActionController(root: project.scheme.directory)
      controller.localExecutor = LowPriorityExecutor()
      controller.confirm = { question in await AppInstalls.shared.ask(question) }
      controller.addFinishHandler { [weak controller] _, succeeded in
        guard let controller else { return }
        AppInstalls.shared.finished(path, controller: controller, fingerprint: fingerprint, succeeded: succeeded)
      }
      self.controller = controller
      controller.perform(.install, scheme: project.scheme, destination: nil)
    }
  }

  private func finished(_ path: String, controller: ActionController, fingerprint: SourceFingerprint, succeeded: Bool) {
    guard current == path, let project = projects[path] else { return }
    Self.writeLog(controller.log.text, for: project.scheme)
    if succeeded, let app = InstalledApp(at: AppInstall.destination(of: project.scheme)) {
      store.records[path] = InstallRecord(fingerprint: fingerprint.value, app: app)
      store.save()
    } else if case .failed(_, _, let summary) = controller.state {
      failures[path] = summary
    }
    current = nil
    self.controller = nil
    check(path)
    startNext()
  }

  // MARK: - Log

  /// The last install's log of a project's app.
  nonisolated static func logURL(for scheme: ActionScheme) -> URL {
    URL.libraryDirectory.appendingPathComponent("Logs/Dev/Install \(scheme.projectName).log")
  }

  /// The log of `root`'s last install, when there is one.
  func logURL(_ root: URL?) -> URL? {
    guard let project = root.flatMap({ projects[$0.standardizedFileURL.path] }) else { return nil }
    let url = Self.logURL(for: project.scheme)
    return FileManager.default.fileExists(atPath: url.path) ? url : nil
  }

  private static func writeLog(_ text: String, for scheme: ActionScheme) {
    let url = logURL(for: scheme)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? Data(text.utf8).write(to: url, options: .atomic)
  }

  // MARK: - Store

  /// A project's installable scheme, found while its top-level files had `fingerprint`.
  nonisolated struct CachedScheme: Codable, Sendable {
    var fingerprint: String
    var scheme: ActionScheme?
  }

  /// What Dev keeps between launches: each project's last install and its scheme, by project folder path.
  struct Store: Codable {
    var records: [String: InstallRecord] = [:]
    var schemes: [String: CachedScheme] = [:]

    nonisolated static var url: URL {
      URL.applicationSupportDirectory.appendingPathComponent("dev.v57.dev/Installs.json")
    }

    static func load() -> Store {
      (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Store.self, from: $0) } ?? Store()
    }

    func save() {
      try? FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try? JSONEncoder().encode(self).write(to: Self.url, options: .atomic)
    }
  }
}
