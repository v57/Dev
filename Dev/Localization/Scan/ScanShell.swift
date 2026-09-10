//
//  ScanShell.swift
//  Dev
//
//  Created by Dmitry on 10.09.26.
//

import Darwin
import Foundation

/// Result of one scan subprocess run (toolchain invocation).
nonisolated struct ScanShellResult {
  var status: Int32
  var stdout: String
  var stderr: String
  var timedOut: Bool = false
  var cancelled: Bool = false

  var succeeded: Bool { status == 0 }

  /// Error lines with the generic driver summaries removed — the text worth
  /// showing in a scan report.
  func errorLines(limit: Int = 3) -> [String] {
    let lines = (stderr.isEmpty ? stdout : stderr)
      .split(separator: "\n")
      .map(String.init)
    var specific: [String] = []
    for line in lines where line.contains("error:") {
      let generic = line.contains("emit-module command failed")
        || line.contains("failed with a nonzero exit code")
        || line.contains("Command line")
      if !generic { specific.append(String(line.prefix(200))) }
      if specific.count == limit { return specific }
    }
    if specific.isEmpty, let line = lines.first(where: { $0.contains("error:") }) {
      return [String(line.prefix(200))]
    }
    return specific.isEmpty ? ["compile failed"] : specific
  }

  /// First specific compiler error line, or the timeout/cancel wording.
  var firstErrorLine: String {
    if cancelled { return "cancelled" }
    if timedOut { return "compile timed out" }
    return errorLines(limit: 1).first ?? "compile failed"
  }
}

/// Toolchain subprocesses for the string scan: output capture, a timeout,
/// and a global cancel that terminates every live child (the scan runs up to
/// four compiles at once, so a cancel must reach all of them).
nonisolated enum ScanShell {
  /// Absolute path to the active developer dir's tool launcher.
  static let xcrunPath = "/usr/bin/xcrun"

  private static let lock = NSLock()
  private static var liveChildren: [ObjectIdentifier: Process] = [:]

  /// Runs a subprocess synchronously, capturing stdout and stderr. If
  /// `timeout` elapses the process is SIGTERM'd, then SIGKILL'd after a
  /// short grace period.
  static func run(
    _ executable: String,
    arguments: [String],
    currentDirectory: URL?,
    timeout: TimeInterval
  ) -> ScanShellResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    if let currentDirectory {
      process.currentDirectoryURL = currentDirectory
    }
    process.environment = ProcessInfo.processInfo.environment

    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe

    let outBox = DataBox()
    let errBox = DataBox()

    outPipe.fileHandleForReading.readabilityHandler = { handle in
      let chunk = handle.availableData
      if chunk.isEmpty {
        handle.readabilityHandler = nil
      } else {
        outBox.append(chunk)
      }
    }
    errPipe.fileHandleForReading.readabilityHandler = { handle in
      let chunk = handle.availableData
      if chunk.isEmpty {
        handle.readabilityHandler = nil
      } else {
        errBox.append(chunk)
      }
    }

    let semaphore = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in semaphore.signal() }

    do {
      try process.run()
    } catch {
      return ScanShellResult(
        status: -1, stdout: "",
        stderr: "failed to launch \(executable): \(error)")
    }
    register(process)

    var timedOut = false
    if semaphore.wait(timeout: .now() + timeout) == .timedOut {
      timedOut = true
      process.terminate()
      // If SIGTERM does not stop it within the grace period, force kill.
      DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
        if process.isRunning {
          kill(process.processIdentifier, SIGKILL)
        }
      }
      semaphore.wait()
    }
    unregister(process)

    outPipe.fileHandleForReading.closeFile()
    errPipe.fileHandleForReading.closeFile()

    return ScanShellResult(
      status: process.terminationStatus,
      stdout: outBox.text, stderr: errBox.text, timedOut: timedOut)
  }

  /// Runs `swift` (via xcrun) with the given arguments in `directory`.
  static func swift(
    _ arguments: [String],
    currentDirectory: URL,
    timeout: TimeInterval = 600
  ) -> ScanShellResult {
    run(
      xcrunPath, arguments: ["swift"] + arguments,
      currentDirectory: currentDirectory, timeout: timeout)
  }

  /// Runs `swiftc` (via xcrun) with the given arguments in `directory`.
  static func swiftc(
    _ arguments: [String],
    currentDirectory: URL,
    timeout: TimeInterval = 600
  ) -> ScanShellResult {
    run(
      xcrunPath, arguments: ["swiftc"] + arguments,
      currentDirectory: currentDirectory, timeout: timeout)
  }

  /// Terminates every live child — the scan's cancel path. A child that
  /// ignores SIGTERM is SIGKILL'd after a grace period (off the caller's
  /// thread, which here is the main actor).
  static func terminateAll() {
    lock.lock()
    let children = Array(liveChildren.values)
    lock.unlock()
    guard !children.isEmpty else { return }
    for child in children where child.isRunning {
      child.terminate()
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
      for child in children where child.isRunning {
        kill(child.processIdentifier, SIGKILL)
      }
    }
  }

  private static func register(_ process: Process) {
    lock.lock()
    liveChildren[ObjectIdentifier(process)] = process
    lock.unlock()
  }

  private static func unregister(_ process: Process) {
    lock.lock()
    liveChildren.removeValue(forKey: ObjectIdentifier(process))
    lock.unlock()
  }

  /// Lock-protected byte sink for a pipe's readability handler (the handler
  /// runs on a dispatch queue, never the caller's thread).
  private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
      lock.lock()
      data.append(chunk)
      lock.unlock()
    }

    var text: String {
      lock.lock()
      defer { lock.unlock() }
      return String(decoding: data, as: UTF8.self)
    }
  }
}
