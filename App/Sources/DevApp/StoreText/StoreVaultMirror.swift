//
//  StoreVaultMirror.swift
//  Dev
//

import Foundation
import VaultKit

/// One file of a project's `.dev/store/private/`, kept in the vault: sealed like every record, and under an id
/// derived with the vault's key, so CloudKit sees neither the text nor which project or path it belongs to.
nonisolated struct StoreTextRecord: VaultRecord {
  static let kind = "storeText"

  var id: String
  /// The `VaultProject` it belongs to.
  var project: String
  /// Under `.dev/store/private/`.
  var path: String
  var text: String

  init(id: String, project: String, path: String, text: String) {
    self.id = id
    self.project = project
    self.path = path
    self.text = text
  }

  init(id: String, values: [String: JSONValue]) {
    self.id = id
    project = values["project"]?.stringValue ?? ""
    path = values["path"]?.stringValue ?? ""
    text = values["text"]?.stringValue ?? ""
  }

  var values: [String: JSONValue] {
    ["project": .string(project), "path": .string(path), "text": .string(text)]
  }
}

/// Keeps `.dev/store/private/` and the vault the same, so drafts, review notes and messages to testers survive this
/// device and reach the reader's others while staying out of git.
///
/// The files stay the working copy: agents and other tools write them, and a project works with no vault. A pass
/// compares each file, its record and the text they last agreed on (`.vault-state.json`, per checkout), as the notes
/// mirror does: one side changed, the other follows; both changed, the text merges by line and a clash keeps both
/// versions between conflict markers; an edit beats a delete. A file is removed only when the vault says the record
/// was deleted, never because the record is missing: a wiped vault gets its texts back from here.
nonisolated struct StoreVaultMirror: Sendable {
  struct Report: Equatable, Sendable {
    var sent = 0
    var written = 0
    var merged = 0
    var conflicts = 0
    var removedFiles = 0
    var removedRecords = 0

    /// Something on this device's disk changed, so what's on screen may be old.
    var changedFiles: Bool { written + merged + removedFiles > 0 }
  }

  static let stateFile = ".vault-state.json"
  private static let lock = NSLock()

  let texts: StoreTexts
  let store: VaultStore
  let project: String

  private var manager: FileManager { .default }

  func reconcile() throws -> Report {
    Self.lock.lock()
    defer { Self.lock.unlock() }
    var report = Report()
    var state = readState()
    let files = localFiles()
    var records: [String: StoreTextRecord] = [:]
    for record in try store.records(StoreTextRecord.self)
    where record.project == project && Self.isMirrored(record.path) {
      records[record.path] = record
    }

    for path in Set(files.keys).union(records.keys).union(state.keys).sorted() {
      let base = state[path]
      switch (files[path], records[path]?.text) {
      case let (file?, vault?):
        if file == vault {
          state[path] = file
        } else if file == base {
          try writeFile(vault, path)
          report.written += 1
          state[path] = vault
        } else if vault == base {
          try save(file, path)
          report.sent += 1
          state[path] = file
        } else {
          // `translations.json` is a list of hashes: the vault's copy at worst marks a translation out of date.
          let merge = path.hasSuffix(".txt") ? TextMerge.merge(base: base ?? "", ours: file, theirs: vault) : nil
          let merged = merge?.text ?? vault
          if merged != file { try writeFile(merged, path) }
          if merged != vault { try save(merged, path) }
          report.merged += 1
          if merge?.hasConflicts == true { report.conflicts += 1 }
          state[path] = merged
        }
      case let (file?, nil):
        if file == base, try isDeleted(path) {
          try removeFile(path)
          report.removedFiles += 1
          state[path] = nil
        } else {
          try save(file, path)
          report.sent += 1
          state[path] = file
        }
      case let (nil, vault?):
        if vault == base {
          // The file left here: its text went ready, or it was removed.
          try store.delete(id: id(of: path))
          report.removedRecords += 1
          state[path] = nil
        } else {
          try writeFile(vault, path)
          report.written += 1
          state[path] = vault
        }
      case (nil, nil):
        state[path] = nil
      }
    }
    try writeState(state)
    return report
  }

  /// What a pass carries: the store's texts and their translation records, never a hidden file or anything that would
  /// leave the folder, whatever a record claims.
  static func isMirrored(_ path: String) -> Bool {
    guard !path.isEmpty, !path.hasPrefix("/"), path.hasSuffix(".txt") || path == "translations.json" else { return false }
    return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && !$0.hasPrefix(".") }
  }

  // MARK: The vault

  private func id(of path: String) throws -> String {
    try store.derivedID("storeText|\(project)|\(path)")
  }

  private func save(_ text: String, _ path: String) throws {
    try store.save(StoreTextRecord(id: id(of: path), project: project, path: path, text: text))
  }

  private func isDeleted(_ path: String) throws -> Bool {
    try store.item(id: id(of: path))?.isDeleted == true
  }

  // MARK: The folder

  private func localFiles() -> [String: String] {
    let folder = texts.privateFolder.standardizedFileURL
    guard let walker = manager.enumerator(at: folder, includingPropertiesForKeys: nil) else { return [:] }
    var files: [String: String] = [:]
    for case let url as URL in walker {
      let path = String(url.standardizedFileURL.path.dropFirst(folder.path.count + 1))
      guard Self.isMirrored(path), let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
      files[path] = text
    }
    return files
  }

  /// Through the ignore rule first, so a text from the vault can't land in a checkout that would commit it.
  private func writeFile(_ text: String, _ path: String) throws {
    try texts.prepareFolder()
    let url = texts.privateFolder.appendingPathComponent(path)
    try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
  }

  private func removeFile(_ path: String) throws {
    let url = texts.privateFolder.appendingPathComponent(path)
    try manager.removeItem(at: url)
    texts.prune(url.deletingLastPathComponent())
  }

  private var stateURL: URL { texts.privateFolder.appendingPathComponent(Self.stateFile) }

  private func readState() -> [String: String] {
    guard let data = try? Data(contentsOf: stateURL) else { return [:] }
    return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
  }

  private func writeState(_ state: [String: String]) throws {
    if state.isEmpty, !manager.fileExists(atPath: stateURL.path) { return }
    try texts.prepareFolder()
    try manager.createDirectory(at: texts.privateFolder, withIntermediateDirectories: true)
    try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
  }
}

