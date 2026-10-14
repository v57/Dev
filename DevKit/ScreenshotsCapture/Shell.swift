#if os(macOS)
  import Foundation

  /// Runs a command line tool and waits for it.
  enum Shell {
    struct Result {
      var status: Int32
      var output: String

      var succeeded: Bool { status == 0 }
      var trimmed: String { output.trimmingCharacters(in: .whitespacesAndNewlines) }
      /// The last lines, for an error message.
      func tail(_ count: Int = 15) -> String {
        output.split(separator: "\n", omittingEmptySubsequences: true).suffix(count).joined(separator: "\n")
      }
    }

    /// stdout and stderr together.
    @discardableResult
    static func run(
      _ tool: String, _ arguments: [String], in directory: URL? = nil, environment: [String: String] = [:]
    ) -> Result {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: tool.hasPrefix("/") ? tool : "/usr/bin/env")
      process.arguments = tool.hasPrefix("/") ? arguments : [tool] + arguments
      if let directory { process.currentDirectoryURL = directory }
      if !environment.isEmpty {
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
      }
      let pipe = Pipe()
      process.standardOutput = pipe
      process.standardError = pipe
      process.standardInput = FileHandle.nullDevice
      do {
        try process.run()
      } catch {
        return Result(status: -1, output: "\(tool): \(error.localizedDescription)")
      }
      // Read before waiting: a full pipe would block the tool forever.
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      return Result(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }
  }

  /// Follows a file another process writes (an app's stdout), a line at a time.
  final class LineFollower {
    private let handle: FileHandle?
    private var buffer = Data()

    init(_ url: URL) {
      FileManager.default.createFile(atPath: url.path, contents: nil)
      handle = try? FileHandle(forReadingFrom: url)
    }

    deinit { try? handle?.close() }

    /// The complete lines written since the last call.
    func newLines() -> [String] {
      guard let handle, let data = try? handle.readToEnd(), !data.isEmpty else { return [] }
      buffer.append(data)
      var lines: [String] = []
      while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
        lines.append(String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self))
        buffer.removeSubrange(buffer.startIndex...newline)
      }
      return lines
    }
  }

  struct CaptureError: LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
  }
#endif
