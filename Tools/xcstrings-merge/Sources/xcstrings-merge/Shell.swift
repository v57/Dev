import Foundation
import Darwin

/// Result of a completed subprocess run.
struct RunResult {
  var status: Int32
  var stdout: String
  var stderr: String
  var timedOut: Bool = false

  var succeeded: Bool { status == 0 }
}

/// Thin wrapper around subprocess execution with output capture and a timeout.
enum Shell {
  /// Absolute path to the active developer dir's tool launcher.
  static let xcrunPath = "/usr/bin/xcrun"

  /// Runs a subprocess synchronously, capturing stdout and stderr.
  /// If `timeout` elapses the process is SIGTERM'd, then SIGKILL'd after a
  /// short grace period.
  static func run(
    _ executable: String,
    arguments: [String],
    currentDirectory: URL? = nil,
    timeout: TimeInterval = 600
  ) -> RunResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    if let cwd = currentDirectory {
      process.currentDirectoryURL = cwd
    }
    process.environment = ProcessInfo.processInfo.environment

    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe

    var outData = Data()
    var errData = Data()
    let outLock = NSLock()
    let errLock = NSLock()

    outPipe.fileHandleForReading.readabilityHandler = { handle in
      let chunk = handle.availableData
      if chunk.isEmpty {
        handle.readabilityHandler = nil
      } else {
        outLock.lock()
        outData.append(chunk)
        outLock.unlock()
      }
    }
    errPipe.fileHandleForReading.readabilityHandler = { handle in
      let chunk = handle.availableData
      if chunk.isEmpty {
        handle.readabilityHandler = nil
      } else {
        errLock.lock()
        errData.append(chunk)
        errLock.unlock()
      }
    }

    let semaphore = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in semaphore.signal() }

    do {
      try process.run()
    } catch {
      return RunResult(status: -1, stdout: "", stderr: "failed to launch \(executable): \(error)")
    }

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

    outPipe.fileHandleForReading.closeFile()
    errPipe.fileHandleForReading.closeFile()

    outLock.lock()
    let out = String(decoding: outData, as: UTF8.self)
    outLock.unlock()
    errLock.lock()
    let err = String(decoding: errData, as: UTF8.self)
    errLock.unlock()

    return RunResult(status: process.terminationStatus, stdout: out, stderr: err, timedOut: timedOut)
  }

  /// Runs `swift` (via xcrun) with the given arguments in `directory`.
  static func swift(
    _ arguments: [String],
    currentDirectory: URL,
    timeout: TimeInterval = 600
  ) -> RunResult {
    run(xcrunPath, arguments: ["swift"] + arguments, currentDirectory: currentDirectory, timeout: timeout)
  }

  /// Runs `swiftc` (via xcrun) with the given arguments in `directory`.
  static func swiftc(
    _ arguments: [String],
    currentDirectory: URL,
    timeout: TimeInterval = 600
  ) -> RunResult {
    run(xcrunPath, arguments: ["swiftc"] + arguments, currentDirectory: currentDirectory, timeout: timeout)
  }
}
