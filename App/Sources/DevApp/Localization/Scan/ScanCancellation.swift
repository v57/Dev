//
//  ScanCancellation.swift
//  Dev
//
//  Created by Dmitry on 10.09.26.
//

import Foundation

/// Thread-safe cancel flag shared between the UI (main actor) and the scan
/// worker (a detached task spawning compiles on several threads). The worker
/// checks it between steps; `cancel()` also terminates the live children so
/// a running `swift build` / `swiftc` stops immediately.
nonisolated final class ScanCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var flag = false

  var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return flag
  }

  func cancel() {
    lock.lock()
    flag = true
    lock.unlock()
    ScanShell.terminateAll()
  }
}
