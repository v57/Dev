//
//  LocalizationsStore.swift
//  Dev
//
//  The Translations tool's state and actions over the translations repository: scan the apps (an Xcode build each,
//  `StringsDataScan`), write every source's catalog (`SourceCatalogMerge`), translate a source or all of them with the
//  Localization tab's own pipeline (`LocalizationsTranslator`), then compile with the repository's `Scripts/build` and
//  commit per source. Design: plans/localizations-repo.md.
//

import CodeActions
import ComponentKit
import Foundation
import Observation
import PlatformBroadcast

/// What the tool keeps between launches (`~/Library/Application Support/dev.v57.dev/Localizations.json`): the
/// repository, the apps and their last scans, the languages and what changed since the last commit. Nothing of it
/// lives in the repository, which holds translations only.
nonisolated struct LocalizationsState: Codable, Sendable {
  var repo: String?
  var apps: [LocalizationsApp] = []
  /// The languages every source is translated into.
  var languages: [String] = LocalizationsState.defaultLanguages
  var scans: [String: AppScan] = [:]
  /// Source -> what changed since its last commit, for the commit message.
  var notes: [String: [String]] = [:]
  /// Source -> what it is, in a phrase ("a folder-based code editor for Mac, iPhone and iPad"): the model is told,
  /// so it translates for that app. Optional so a state file from before it still reads.
  var descriptions: [String: String]?

  /// The languages apps bundle by default (Ideas/Localization.md), English aside.
  static let defaultLanguages = ["de", "fr", "es", "ja", "zh-Hans", "pt-BR", "ko", "it", "ru"]

  static var url: URL {
    URL.applicationSupportDirectory.appendingPathComponent("dev.v57.dev/Localizations.json")
  }

  static func load(from url: URL = url) -> LocalizationsState {
    guard let data = try? Data(contentsOf: url) else { return LocalizationsState() }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return (try? decoder.decode(LocalizationsState.self, from: data)) ?? LocalizationsState()
  }

  func save(to url: URL = url) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    guard let data = try? encoder.encode(self) else { return }
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? data.write(to: url, options: .atomic)
  }
}

