//
//  RunnerPlan.swift
//  DevRunners
//
//  Turning a workflow step into jobs and choosing the runners that may take each. Pure functions over plain values,
//  tested without a hub.
//

import Foundation

/// What a step asks of a runner: from its `runner` (`hub`, `hub:macos`, `hub:linux-arm64`) and its `requires`.
public struct RunnerRequirement: Codable, Hashable, Sendable {
  /// `macos`, `linux`, `windows`; nil for any system
  public var os: String?
  /// `arm64`, `x64`; nil for any
  public var arch: String?
  /// An Xcode version prefix (`27`, `27.2`), or "" for any Xcode
  public var xcode: String?
  /// A Swift version prefix (`6.3`), or "" for any toolchain
  public var swift: String?
  /// Part of a free simulator's name or runtime (`iPhone`, `iOS 27`)
  public var simulator: String?

  public init(os: String? = nil, arch: String? = nil, xcode: String? = nil, swift: String? = nil, simulator: String? = nil) {
    self.os = os
    self.arch = arch
    self.xcode = xcode
    self.swift = swift
    self.simulator = simulator
  }

  /// The requirement of a step's `runner`, or nil when it isn't a Hub runner (`mac`, `vm:<name>`).
  public init?(runner: String, requires: RunnerRequirement? = nil) {
    guard runner == "hub" || runner.hasPrefix("hub:") else { return nil }
    self = requires ?? RunnerRequirement()
    let kind = runner.dropFirst(3).drop { $0 == ":" }.lowercased()
    guard !kind.isEmpty else { return }
    let parts = kind.split(separator: "-", maxSplits: 1).map(String.init)
    os = parts[0] == "mac" ? "macos" : parts[0]
    if parts.count > 1 { arch = parts[1] == "x86_64" || parts[1] == "amd64" ? "x64" : parts[1] }
  }

  /// The run path's kind when the requirement names both (`macos-arm64`).
  public var kind: String? { os.flatMap { os in arch.map { "\(os)-\($0)" } } }

  /// "macOS · Xcode 27 · iPhone"
  public var summary: String {
    var parts: [String] = []
    switch os {
    case "macos": parts.append("macOS")
    case "linux": parts.append("Linux")
    case "windows": parts.append("Windows")
    case let os?: parts.append(os)
    case nil: break
    }
    if let arch { parts.append(arch) }
    if let xcode { parts.append(xcode.isEmpty ? "Xcode" : "Xcode \(xcode)") }
    if let swift { parts.append(swift.isEmpty ? "Swift" : "Swift \(swift)") }
    if let simulator { parts.append(simulator) }
    return parts.joined(separator: " · ")
  }

  /// Whether `runner` has what this asks for (free simulators count only while free).
  public func isMet(by runner: RunnerInfo) -> Bool {
    if let os, runner.os != os { return false }
    if let arch, runner.arch != arch { return false }
    if let xcode, !Self.version(runner.xcode, matches: xcode) { return false }
    if let swift, !Self.version(runner.swift, matches: swift) { return false }
    if let simulator, !runner.simulators.contains(where: {
      $0.free && "\($0.name) \($0.runtime)".localizedCaseInsensitiveContains(simulator)
    }) {
      return false
    }
    return true
  }

  /// `27.2` matches `27`, `27.2` and "" (any); nil (absent) matches nothing.
  static func version(_ version: String?, matches prefix: String) -> Bool {
    guard let version else { return false }
    let wanted = prefix.split(separator: ".")
    let have = version.split(separator: ".")
    return wanted.count <= have.count && zip(wanted, have).allSatisfy { $0 == $1 }
  }
}

/// A runner on the hub: its provider connection, its device and what it last said.
public struct HubRunner: Identifiable, Hashable, Sendable {
  /// The provider connection of `dev-runner/status` (its control connection)
  public var id: String
  public var deviceID: String?
  public var deviceName: String?
  /// Its device is an approved device of the hub (owner's), so Dev may send it jobs
  public var trusted: Bool
  public var info: RunnerInfo?

  public init(id: String, deviceID: String?, deviceName: String?, trusted: Bool, info: RunnerInfo?) {
    self.id = id
    self.deviceID = deviceID
    self.deviceName = deviceName
    self.trusted = trusted
    self.info = info
  }

  public var name: String { info?.name ?? deviceName ?? id }
  public var isBusy: Bool { info?.job != nil }
}

