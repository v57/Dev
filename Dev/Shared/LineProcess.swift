//
//  LineProcess.swift
//  Dev
//

import Foundation

/// A subprocess whose output is read line by line as it is written: the Release
/// and VMs tools show a long command's progress live instead of waiting for it.
///
/// stdout and stderr arrive merged, in order, on one stream; the stream finishes
/// when the process exits, and `status` holds its exit code from then on.
nonisolated final class LineProcess: @unchecked Sendable {
  private let process = Process()
  private let lock = NSLock()
  private var _status: Int32?

  /// The exit code, once the process has ended.
  var status: Int32? { lock.withLock { _status } }

  init(_ executable: String, _ arguments: [String], directory: URL? = nil,
       environment extra: [String: String] = [:]) {
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.currentDirectoryURL = directory
    var environment = ProcessInfo.processInfo.environment
    // An app opened from Finder gets a bare PATH; developer tools live in Homebrew.
    let path = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
    environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + path
    environment.merge(extra) { _, new in new }
    process.environment = environment
  }

  /// Starts the process and streams its output lines. Cancelling the consumer
  /// terminates the process.
  func lines() -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { continuation in
      let pipe = Pipe()
      process.standardOutput = pipe
      process.standardError = pipe
      process.standardInput = FileHandle.nullDevice
      // The read handler and the exit handler run on different queues; the
      // buffer is only touched under this lock.
      let bufferLock = NSLock()
      nonisolated(unsafe) var buffer = Data()
      let drain: (Data, Bool) -> Void = { chunk, isLast in
        bufferLock.withLock {
          buffer.append(chunk)
          while let newline = buffer.firstIndex(of: 0x0A) {
            let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex...newline)
            continuation.yield(line)
          }
          if isLast, !buffer.isEmpty {
            continuation.yield(String(decoding: buffer, as: UTF8.self))
            buffer.removeAll()
          }
        }
      }
      pipe.fileHandleForReading.readabilityHandler = { handle in
        let chunk = handle.availableData
        if !chunk.isEmpty { drain(chunk, false) }
      }
      process.terminationHandler = { [weak self] process in
        pipe.fileHandleForReading.readabilityHandler = nil
        drain(pipe.fileHandleForReading.readDataToEndOfFile(), true)
        self?.lock.withLock { self?._status = process.terminationStatus }
        continuation.finish()
      }
      continuation.onTermination = { [weak self] reason in
        if case .cancelled = reason { self?.terminate() }
      }
      do {
        try process.run()
      } catch {
        continuation.finish(throwing: error)
      }
    }
  }

  /// SIGTERM to the process (and, through its own handling, its children).
  func terminate() {
    if process.isRunning { process.terminate() }
  }

  /// Runs to the end and answers the exit code and all output.
  static func run(_ executable: String, _ arguments: [String], directory: URL? = nil)
    async -> (status: Int32, output: String)
  {
    let process = LineProcess(executable, arguments, directory: directory)
    var output: [String] = []
    do {
      for try await line in process.lines() { output.append(line) }
    } catch {
      return (-1, error.localizedDescription)
    }
    return (process.status ?? -1, output.joined(separator: "\n"))
  }
}