/// The translations repository: `<Source>/Localizable.xcstrings`, `Scripts/build` and `manifest.json`.
nonisolated enum LocalizationsRepo {
  /// `~/Developer/v57/Localizations` when it is there.
  static var standard: URL? {
    let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Developer/v57/Localizations")
    return isRepo(url) ? url : nil
  }

  static func isRepo(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.appendingPathComponent("Scripts/build").path)
      && FileManager.default.fileExists(atPath: url.appendingPathComponent("manifest.json").path)
  }

  static func catalog(_ source: String, in repo: URL) -> URL {
    repo.appendingPathComponent(source, isDirectory: true).appendingPathComponent("Localizable.xcstrings")
  }

  /// Whether `catalog` is a source's catalog in a translations repository: the Translations tool owns those, so the
  /// sidebar doesn't list them as projects of their own.
  static func isSourceCatalog(_ catalog: URL) -> Bool {
    isRepo(catalog.deletingLastPathComponent().deletingLastPathComponent())
  }

  /// The sources the repository has catalogs for, by folder.
  static func sources(in repo: URL) -> [String] {
    let folders = (try? FileManager.default.contentsOfDirectory(
      at: repo, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
    return folders.filter { FileManager.default.fileExists(atPath: catalog($0.lastPathComponent, in: repo).path) }
      .map(\.lastPathComponent).sorted()
  }
}

/// A command line run for the tool: its output line by line, cancellable.
nonisolated final class LocalizationsProcess: @unchecked Sendable {
  private let lock = NSLock()
  private var process: Process?
  private var cancelled = false

  /// Runs `executable` and returns its exit status; at low priority (`taskpolicy -c utility`, `nice 10`) when asked,
  /// like Dev's installs, so the Mac stays usable during a build.
  func run(
    _ executable: String, _ arguments: [String], in directory: URL?, lowPriority: Bool = false,
    onLine: @escaping @Sendable (String) -> Void
  ) async -> Int32 {
    await withCheckedContinuation { continuation in
      let process = Process()
      if lowPriority {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nice")
        process.arguments = ["-n", "10", "/usr/sbin/taskpolicy", "-c", "utility", executable] + arguments
      } else {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
      }
      process.currentDirectoryURL = directory
      let pipe = Pipe()
      process.standardOutput = pipe
      process.standardError = pipe
      let buffer = LineBuffer(onLine: onLine)
      pipe.fileHandleForReading.readabilityHandler = { handle in
        let data = handle.availableData
        if data.isEmpty {
          handle.readabilityHandler = nil
        } else {
          buffer.append(data)
        }
      }
      process.terminationHandler = { process in
        pipe.fileHandleForReading.readabilityHandler = nil
        buffer.append(pipe.fileHandleForReading.readDataToEndOfFile())
        buffer.flush()
        continuation.resume(returning: process.terminationStatus)
      }
      lock.lock()
      let wasCancelled = cancelled
      self.process = process
      lock.unlock()
      guard !wasCancelled else {
        continuation.resume(returning: -1)
        return
      }
      do {
        try process.run()
      } catch {
        onLine("error: \(error.localizedDescription)")
        continuation.resume(returning: -1)
      }
    }
  }

  func cancel() {
    lock.lock()
    cancelled = true
    let process = process
    lock.unlock()
    if process?.isRunning == true { process?.terminate() }
  }

  private final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private let onLine: @Sendable (String) -> Void
    init(onLine: @escaping @Sendable (String) -> Void) { self.onLine = onLine }
    func append(_ data: Data) {
      lock.lock()
      pending.append(data)
      var lines: [String] = []
      while let newline = pending.firstIndex(of: 0x0A) {
        lines.append(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
        pending.removeSubrange(pending.startIndex...newline)
      }
      lock.unlock()
      lines.forEach(onLine)
    }
    func flush() {
      lock.lock()
      let rest = pending
      pending = Data()
      lock.unlock()
      if !rest.isEmpty { onLine(String(decoding: rest, as: UTF8.self)) }
    }
  }
}

/// The Translations tool's model: one for the app.
@Observable @MainActor
final class LocalizationsStore {
  static let shared = LocalizationsStore()

  private(set) var state: LocalizationsState
  /// The sources the scanned apps make (`LocalizationsPlan`), rebuilt when a scan or an app's inclusion changes.
  private(set) var plan: LocalizationsPlan
  /// Source -> how far its catalog is, read from the repository.
  private(set) var progress: [String: SourceProgress] = [:]
  /// What the tool is doing now ("Scanning Markdown…"), nil when idle.
  private(set) var activity: String?
  /// The latest lines of the running step's output.
  private(set) var log: [String] = []
  private(set) var error: String?
  /// The last finished step, in a line ("Wrote 6 catalogs").
  private(set) var summary: String?
  private var task: Task<Void, Never>?
  private var process: LocalizationsProcess?
  private var translator: LocalizationsTranslator?
  private let stateURL: URL

  init(stateURL: URL = LocalizationsState.url) {
    self.stateURL = stateURL
    var state = LocalizationsState.load(from: stateURL)
    if state.repo == nil { state.repo = LocalizationsRepo.standard?.path }
    self.state = state
    plan = LocalizationsPlan(apps: state.apps, scans: state.scans, kitsFolder: Self.kitsFolder(state.repo))
    refreshApps()
    ImportedTranslationDB.shared.restoreIfNeeded()
  }

  var repoURL: URL? { state.repo.map { URL(fileURLWithPath: $0, isDirectory: true) } }
  var isBusy: Bool { task != nil }
  var apps: [LocalizationsApp] { state.apps }
  var languages: [String] { state.languages }

  /// Every source to show: the plan's, then catalogs the repository has that no scanned app makes now.
  var sourceNames: [String] {
    let planned = plan.sources.map(\.name)
    let extra = repoURL.map { LocalizationsRepo.sources(in: $0) }?.filter { !planned.contains($0) } ?? []
    return planned + extra
  }

  func source(_ name: String) -> LocalizationsSource? { plan.sources.first { $0.name == name } }

  // MARK: - settings

  func chooseRepo() {
    Task {
      guard let url = await KitDesktop.chooseFolders(
        prompt: String(localized: "Choose"), message: String(localized: "Choose the translations repository (it holds Scripts/build and manifest.json)")
      ).first else { return }
      guard LocalizationsRepo.isRepo(url) else {
        error = String(localized: "\(url.lastPathComponent) has no Scripts/build and manifest.json: it isn't a translations repository.")
        return
      }
      state.repo = url.standardizedFileURL.path
      refreshApps()
      persist()
    }
  }

  /// Re-reads the apps next to the repository, keeping each known app's settings and the apps added by hand.
  func refreshApps() {
    guard let repoURL else { return }
    var found = LocalizationsApps.discover(near: repoURL)
    for app in state.apps where app.added == true && !found.contains(where: { $0.name == app.name }) {
      guard var current = LocalizationsApps.app(at: app.folderURL) else { continue }
      current.added = true
      found.append(current)
    }
    state.apps = found.map { app in
      guard let known = state.apps.first(where: { $0.name == app.name }) else { return app }
      var app = app
      app.included = known.included
      app.scheme = known.scheme
      return app
    }
    replan()
    refreshProgress()
  }

  /// Asks for an app's folder (one holding a `-Local` workspace) and adds it.
  func chooseApp() {
    Task {
      guard let url = await KitDesktop.chooseFolders(
        prompt: String(localized: "Add"), message: String(localized: "Choose an app's folder (it holds a -Local workspace)")
      ).first else { return }
      addApp(at: url)
    }
  }

  /// Adds the app in `folder`, one that isn't next to the repository (Hub).
  func addApp(at folder: URL) {
    guard var app = LocalizationsApps.app(at: folder) else {
      error = String(localized: "\(folder.lastPathComponent) has no -Local workspace with an app target.")
      return
    }
    app.added = true
    state.apps.removeAll { $0.name == app.name }
    state.apps.append(app)
    state.apps.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    replan()
    persist()
  }

  // MARK: - what each source is

  static var aboutPrefix: String { LocalizationsAbout.prefix }

  func description(of source: String) -> String { state.descriptions?[source] ?? "" }

  func setDescription(_ text: String, of source: String) {
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    var descriptions = state.descriptions ?? [:]
    descriptions[source] = text.isEmpty ? nil : text
    state.descriptions = descriptions
    persist()
  }

  /// What the model is told about a source (`LocalizationsAbout`).
  func about(_ source: String) -> [String] {
    LocalizationsAbout.lines(for: source, in: plan, descriptions: state.descriptions ?? [:])
  }

  // MARK: - shipped translations

  /// Dev's imported translation database (other apps' shipped translations, `language/source/target/app`): a run fills
  /// every empty slot it has an exact match for before any model call, marked imported.
  var importedDatabase: URL? { ImportedTranslationDB.shared.fileURL }

  func importDatabase(_ url: URL? = nil) {
    Task {
      if let url {
        do { try await ImportedTranslationDB.shared.setImported(url) } catch {
          self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
      } else {
        await ImportedTranslationDB.shared.importViaPanel()
        if let message = ImportedTranslationDB.shared.errorMessage { self.error = message }
      }
    }
  }

  func setIncluded(_ app: String, _ included: Bool) {
    guard let index = state.apps.firstIndex(where: { $0.name == app }) else { return }
    state.apps[index].included = included
    replan()
    persist()
  }

  func addLanguages(_ codes: [String]) {
    state.languages += codes.filter { !state.languages.contains($0) }
    persist()
  }

  func removeLanguage(_ code: String) {
    state.languages.removeAll { $0 == code }
    persist()
  }

  func dismissError() { error = nil }

  /// Reads every catalog's progress off the main actor.
  func refreshProgress() {
    guard let repoURL else { return }
    let names = sourceNames
    Task {
      let read = await Task.detached(priority: .utility) {
        names.reduce(into: [String: SourceProgress]()) { found, name in
          if let catalog = try? StringCatalog.load(url: LocalizationsRepo.catalog(name, in: repoURL)) {
            found[name] = SourceProgress(catalog)
          }
        }
      }.value
      progress = read
    }
  }

  private func replan() {
    plan = LocalizationsPlan(apps: state.apps, scans: state.scans, kitsFolder: Self.kitsFolder(state.repo))
  }

  /// The folder of the shared checkouts: the repository's (v57's).
  private static func kitsFolder(_ repo: String?) -> String? {
    repo.map { URL(fileURLWithPath: $0).deletingLastPathComponent().standardizedFileURL.path }
  }

  private func persist() { state.save(to: stateURL) }

  private func note(_ source: String, _ text: String) {
    var notes = state.notes[source] ?? []
    if !notes.contains(text) { notes.append(text) }
    state.notes[source] = notes
  }

  private func say(_ line: String) {
    log.append(line)
    if log.count > 400 { log.removeFirst(log.count - 400) }
  }

  // MARK: - running

  /// Stops the running step: the build or script is terminated, a translation run is cancelled with what it already
  /// applied kept.
  func cancel() {
    process?.cancel()
    translator?.cancel()
    task?.cancel()
  }

  private func start(_ title: String, _ work: @escaping @MainActor () async -> Void) {
    guard task == nil else { return }
    error = nil
    summary = nil
    log = []
    activity = title
    task = Task {
      await work()
      activity = nil
      process = nil
      translator = nil
      task = nil
      persist()
      refreshProgress()
    }
  }

  // MARK: scan

  /// Builds each app with string extraction on, reads what it links and holds, then writes every source's catalog.
  func scan(_ names: [String]? = nil) {
    let targets = state.apps.filter { names?.contains($0.name) ?? $0.included }
    guard let repoURL, !targets.isEmpty else { return }
    start(String(localized: "Scanning")) { [self] in
      for app in targets {
        guard !Task.isCancelled else { break }
        activity = String(localized: "Building \(app.name)")
        if let scan = await build(app) {
          state.scans[app.name] = scan
          say("\(app.name): \(scan.modules.map { "\($0.module) \($0.keys.count)" }.joined(separator: ", "))")
          for warning in scan.warnings { say("\(app.name): \(warning)") }
          persist()
        }
      }
      replan()
      activity = String(localized: "Writing catalogs")
      writeCatalogs(in: repoURL)
    }
  }

  /// One app's build into its build folder (`BuildFolders`, shared with Code's installs and the agents), then the
  /// keys it extracted. Nil when the build failed.
  private func build(_ app: LocalizationsApp) async -> AppScan? {
    let derivedData = BuildFolders.standard.instance(.xcode, for: app.folderURL)
      ?? URL.cachesDirectory.appendingPathComponent("dev.v57.dev/Localizations/\(app.name)")
    let process = LocalizationsProcess()
    self.process = process
    let lines = LineSink()
    let status = await process.run(
      "/usr/bin/xcodebuild",
      [
        "-workspace", app.container, "-scheme", app.scheme, "-destination", "platform=macOS",
        "-derivedDataPath", derivedData.path, "-quiet", "build",
        "SWIFT_EMIT_LOC_STRINGS=YES", "CODE_SIGNING_ALLOWED=NO", "COMPILER_INDEX_STORE_ENABLE=NO",
      ],
      in: app.folderURL, lowPriority: true
    ) { line in lines.add(line) }
    for line in lines.take() where line.contains("error:") && !line.contains("exit code 0 but produced no further output") { say("\(app.name): \(line)") }
    guard status == 0 else {
      if !Task.isCancelled { error = String(localized: "\(app.name) didn't build (xcodebuild exited with \(status)). The log has its errors.") }
      return nil
    }
    let scheme = app
    return await Task.detached(priority: .utility) { StringsDataScan.read(derivedData: derivedData, app: scheme) }.value
  }

  /// Merges each planned source's keys into its catalog and writes the ones that changed.
  private func writeCatalogs(in repo: URL) {
    var written = 0
    for source in plan.sources {
      let url = LocalizationsRepo.catalog(source.name, in: repo)
      let existing = FileManager.default.fileExists(atPath: url.path) ? try? StringCatalog.load(url: url) : nil
      if FileManager.default.fileExists(atPath: url.path), existing == nil {
        say("\(source.name): the catalog couldn't be read, so it was left alone")
        continue
      }
      let (catalog, counts) = SourceCatalogMerge.merge(existing, keys: source.keys)
      guard existing == nil || counts.changed else { continue }
      do {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try catalog.save(to: url)
      } catch {
        say("\(source.name): \(error.localizedDescription)")
        continue
      }
      written += 1
      if existing == nil {
        note(source.name, "Added the catalog with \(counts.total) keys")
      } else {
        if counts.added > 0 { note(source.name, "added \(counts.added) keys") }
        if counts.revived > 0 { note(source.name, "brought back \(counts.revived) keys") }
        if counts.staled > 0 { note(source.name, "marked \(counts.staled) removed keys stale") }
        if counts.commented > 0 { note(source.name, "updated \(counts.commented) comments") }
      }
      say("\(source.name): \(counts.total) keys (+\(counts.added), stale \(counts.staled))")
    }
    summary = written == 0 ? String(localized: "Every catalog is current") : String(localized: "Wrote \(written) catalogs")
  }

  // MARK: translate

  /// Translates the sources (all of them when nil) into the tool's languages, one after the other, with the
  /// Localization tab's pipeline; each catalog is saved when its run ends.
  func translate(_ names: [String]? = nil, shell: Translation.Shell) {
    guard let repoURL else { return }
    if let problem = ModelSettings.problem {
      error = problem
      return
    }
    // Translate All is the included apps' sources: a catalog no included app makes now stays as it is.
    let sources = (names ?? plan.sources.map(\.name)).filter {
      FileManager.default.fileExists(atPath: LocalizationsRepo.catalog($0, in: repoURL).path)
    }
    let languages = state.languages
    guard !sources.isEmpty, !languages.isEmpty else { return }
    // The shipped translations (Dev's imported translation database) fill what they can before any model call.
    ImportedTranslationDB.shared.restoreIfNeeded()
    start(String(localized: "Translating")) { [self] in
      var done = 0
      for name in sources {
        guard !Task.isCancelled else { break }
        activity = String(localized: "Translating \(name)")
        let translator = LocalizationsTranslator(shell: shell)
        self.translator = translator
        do {
          let outcome = try await translator.translate(
            catalog: LocalizationsRepo.catalog(name, in: repoURL), source: name, languages: languages,
            about: about(name))
          say("\(name): \(outcome)")
          if outcome.changed { note(name, "translated into \(languages.joined(separator: ", "))") }
          done += 1
        } catch {
          say("\(name): \(error.localizedDescription)")
          self.error = "\(name): \(error.localizedDescription)"
          if Task.isCancelled { break }
        }
        refreshProgress()
      }
      summary = String(localized: "Translated \(done.formatted()) of \(sources.count) sources")
    }
  }

  // MARK: build and commit

  /// Runs the repository's `Scripts/build` (catalogs -> `.lproj` files and `manifest.json`), then commits each source
  /// that changed, with `manifest.json` in the first: `<Source>: <what changed>`.
  func buildAndCommit() {
    guard let repoURL else { return }
    start(String(localized: "Building")) { [self] in
      let process = LocalizationsProcess()
      self.process = process
      let lines = LineSink()
      let status = await process.run(
        "/bin/zsh", [repoURL.appendingPathComponent("Scripts/build").path], in: repoURL
      ) { line in lines.add(line) }
      lines.take().forEach(say)
      guard status == 0 else {
        error = String(localized: "Scripts/build failed (exit \(status)).")
        return
      }
      activity = String(localized: "Committing")
      var commits = 0
      for source in LocalizationsRepo.sources(in: repoURL) {
        guard await hasChanges(source, in: repoURL) else { continue }
        let message = commitMessage(for: source)
        let paths = [source, "manifest.json"]
        guard await git(["add", "-A", "--"] + paths, in: repoURL) == 0,
          await git(["commit", "-q", "-m", message, "--"] + paths, in: repoURL) == 0
        else {
          error = String(localized: "Committing \(source) failed. The log has git's answer.")
          return
        }
        say("committed: \(message)")
        state.notes[source] = nil
        commits += 1
      }
      // The manifest alone (a source removed by hand, a rebuild after a script change).
      if await hasChanges("manifest.json", in: repoURL) {
        _ = await git(["commit", "-q", "-m", "Rebuilt manifest.json", "--", "manifest.json"], in: repoURL)
        commits += 1
      }
      summary = commits == 0 ? String(localized: "Nothing to commit") : String(localized: "Made \(commits) commits")
    }
  }

  func commitMessage(for source: String) -> String {
    let notes = state.notes[source] ?? []
    guard let first = notes.first else { return "\(source): Updated translations" }
    let text = ([first.prefix(1).uppercased() + first.dropFirst()] + notes.dropFirst()).joined(separator: ", ")
    return "\(source): \(text)"
  }

  private func hasChanges(_ path: String, in repo: URL) async -> Bool {
    let lines = LineSink()
    _ = await LocalizationsProcess().run(
      "/usr/bin/git", ["status", "--porcelain", "--", path], in: repo) { lines.add($0) }
    return lines.take().contains { !$0.isEmpty }
  }

  private func git(_ arguments: [String], in repo: URL) async -> Int32 {
    let lines = LineSink()
    let status = await LocalizationsProcess().run("/usr/bin/git", arguments, in: repo) { lines.add($0) }
    if status != 0 { lines.take().forEach(say) }
    return status
  }

  // MARK: - debug commands

  #if DEBUG
    /// Debug builds take commands without a click: post the distributed notification `dev.v57.dev.localizations`
    /// with `scan [app…]`, `translate [source…]`, `build`, `cancel`, `include <app> yes|no`, `addapp <folder>`,
    /// `describe <source> <phrase…>`, `importdb <file>`, `languages <code…>` or
    /// `dump` (the state, plan and progress to /tmp/dev-localizations.txt).
    func listenForDebugCommands(shell: Translation.Shell) async {
      for await note in Broadcast.messages(named: "dev.v57.dev.localizations") {
        guard let command = note[Broadcast.objectKey] else { continue }
        let words = command.split(separator: " ").map(String.init)
        let rest = Array(words.dropFirst())
        switch words.first {
        case "scan": scan(rest.isEmpty ? nil : rest)
        case "translate": translate(rest.isEmpty ? nil : rest, shell: shell)
        case "build": buildAndCommit()
        case "cancel": cancel()
        case "include": if rest.count == 2 { setIncluded(rest[0], rest[1] == "yes") }
        case "addapp": if !rest.isEmpty { addApp(at: URL(fileURLWithPath: rest.joined(separator: " "))) }
        case "describe": if let source = rest.first { setDescription(rest.dropFirst().joined(separator: " "), of: source) }
        case "importdb": if !rest.isEmpty { importDatabase(URL(fileURLWithPath: rest.joined(separator: " "))) }
        case "languages":
          state.languages = rest
          persist()
        case "dump": dump()
        default: break
        }
      }
    }

    private func dump() {
      var lines = ["repo: \(state.repo ?? "-")", "activity: \(activity ?? "-")", "error: \(error ?? "-")",
        "summary: \(summary ?? "-")", "languages: \(state.languages.joined(separator: " "))"]
      for app in state.apps {
        let scan = state.scans[app.name]
        lines.append("app \(app.name) included=\(app.included) scheme=\(app.scheme) scanned=\(scan?.date.description ?? "-") "
          + "lookup=\(plan.lookup[app.name]?.joined(separator: ",") ?? "-")")
      }
      for name in sourceNames {
        let source = source(name)
        let progress = progress[name]
        let languages = state.languages.map { "\($0)=\(progress?.translated[$0] ?? 0)" }.joined(separator: " ")
        lines.append("source \(name) kind=\(source?.kind.rawValue ?? "-") keys=\(source?.keys.count ?? 0) "
          + "catalog=\(progress?.keys ?? 0) stale=\(progress?.stale ?? 0) usedBy=\(source?.usedBy.joined(separator: ",") ?? "-") "
          + languages)
      }
      lines.append(
        "imported: \(ImportedTranslationDB.shared.fileURL?.path ?? "-") "
          + "importError=\(ImportedTranslationDB.shared.errorMessage ?? "-")")
      for name in sourceNames { lines += about(name).map { "about \(name): \($0)" } }
      lines.append("log:")
      lines += log.suffix(60)
      try? lines.joined(separator: "\n").write(toFile: "/tmp/dev-localizations.txt", atomically: true, encoding: .utf8)
    }
  #endif
}

/// Lines a process wrote, collected from its reader thread.
nonisolated final class LineSink: @unchecked Sendable {
  private let lock = NSLock()
  private var lines: [String] = []
  func add(_ line: String) {
    lock.lock()
    lines.append(line)
    if lines.count > 2000 { lines.removeFirst(lines.count - 2000) }
    lock.unlock()
  }
  func take() -> [String] {
    lock.lock()
    defer { lock.unlock() }
    let taken = lines
    lines = []
    return taken
  }
}

// MARK: - Translating one source

/// Runs the Localization tab's pipeline on one source's catalog with no pane showing it: the catalog opens in a store
/// of its own, the languages are added to it, the shell's workspace for it runs translate (prepare, prelearn, learn,
/// translate, the row pass) and its Save writes the file. The same path the toolbar's Translate takes, so translation
/// memory, context rules and the run's history are the ones the tab uses.
@MainActor
final class LocalizationsTranslator {
  let shell: Translation.Shell
  private var workspace: Translation.Workspace?
  private var cancelled = false

  init(shell: Translation.Shell) {
    self.shell = shell
  }

  struct Outcome: CustomStringConvertible {
    var items = 0
    var done = 0
    var failures = 0
    var changed = false
    var description: String {
      "\(done)/\(items) translated" + (failures > 0 ? ", \(failures) failed batch(es)" : "")
    }
  }

  enum Failure: LocalizedError {
    case open(String)
    var errorDescription: String? {
      switch self {
      case .open(let detail): detail
      }
    }
  }

  func cancel() {
    cancelled = true
    workspace?.pause()
  }

  /// `about`: what the source is, for the model (`LocalizationsStore.about`), kept as the `About:` lines of the
  /// source's project rules.
  func translate(catalog url: URL, source: String, languages: [String], about: [String] = []) async throws -> Outcome {
    let data = TranslationData.shared
    await data.start()
    // The source's own translation project, named so it reads apart from the app project of the same name.
    if Reconcile.existingProject(catalogURL: url) == nil {
      _ = data.insertProject(name: "\(source) (Localizations)", catalogURL: url)
    }
    let store = LocalizationStore(registersAsActive: false)
    await store.open(url)
    guard store.isLoaded, store.catalogURL == url, let opened = store.catalog else {
      throw Failure.open(
        store.loadError
          ?? "The catalog and Dev's records disagree; open it in the Localization tab once to choose a version.")
    }
    let missing = languages.filter { !store.isLanguagePresent($0) }
    if !missing.isEmpty {
      store.addLanguages(missing)
      while store.isAddingLanguage { try await Task.sleep(for: .milliseconds(50)) }
      // A workspace built before these languages existed doesn't have their columns.
      shell.forget(catalogURL: url)
    }
    guard !cancelled else { return Outcome() }
    shell.handOver(store: store, catalogURL: url)
    guard let workspace = await shell.focus(catalogURL: url, catalog: store.catalog ?? opened) else {
      throw Failure.open(shell.error ?? "The translation workspace couldn't be built.")
    }
    self.workspace = workspace
    workspace.closeOverlay()
    // Written before the run, so its prompts carry them. A changed line marks the source's translations stale, like any
    // project rule.
    workspace.project.context.replaceLines(prefixed: LocalizationsStore.aboutPrefix, with: about)
    // A source with nothing left to translate isn't run: a run ends in the row pass, which sends every row again
    // whatever its state (Translate by row), and over a finished source that costs hours and changes nothing.
    try workspace.project.loadData()
    let hasWork = workspace.project.data.contains { row in
      row.isCatalogRow && row.targets.contains(where: \.needsMachineTranslate)
    }
    guard hasWork || !missing.isEmpty else { return Outcome() }
    try await workspace.run(.vertical)
    let run = workspace.runner.runs[.vertical]
    await workspace.save()
    if let failure = workspace.error, run?.failures.isEmpty ?? true {
      throw Failure.open(failure)
    }
    return Outcome(
      items: run?.tally.items ?? 0, done: run?.tally.itemsDone ?? 0, failures: run?.failures.count ?? 0,
      changed: (run?.tally.itemsDone ?? 0) > 0 || !missing.isEmpty)
  }
}