/// Where a job goes.
public enum RunnerRoute: Hashable, Sendable {
  /// Through the hub's load balancer on this path: every runner behind it can take the job
  case balanced(path: String)
  /// To this runner (by device), on its kind's path: only some runners of the kind can take it
  case runner(HubRunner, path: String)
  /// Every runner that could take it is busy: ask again when one is free
  case wait
  /// No runner on the hub can take it
  case none
}

public enum RunnerPlan {
  /// The jobs of one step: one per shard (`shards` 2 to 64), else one. Ids are `<run>.<step>.<shard>`.
  public static func jobs(
    run: String, workflow: String, step: String, shards: Int?, repo: String, commit: String
  ) -> [RunnerJob] {
    let count = min(max(shards ?? 1, 1), 64)
    let safe = { (text: String) in String(text.map { $0.isLetter || $0.isNumber || "._-".contains($0) ? $0 : "-" }) }
    return (0..<count).map { index in
      RunnerJob(
        id: "\(safe(run)).\(safe(step)).\(index)", repo: repo, commit: commit, workflow: workflow, step: step,
        shard: count > 1 ? .init(index: index, count: count) : nil)
    }
  }

  /// The runners that may take a job of `requirement` for `repo`: trusted, allowing the repository, having what it needs.
  public static func candidates(for requirement: RunnerRequirement, repo: String, in runners: [HubRunner]) -> [HubRunner] {
    runners.filter { runner in
      guard runner.trusted, let info = runner.info else { return false }
      return requirement.isMet(by: info) && RepoURL.isAllowed(repo, by: info.repos)
    }
  }

  /// Where a job goes. When every runner behind a run path can take the job, the hub's load balancer picks
  /// (`dev-runner/run`, else the kind's path); otherwise the free candidate with the most free CPU, or `wait` while
  /// every candidate is busy or reserved for another job of this run.
  public static func route(
    _ requirement: RunnerRequirement, repo: String, runners: [HubRunner], reserved: Set<String> = []
  ) -> RunnerRoute {
    let candidates = candidates(for: requirement, repo: repo, in: runners)
    guard !candidates.isEmpty else { return .none }
    let ids = Set(candidates.map(\.id))
    let all = runners.filter { $0.info != nil }
    if all.allSatisfy({ ids.contains($0.id) }) { return .balanced(path: "dev-runner/run") }
    let kinds = Set(candidates.compactMap(\.info?.kind))
    if kinds.count == 1, let kind = kinds.first,
       all.filter({ $0.info?.kind == kind }).allSatisfy({ ids.contains($0.id) }) {
      return .balanced(path: "dev-runner/run/\(kind)")
    }
    let free = candidates.filter { !$0.isBusy && !reserved.contains($0.id) }
      .sorted { ($0.info?.cpu.free ?? 0) > ($1.info?.cpu.free ?? 0) }
    guard let pick = free.first, let kind = pick.info?.kind else { return .wait }
    return .runner(pick, path: "dev-runner/run/\(kind)")
  }
}

/// Clone URLs in one spelling, as the runner compares them (dev-runner's policy.ts `normalizeRepo`).
public enum RepoURL {
  public static func normalized(_ text: String) -> String? {
    var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty, !value.hasPrefix("-"), !value.contains("::"), !value.contains(where: \.isWhitespace) else { return nil }
    if !value.contains("://"), let at = value.firstIndex(of: "@"), let colon = value[at...].firstIndex(of: ":") {
      value = "ssh://\(value[..<colon])/\(value[value.index(after: colon)...])"
    }
    if value.hasPrefix("/") { value = "file://" + value }
    guard let url = URLComponents(string: value), let scheme = url.scheme?.lowercased(),
          ["https", "ssh", "file"].contains(scheme), url.query == nil, url.fragment == nil, url.password == nil
    else { return nil }
    var path = url.path
    while path.hasSuffix("/") { path.removeLast() }
    if path.hasSuffix(".git") { path.removeLast(4) }
    guard !path.isEmpty, !path.split(separator: "/").contains("..") else { return nil }
    let user = url.user.map { "\($0)@" } ?? ""
    let port = url.port.map { ":\($0)" } ?? ""
    return "\(scheme)://\(user)\((url.host ?? "").lowercased())\(port)\(path)"
  }

  public static func isAllowed(_ repo: String, by allowed: [String]) -> Bool {
    guard let normal = normalized(repo) else { return false }
    return allowed.contains { entry in
      entry.hasSuffix("/") ? normal.hasPrefix(entry) && normal.count > entry.count : normal == entry
    }
  }
}