/// Where the mirror meets the app: which vault a project's in, and running a pass off the main thread.
@MainActor enum StoreVaultSync {
  enum Status: Equatable {
    case unknown
    /// In the vault, and the two agree.
    case kept(StoreVaultMirror.Report)
    /// The project isn't in a vault here, so its private text is on this device only.
    case notInVault
    case failed(String)
  }

  private static func mirror(root: URL) -> StoreVaultMirror? {
    guard !LaunchOptions.isScreenshotMode || VaultDemo.isOn else { return nil }
    let path = root.standardizedFileURL.path
    guard let vault = VaultProjects.shared.vault(of: root), let store = vault.store,
          let project = vault.localProjects.first(where: { $0.localPath == path })
    else { return nil }
    return StoreVaultMirror(texts: StoreTexts(root: root), store: store, project: project.id)
  }

  static func sync(root: URL) async -> Status {
    guard let mirror = mirror(root: root) else { return .notInVault }
    return await Task.detached(priority: .utility) { () -> Status in
      do {
        return .kept(try mirror.reconcile())
      } catch {
        return .failed(error.localizedDescription)
      }
    }.value
  }

  /// A pass over every project with private text, in the vault or here: an agent may have written a file with the app
  /// closed, and it should reach the vault without the tab being opened.
  static func syncAll(roots: [URL]) {
    let mirrors = roots.compactMap { mirror(root: $0) }
    guard !mirrors.isEmpty else { return }
    Task.detached(priority: .utility) {
      for mirror in mirrors {
        let projects = Set(((try? mirror.store.records(StoreTextRecord.self)) ?? []).map(\.project))
        guard projects.contains(mirror.project) || FileManager.default.fileExists(atPath: mirror.texts.privateFolder.path)
        else { continue }
        _ = try? mirror.reconcile()
      }
    }
  }
}
