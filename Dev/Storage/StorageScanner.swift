//
//  StorageScanner.swift
//  Dev
//

import Foundation

/// What a running scan reports, in order: phases while it discovers, then one
/// `measured` per item as its size lands, then the finished snapshot.
nonisolated enum StorageScanEvent: Sendable {
  case phase(String)
  case discovered(Int)
  /// One more item measured, kept or not: what the progress bar counts.
  case progress(Int)
  /// An item large enough to keep.
  case measured(StorageItem)
  case finished(StorageSnapshot)
}

/// Discovery, then measurement: finds every item (cheap — fixed locations, a
/// pruned walk of your folders, two simctl calls), works out which item owns
/// which nested bytes, then measures up to six items at a time off the main
/// actor. Cancelling the stream's consumer cancels the scan.
nonisolated enum StorageScanner {
  static let concurrentMeasurements = 6

  static func scan(
    roots: [String]?, runningBundle: String, fullDiskAccess: Bool
  ) -> AsyncStream<StorageScanEvent> {
    AsyncStream { continuation in
      let task = Task.detached(priority: .utility) {
        continuation.yield(.phase("Reading tool locations…"))
        var discovery = StorageDiscovery()
        discovery.fullDiskAccess = fullDiskAccess
        discovery.addSwift()
        discovery.addAndroid()
        discovery.addAI()
        discovery.addVirtualMachines()
        discovery.addJavaScript()
        discovery.addWeb()
        discovery.addPython()
        discovery.addToolchains()
        discovery.addDatabases()
        discovery.addTemporary()
        discovery.addMacOS()
        if fullDiskAccess { discovery.addProtected() }
        guard !Task.isCancelled else { return continuation.finish() }

        let walkRoots = roots ?? discovery.defaultWalkRoots
        continuation.yield(.phase("Walking your folders…"))
        discovery.walk(roots: walkRoots)
        guard !Task.isCancelled else { return continuation.finish() }

        continuation.yield(.phase("Reading apps…"))
        discovery.addApps(excludingBundle: runningBundle)
        if fullDiskAccess { discovery.addContainers() }
        discovery.addOther()

        let pending = assigningExclusions(discovery.items)
        continuation.yield(.discovered(pending.count))
        continuation.yield(.phase("Measuring…"))

        var measured: [StorageItem] = []
        let ledger = SharedBlockLedger()
        await withTaskGroup(of: StorageItem?.self) { group in
          var queue = pending.makeIterator()
          func enqueue() {
            guard let item = queue.next() else { return }
            group.addTask { measure(item, ledger: ledger) }
          }
          for _ in 0..<concurrentMeasurements { enqueue() }
          var done = 0
          while let result = await group.next() {
            done += 1
            continuation.yield(.progress(done))
            if let item = result {
              measured.append(item)
              continuation.yield(.measured(item))
            }
            if Task.isCancelled {
              group.cancelAll()
            } else {
              enqueue()
            }
          }
        }
        guard !Task.isCancelled else { return continuation.finish() }

        let volume = volumeCapacity()
        continuation.yield(.finished(StorageSnapshot(
          date: Date(), items: measured, volumeTotal: volume.total,
          volumeAvailable: volume.available, roots: walkRoots, fullDiskAccess: fullDiskAccess)))
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  /// Sizes one item; nil when it is below its own threshold (and so noise).
  static func measure(_ item: StorageItem, ledger: SharedBlockLedger) -> StorageItem? {
    var item = item
    if case .cloneDuplicates(let roots) = item.cleanup {
      // What cloning frees is what the copies hold on their own, which only
      // reading them tells; their bytes are already counted by their folders.
      let found = StorageDuplicates.find(in: roots)
      item.bytes = found.bytes
      item.detail = "\(found.copyCount) copies of \(found.groups.count) files · nothing is removed"
    } else if !item.reportedSize {
      let measurement = DiskUsage.measure(item.paths, excluding: item.excluded, ledger: ledger)
      item.bytes = measurement.bytes
      item.sharedBytes = measurement.sharedElsewhere > 0 ? measurement.sharedElsewhere : nil
      item.modified = measurement.newest > 0 ? Date(timeIntervalSince1970: TimeInterval(measurement.newest)) : nil
    }
    guard !Task.isCancelled, item.bytes >= item.minBytes else { return nil }
    return item
  }

  /// Gives each item the paths of the items nested inside it, so measuring
  /// the outer one skips bytes the inner one already counts.
  static func assigningExclusions(_ items: [StorageItem]) -> [StorageItem] {
    let owned = items.flatMap { item in item.paths.map { (path: $0, id: item.id) } }
      .sorted { $0.path < $1.path }
    let sortedPaths = owned.map(\.path)
    return items.map { item in
      guard !item.reportedSize else { return item }
      var item = item
      var excluded: [String] = []
      for path in item.paths {
        let prefix = path + "/"
        // Every path that starts with `prefix` sorts in one run after it.
        var index = lowerBound(sortedPaths, prefix)
        while index < owned.count, owned[index].path.hasPrefix(prefix) {
          if owned[index].id != item.id { excluded.append(owned[index].path) }
          index += 1
        }
      }
      item.excluded = excluded
      // A folder of other files that also holds categorised items is shown,
      // not removed: trashing it would take those items with it.
      if item.category == .files, !excluded.isEmpty {
        item.cleanup = .revealOnly(
          reason: "Also holds items from other categories — clean those here, or remove the folder in Finder")
      }
      return item
    }
  }

  private static func lowerBound(_ sorted: [String], _ value: String) -> Int {
    var low = 0, high = sorted.count
    while low < high {
      let mid = (low + high) / 2
      if sorted[mid] < value { low = mid + 1 } else { high = mid }
    }
    return low
  }

  static func volumeCapacity() -> (total: Int64, available: Int64) {
    let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(
      forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
    return (Int64(values?.volumeTotalCapacity ?? 0), values?.volumeAvailableCapacityForImportantUsage ?? 0)
  }
}

// MARK: - Cleaning

/// What one clean did: which items went, and which did not and why.
nonisolated struct StorageCleanReport: Sendable {
  var cleanedIDs: [String] = []
  var cleanedBytes: Int64 = 0
  var failures: [(title: String, message: String)] = []
  var trashedBytes: Int64 = 0
}

nonisolated enum StorageCleaner {
  /// Cleans each item in turn. Files go to the Trash unless
  /// `deleteImmediately`; tool-managed items run their tool.
  static func clean(_ items: [StorageItem], deleteImmediately: Bool) -> StorageCleanReport {
    var report = StorageCleanReport()
    let fileManager = FileManager.default
    let asRoot = items.filter(needsRoot)
    // Simulators go before their runtime, and a runtime one of them stayed
    // on stays too, so no simulator is left without its runtime.
    let ordered = items.filter { $0.parent != nil } + items.filter { $0.parent == nil }
    var keptParents: [String: String] = [:]
    for item in ordered where !needsRoot(item) {
      if let kept = keptParents[item.id] {
        report.failures.append((item.title, "\(kept) could not be removed first"))
        continue
      }
      do {
        switch item.cleanup {
        case .trash:
          for path in item.paths where fileManager.fileExists(atPath: path) {
            try remove(path, deleteImmediately: deleteImmediately)
          }
          if !deleteImmediately { report.trashedBytes += item.bytes }
        case .trashContents:
          for path in item.paths {
            for name in (try? fileManager.contentsOfDirectory(atPath: path)) ?? [] {
              try remove(path + "/" + name, deleteImmediately: deleteImmediately)
            }
          }
          if !deleteImmediately { report.trashedBytes += item.bytes }
        case .command(let executable, let arguments, _):
          let result = ScanShell.run(executable, arguments: arguments, currentDirectory: nil, timeout: 900)
          guard result.succeeded else {
            let output = (result.stderr.isEmpty ? result.stdout : result.stderr)
              .trimmingCharacters(in: .whitespacesAndNewlines)
            throw CleanError(message: output.isEmpty ? "exit status \(result.status)" : output)
          }
        case .revealOnly(let reason):
          throw CleanError(message: reason)
        case .adminCommand:
          continue  // run by cleanAsRoot
        case .cloneDuplicates(let roots):
          let idle = StorageDiscovery.excludingBootedSimulators(roots)
          guard !idle.isEmpty else { throw CleanError(message: "The simulators are booted, or simctl did not answer") }
          let result = StorageDuplicates.cloneAll(in: idle)
          if result.cloned == 0, let first = result.failures.first { throw CleanError(message: first) }
          report.cleanedIDs.append(item.id)
          report.cleanedBytes += result.freed
          if !result.failures.isEmpty {
            report.failures.append((item.title,
              "\(result.failures.count) files kept their own copy. First: \(result.failures[0])"))
          }
          continue
        }
        report.cleanedIDs.append(item.id)
        report.cleanedBytes += item.bytes
      } catch {
        report.failures.append((item.title, message(for: error, item: item)))
        if let parent = item.parent { keptParents[parent] = item.title }
      }
    }
    if !asRoot.isEmpty {
      cleanAsRoot(asRoot, deleteImmediately: deleteImmediately, into: &report)
    }
    return report
  }

  static func needsRoot(_ item: StorageItem) -> Bool {
    if case .adminCommand = item.cleanup { return true }
    return item.needsAdmin && item.cleanup.isCleanable
  }

  /// Everything that needs root, in ONE script behind ONE password prompt.
  /// Each item reports its own outcome, so one refusal does not hide the rest.
  /// Moved items land in your Trash owned by you, so emptying it needs no
  /// password and Put Back still works.
  private static func cleanAsRoot(
    _ items: [StorageItem], deleteImmediately: Bool, into report: inout StorageCleanReport
  ) {
    let trash = NSHomeDirectory() + "/.Trash"
    let owner = "\(getuid()):\(getgid())"
    var script = "T=\(StorageSystemScan.quoted(trash))\n"
    for (index, item) in items.enumerated() {
      var body: [String] = []
      switch item.cleanup {
      case .adminCommand(let command, _):
        body.append(command)
      case .trash:
        for path in item.paths {
          let quoted = StorageSystemScan.quoted(path)
          if deleteImmediately {
            body.append("/bin/rm -rf -- \(quoted)")
          } else {
            body.append("""
              d="$T/$(/usr/bin/basename \(quoted))"; [ -e "$d" ] && d="$d $(/bin/date +%H.%M.%S)-\(index)"; \
              /bin/mv -- \(quoted) "$d" && /usr/sbin/chown -R \(owner) "$d"
              """)
          }
        }
      case .trashContents:
        for path in item.paths {
          body.append("/usr/bin/find \(StorageSystemScan.quoted(path)) -mindepth 1 -maxdepth 1 -exec /bin/rm -rf {} +")
        }
      case .command, .revealOnly, .cloneDuplicates:
        continue
      }
      script += """
        if out=$( { \(body.joined(separator: " && ")); } 2>&1 ); then printf 'OK\\t%d\\n' \(index); \
        else printf 'FAIL\\t%d\\t%s\\n' \(index) "$(echo "$out" | /usr/bin/tr '\\n' ' ')"; fi

        """
    }

    let output: String
    do {
      output = try StorageSystemScan.runAsRoot(script)
    } catch {
      for item in items { report.failures.append((item.title, error.localizedDescription)) }
      return
    }
    var outcomes: [Int: String?] = [:]
    for line in output.split(separator: "\n") {
      let fields = line.split(separator: "\t", maxSplits: 2).map(String.init)
      guard fields.count >= 2, let index = Int(fields[1]) else { continue }
      outcomes[index] = fields[0] == "OK" ? .some(nil) : .some(fields.count > 2 ? fields[2] : "failed")
    }
    for (index, item) in items.enumerated() {
      switch outcomes[index] {
      case .some(.none):
        report.cleanedIDs.append(item.id)
        report.cleanedBytes += item.bytes
        if !deleteImmediately, case .trash = item.cleanup { report.trashedBytes += item.bytes }
      case .some(.some(let message)):
        report.failures.append((item.title, hint(message, item: item)))
      case .none:
        report.failures.append((item.title, "No result from the administrator script"))
      }
    }
  }

  /// The error, plus the setting that fixes it when that is known: another
  /// app's bundle can only be moved with App Management allowed.
  private static func message(for error: Error, item: StorageItem) -> String {
    let denied = (error as? CocoaError)?.code == .fileWriteNoPermission
    return denied ? hint("Operation not permitted", item: item) : error.localizedDescription
  }

  private static func hint(_ message: String, item: StorageItem) -> String {
    if message.contains("not permitted"), item.primaryPath.hasSuffix(".app") {
      return "macOS refused to move the app. Allow Dev in System Settings › Privacy & Security › "
        + "App Management, then try again."
    }
    if message.contains("not permitted") {
      return message + " — macOS protects this location (Full Disk Access or SIP)."
    }
    return message
  }

  private static func remove(_ path: String, deleteImmediately: Bool) throws {
    let url = URL(fileURLWithPath: path)
    if deleteImmediately {
      try FileManager.default.removeItem(at: url)
    } else {
      try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }
  }

  private struct CleanError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
  }
}
