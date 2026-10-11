//
//  VMRunner.swift
//  Dev
//

import Foundation
import Observation

/// "Run on VM": copies a project into a VM over SSH and runs a command there,
/// streaming its output. The copy lands in `~/dev-sync/<project>` on the guest.
///
/// Linux guests get `rsync --delete`, so the copy mirrors the project; Windows
/// guests get a tar stream (Windows ships `tar` and OpenSSH, not rsync), which adds
/// and updates files but leaves removed ones behind.
@Observable
final class VMRunner {
  private(set) var log: [String] = []
  private(set) var isRunning = false
  private(set) var exitStatus: Int32?
  private var process: LineProcess?

  /// Folders never copied: VCS state and build output, rebuilt on the guest.
  static let excluded = [".git", ".build", "build", "DerivedData", "node_modules", ".swiftpm",
                         "xcuserdata", ".DS_Store", "graphify-out"]

  /// A sensible first command for a project, from what it holds.
  static func defaultCommand(for root: URL, system: VirtualMachine.System) -> String {
    let fm = FileManager.default
    if fm.fileExists(atPath: root.appendingPathComponent("Package.swift").path) {
      return system == .windows ? "swift build" : "swift build && swift test"
    }
    if fm.fileExists(atPath: root.appendingPathComponent("package.json").path) {
      return "npm install && npm test"
    }
    if fm.fileExists(atPath: root.appendingPathComponent("Cargo.toml").path) { return "cargo test" }
    if fm.fileExists(atPath: root.appendingPathComponent("Makefile").path) { return "make" }
    return system == .windows ? "dir" : "ls -la"
  }

  func run(project root: URL, on target: String, system: VirtualMachine.System, command: String) {
    guard !isRunning else { return }
    log = []
    exitStatus = nil
    let name = root.lastPathComponent.replacingOccurrences(of: " ", with: "-")
    let script = system == .windows ? Self.windowsScript : Self.linuxScript
    let process = LineProcess(
      "/bin/bash", ["-c", script],
      environment: [
        "DEV_ROOT": root.path, "DEV_TARGET": target, "DEV_NAME": name, "DEV_COMMAND": command,
        "DEV_EXCLUDES": Self.excluded.joined(separator: "\n"),
      ])
    self.process = process
    isRunning = true
    Task { [weak self] in
      do {
        for try await line in process.lines() {
          guard let self else { return }
          if self.log.count > 10_000 { self.log.removeFirst(2_000) }
          self.log.append(line)
        }
      } catch {
        self?.log.append("could not start: \(error.localizedDescription)")
      }
      self?.exitStatus = process.status
      self?.isRunning = false
      self?.process = nil
    }
  }

  func cancel() { process?.terminate() }

  private static let sshOptions =
    #"SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)"#

  /// rsync, then the command in a login shell (so the guest's PATH has its toolchains).
  private static let linuxScript = sshOptions + #"""

    set -o pipefail
    excludes=()
    while IFS= read -r item; do excludes+=(--exclude "$item"); done <<< "$DEV_EXCLUDES"
    echo "::sync $DEV_ROOT -> $DEV_TARGET:dev-sync/$DEV_NAME"
    ssh "${SSH_OPTS[@]}" "$DEV_TARGET" "mkdir -p dev-sync/$DEV_NAME" || exit $?
    rsync -az --delete --stats "${excludes[@]}" -e "ssh ${SSH_OPTS[*]}" \
      "$DEV_ROOT/" "$DEV_TARGET:dev-sync/$DEV_NAME/" | grep -E "^(Number of regular files transferred|Total transferred file size)" || exit $?
    echo "::run $DEV_COMMAND"
    remote=$(printf 'cd ~/dev-sync/%q && %s' "$DEV_NAME" "$DEV_COMMAND")
    ssh "${SSH_OPTS[@]}" "$DEV_TARGET" "bash -lc $(printf %q "$remote")"
    status=$?
    echo "::exit $status"
    exit $status
    """#

  /// A tar stream whose entries already carry the `dev-sync/<name>/` prefix, so
  /// the guest's tar creates the folder itself in cmd and PowerShell alike.
  private static let windowsScript = sshOptions + #"""

    set -o pipefail
    excludes=()
    while IFS= read -r item; do excludes+=(--exclude "$item"); done <<< "$DEV_EXCLUDES"
    echo "::sync $DEV_ROOT -> $DEV_TARGET:dev-sync/$DEV_NAME"
    tar -czf - "${excludes[@]}" -s ",^\.,dev-sync/$DEV_NAME," -C "$DEV_ROOT" . \
      | ssh "${SSH_OPTS[@]}" "$DEV_TARGET" "tar -xzf - -C ." || exit $?
    echo "::run $DEV_COMMAND"
    ssh "${SSH_OPTS[@]}" "$DEV_TARGET" "cd dev-sync\\$DEV_NAME && $DEV_COMMAND"
    status=$?
    echo "::exit $status"
    exit $status
    """#
}
