//
//  RunnerModels.swift
//  DevRunners
//
//  The runner protocol (`dev-runner` in ~/Developer/Hub/Services/hub-dev-runner): what a runner advertises, a job, its
//  result and its log. Plain values with no Hub or app types, so the runner model can move to CodeKit later.
//

import Foundation

/// What a runner says about itself (`dev-runner/info`, `dev-runner/status`).
public struct RunnerInfo: Codable, Hashable, Sendable {
  public var version: Int
  public var name: String
  /// `macos`, `linux`, `windows`
  public var os: String
  public var osVersion: String?
  /// `arm64`, `x64`
  public var arch: String
  /// `<os>-<arch>`, the last segment of its run path
  public var kind: String
  public var xcode: String?
  public var swift: String?
  public var simulators: [Simulator]
  public var cpu: CPU
  public var memory: Space
  public var disk: Space
  /// The repositories it takes jobs from; one ending in `/` allows everything under it
  public var repos: [String]
  public var paths: [String]
  /// The job it runs now
  public var job: Job?

  public struct Simulator: Codable, Hashable, Sendable {
    public var name: String
    public var udid: String
    public var runtime: String
    public var free: Bool
  }

  public struct CPU: Codable, Hashable, Sendable {
    public var cores: Int
    public var load: Double
    /// From 0 to 1
    public var free: Double
  }

  public struct Space: Codable, Hashable, Sendable {
    public var total: Int64
    public var free: Int64
  }

  public struct Job: Codable, Hashable, Sendable {
    public var id: String
    public var workflow: String
    public var step: String
    public var shard: RunnerJob.Shard?
    /// `checkout`, `running`
    public var state: String
    public var startedAt: String
  }

  public var systemTitle: String {
    switch os {
    case "macos": "macOS"
    case "linux": "Linux"
    case "windows": "Windows"
    default: os
    }
  }

  public init(
    name: String, os: String, arch: String, xcode: String? = nil, swift: String? = nil, simulators: [Simulator] = [],
    repos: [String], job: Job? = nil, cpuFree: Double = 1
  ) {
    version = 1
    self.name = name
    self.os = os
    self.arch = arch
    kind = "\(os)-\(arch)"
    self.xcode = xcode
    self.swift = swift
    self.simulators = simulators
    cpu = CPU(cores: 8, load: 0, free: cpuFree)
    memory = Space(total: 0, free: 0)
    disk = Space(total: 0, free: 0)
    self.repos = repos
    paths = ["dev-runner/run", "dev-runner/run/\(kind)"]
    self.job = job
  }
}

/// One job: a command step of a workflow at a commit, or one shard of it. The runner reads the command from the
/// workflow file at that commit.
public struct RunnerJob: Codable, Hashable, Sendable, Identifiable {
  public var id: String
  public var repo: String
  public var commit: String
  public var workflow: String
  public var step: String
  public var shard: Shard?
  public var timeout: Double?

  public struct Shard: Codable, Hashable, Sendable {
    public var index: Int
    public var count: Int
    public init(index: Int, count: Int) {
      self.index = index
      self.count = count
    }
  }

  public init(id: String, repo: String, commit: String, workflow: String, step: String, shard: Shard? = nil) {
    self.id = id
    self.repo = repo
    self.commit = commit
    self.workflow = workflow
    self.step = step
    self.shard = shard
  }
}

/// How a job ended.
public struct RunnerJobResult: Codable, Hashable, Sendable {
  public var id: String
  /// `passed`, `failed`, `cancelled`
  public var state: String
  public var exitCode: Int?
  public var reason: String?
  public var startedAt: String?
  public var finishedAt: String?
  public var lines: Int?
  /// The runner's name
  public var runner: String?

  public var passed: Bool { state == "passed" }

  public init(id: String, state: String, reason: String? = nil, runner: String? = nil) {
    self.id = id
    self.state = state
    self.reason = reason
    self.runner = runner
  }
}

/// Part of a job's log: lines from `from` on; the last part carries the result.
public struct RunnerLogChunk: Codable, Hashable, Sendable {
  public var from: Int
  public var lines: [String]
  public var done: RunnerJobResult?
}
