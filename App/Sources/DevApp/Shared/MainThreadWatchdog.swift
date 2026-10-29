//
//  MainThreadWatchdog.swift
//  Dev
//

import Foundation

/// `-DevHangLog <file>`: logs every stretch the main thread could not answer for longer than
/// `threshold`, one line per stall (`<seconds since launch> <stall ms>`), so a lag can be
/// measured the same way before and after a change. A background thread posts a block to the
/// main queue and times how long it waits for it.
nonisolated enum MainThreadWatchdog {
  nonisolated(unsafe) private static var handle: FileHandle?
  private static let launch = Date()
  private static let lock = NSLock()

  /// A line naming what the app is about to do (`# <label>`), so stalls read against it.
  static func mark(_ label: String) {
    write(String(format: "%.2f # %@\n", Date().timeIntervalSince(launch), label))
  }

  private static func write(_ line: String) {
    lock.lock()
    defer { lock.unlock() }
    handle?.write(Data(line.utf8))
  }

  static func start(logTo path: String, threshold: TimeInterval = 0.05) {
    FileManager.default.createFile(atPath: path, contents: nil)
    handle = FileHandle(forWritingAtPath: path)
    guard handle != nil else { return }
    let thread = Thread {
      let answered = DispatchSemaphore(value: 0)
      while true {
        let posted = Date()
        DispatchQueue.main.async { answered.signal() }
        answered.wait()
        let stall = Date().timeIntervalSince(posted)
        if stall >= threshold {
          write(String(format: "%.2f %.0f\n", posted.timeIntervalSince(launch), stall * 1000))
        }
        Thread.sleep(forTimeInterval: 0.01)
      }
    }
    thread.name = "MainThreadWatchdog"
    thread.qualityOfService = .userInteractive
    thread.start()
  }
}
