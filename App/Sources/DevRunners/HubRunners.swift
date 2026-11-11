//
//  HubRunners.swift
//  DevRunners
//
//  The Hub backend of Dev's workflow runners: the only code of Dev that talks to Hub. It connects while the app runs
//  and the user turned runners on (off by default), lists the hub's dev-runner services, sends jobs and streams
//  their logs. The app sees plain values (RunnerModels, RunnerPlan), never HubService.
//

import Channel
import Foundation
import HubService
import Observation

@MainActor
@Observable
public final class HubRunners {
  public enum Status: Equatable, Sendable {
    case off
    case connecting
    case connected
    /// Connected, but the hub doesn't let this key list devices or runners: an owner adds it as an owner, or grants
    /// it `hub/devices` and `dev-runner/` (shown with the key in Settings)
    case notAllowed
    /// The hub refused the connection or isn't the pinned one
    case refused(String)
  }

  /// Where Dev's key for the hub lives.
  public enum Identity: Sendable {
    /// The login Keychain (Apple platforms; Secret Service on Linux)
    case keychain(String)
    case file(URL)
  }

  /// Something that happened to a job, for its log.
  public enum Event: Sendable {
    /// A runner took the job
    case assigned(String)
    case line(String)
    /// Why the job is still waiting (every runner that could take it is busy)
    case waiting(String)
  }

  public private(set) var status = Status.off
  /// The runners on the hub, by name.
  public private(set) var runners: [HubRunner] = []
  /// The hub's address while connected or connecting.
  public private(set) var address: String?

  private let identity: Identity
  @ObservationIgnored private var client: HubClient?
  @ObservationIgnored private var tasks: [Task<Void, Never>] = []
  @ObservationIgnored private var statusTasks: [String: Task<Void, Never>] = [:]
  @ObservationIgnored private var providers: [ServiceProvider] = []
  @ObservationIgnored private var approvedDevices: Set<String>?
  @ObservationIgnored private var balancers: Set<String> = []
  /// Runners this process sent a job to by device and hasn't heard back from
  @ObservationIgnored private var reserved: Set<String> = []

  public init(identity: Identity) {
    self.identity = identity
  }

  private var keyChain: KeyChain {
    switch identity {
    case .file(let url):
      return Self.privateFile(url)
    case .keychain(let tag):
      #if canImport(Security)
        return .keychain(tag)
      #else
        return Self.privateFile(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/\(tag)/hub.key"))
      #endif
    }
  }

  /// A key file in a folder only this user can read (HubService writes the file with default permissions).
  private static func privateFile(_ url: URL) -> KeyChain {
    let folder = url.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
    if FileManager.default.fileExists(atPath: url.path) {
      try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    return .file(url)
  }

  /// Dev's public key on hubs (SPKI, base64): what an owner adds as an owner or grants `dev-runner/` and
  /// `hub/devices`. Made on first use.
  public var publicKey: String { keyChain.publicKey() }

  // MARK: Connecting

  /// Connects to the hub at `address` (`ws://host:port`, `wss://…` or a port on this Mac). Nothing reaches a hub before
  /// this; `disconnect()` or quitting ends it.
  public func connect(to address: String) {
    guard let url = Self.url(address) else {
      status = .refused(String(localized: "Not a hub address: \(address)"))
      return
    }
    if self.address == address, client != nil { return }
    disconnect()
    self.address = address
    status = .connecting
    let client = HubClient(url, keyChain: keyChain)
    client.profile.name = "Dev"
    self.client = client
    tasks = [
      Task { [weak self] in await self?.followConnection(client) },
      Task { [weak self] in await self?.followDevices(client) },
      Task { [weak self] in await self?.followProviders(client) },
    ]
  }

  public func disconnect() {
    tasks.forEach { $0.cancel() }
    statusTasks.values.forEach { $0.cancel() }
    tasks = []
    statusTasks = [:]
    client?.stop()
    client = nil
    providers = []
    approvedDevices = nil
    balancers = []
    runners = []
    address = nil
    status = .off
  }

  /// `1997` → `ws://127.0.0.1:1997`; `host:port` → `ws://host:port`; URLs as they are.
  public nonisolated static func url(_ address: String) -> URL? {
    let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
    if let port = Int(text), port > 0, port < 65536 { return URL(string: "ws://127.0.0.1:\(port)") }
    if text.hasPrefix("ws://") || text.hasPrefix("wss://") { return URL(string: text) }
    guard !text.isEmpty, !text.contains("/") else { return nil }
    return URL(string: "ws://\(text)")
  }

  private func followConnection(_ client: HubClient) async {
    while !Task.isCancelled, self.client === client {
      if let refusal = client.refusal {
        status = .refused(refusal.description)
      } else if !client.isConnected {
        status = .connecting
      } else if status == .connecting || status == .off {
        status = .connected
      }
      try? await Task.sleep(for: .seconds(1))
    }
  }

  /// The hub's approved devices: only runners on them get jobs (the owner's devices).
  private func followDevices(_ client: HubClient) async {
    while !Task.isCancelled, self.client === client {
      do {
        for try await devices in client.devices.list() {
          approvedDevices = Set(devices.filter { $0.approved && !$0.revoked }.map(\.id))
          if status == .notAllowed { status = .connected }
          rebuild()
        }
      } catch {
        if Self.code(of: error) == "forbidden" || Self.code(of: error) == "unauthorized" { status = .notAllowed }
      }
      try? await Task.sleep(for: .seconds(3))
    }
  }

  /// The providers of `dev-runner/status`, each followed on its own connection.
  private func followProviders(_ client: HubClient) async {
    while !Task.isCancelled, self.client === client {
      do {
        for try await list in client.devices.providers("dev-runner/status") {
          providers = list
          let ids = Set(list.map(\.id))
          for (id, task) in statusTasks where !ids.contains(id) {
            task.cancel()
            statusTasks[id] = nil
          }
          for provider in list where statusTasks[provider.id] == nil {
            statusTasks[provider.id] = Task { [weak self] in await self?.followStatus(of: provider, client) }
          }
          rebuild()
        }
      } catch {}
      try? await Task.sleep(for: .seconds(3))
    }
  }

  @ObservationIgnored private var infos: [String: RunnerInfo] = [:]

  private func followStatus(of provider: ServiceProvider, _ client: HubClient) async {
    while !Task.isCancelled, self.client === client {
      do {
        for try await info: RunnerInfo in client.values("dev-runner/status", context: Route(service: provider.id)) {
          infos[provider.id] = info
          rebuild()
        }
      } catch {
        if ["forbidden", "unauthorized"].contains(Self.code(of: error)) { status = .notAllowed }
      }
      try? await Task.sleep(for: .seconds(2))
    }
  }

  private func rebuild() {
    infos = infos.filter { id, _ in providers.contains { $0.id == id } }
    runners = providers.map { provider in
      HubRunner(
        id: provider.id, deviceID: provider.device?.id, deviceName: provider.device?.name,
        trusted: provider.device.map { approvedDevices?.contains($0.id) == true } ?? false, info: infos[provider.id])
    }
    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  // MARK: Jobs

  /// Runs `job` on a runner that meets `requirement` and allows its repository: through the hub's `available` load
  /// balancer when every runner behind the run path can take it, else on the free runner Dev picks. Waits while the
  /// runners that could take it are busy; streams the log from the runner that took it. Cancelling the task cancels
  /// the job.
  public func run(
    _ job: RunnerJob, requirement: RunnerRequirement, onEvent: @escaping @MainActor (Event) -> Void
  ) async -> RunnerJobResult {
    // A fresh connection lists its runners within a few seconds
    for _ in 0..<20 where runners.isEmpty || runners.contains(where: { $0.info == nil }) {
      guard client != nil, !Task.isCancelled else { break }
      try? await Task.sleep(for: .milliseconds(500))
    }
    guard let client else {
      return RunnerJobResult(id: job.id, state: "failed", reason: String(localized: "Hub runners are off"))
    }
    var waitingSaid = false
    while !Task.isCancelled {
      let route = RunnerPlan.route(requirement, repo: job.repo, runners: runners, reserved: reserved)
      let path: String
      var target: HubRunner?
      switch route {
      case .none:
        let need = requirement.summary.isEmpty ? "" : String(localized: " (needs \(requirement.summary))")
        let untrusted = runners.contains { runner in
          !runner.trusted && runner.info.map { requirement.isMet(by: $0) && RepoURL.isAllowed(job.repo, by: $0.repos) } == true
        }
        let reason = runners.isEmpty
          ? String(localized: "No runners on the hub")
          : untrusted
            ? String(localized: "The runners that could take this job aren't on approved devices of the hub")
            : String(localized: "No runner on the hub can take this job\(need) or allows \(job.repo)")
        return RunnerJobResult(id: job.id, state: "failed", reason: reason)
      case .wait:
        if !waitingSaid { onEvent(.waiting(String(localized: "Every runner that can take this job is busy; waiting"))) }
        waitingSaid = true
        try? await Task.sleep(for: .seconds(2))
        continue
      case .balanced(let balanced):
        path = balanced
        await useAvailableBalancer(on: path, client)
      case .runner(let runner, let kindPath):
        path = kindPath
        target = runner
        reserved.insert(runner.id)
      }

      let log = Task { [weak self] in await self?.streamLog(of: job.id, from: target, client, onEvent: onEvent) }
      do {
        let result: RunnerJobResult = try await withTaskCancellationHandler {
          if let device = target?.deviceID {
            return try await client.send(path, job, context: Route(device: device))
          }
          return try await client.send(path, job)
        } onCancel: {
          Task { @MainActor [weak self] in await self?.cancel(job.id) }
        }
        if let target { reserved.remove(target.id) }
        // The log's last part carries the result: let it arrive, then stop following
        for _ in 0..<30 where !log.isCancelled {
          if logDone.contains(job.id) { break }
          try? await Task.sleep(for: .milliseconds(100))
        }
        log.cancel()
        logDone.remove(job.id)
        return result
      } catch {
        if let target { reserved.remove(target.id) }
        log.cancel()
        // No free provider within the hub's wait, or the picked runner got busy: ask again
        if Self.code(of: error) == "unavailable" || (error as? ChannelError)?.text == "api not available" {
          if !waitingSaid { onEvent(.waiting(String(localized: "Waiting for a free runner"))) }
          waitingSaid = true
          try? await Task.sleep(for: .seconds(1))
          continue
        }
        if Task.isCancelled { break }
        return RunnerJobResult(id: job.id, state: "failed", reason: Self.message(of: error))
      }
    }
    return RunnerJobResult(id: job.id, state: "cancelled", reason: String(localized: "cancelled"))
  }

  @ObservationIgnored private var logDone: Set<String> = []

  /// Follows the job's log from the runner that runs it: the one Dev picked, else the one whose status names it.
  private func streamLog(
    of id: String, from picked: HubRunner?, _ client: HubClient, onEvent: @escaping @MainActor (Event) -> Void
  ) async {
    var runner = picked
    while runner == nil, !Task.isCancelled {
      runner = runners.first { $0.info?.job?.id == id }
      if runner == nil { try? await Task.sleep(for: .milliseconds(200)) }
    }
    guard let runner, !Task.isCancelled else { return }
    onEvent(.assigned(runner.name))
    var next = 0
    for _ in 0..<5 where !Task.isCancelled {
      do {
        for try await chunk: RunnerLogChunk in client.values(
          "dev-runner/log", LogRequest(id: id, from: next), context: Route(service: runner.id))
        {
          for line in chunk.lines { onEvent(.line(line)) }
          next = chunk.from + chunk.lines.count
          if chunk.done != nil {
            logDone.insert(id)
            return
          }
        }
      } catch {
        // Picked by device before the job started there: the log appears once it does
        try? await Task.sleep(for: .milliseconds(500))
      }
    }
  }

  /// Stops a job on whichever runner runs it.
  public func cancel(_ id: String) async {
    guard let client, let runner = runners.first(where: { $0.info?.job?.id == id }) else { return }
    let _: Bool? = try? await client.send("dev-runner/cancel", ["id": id], context: Route(service: runner.id))
  }

  /// Sets the hub's `available` balancer on a run path, once per connection (owners only; others keep the hub's).
  private func useAvailableBalancer(on path: String, _ client: HubClient) async {
    guard !balancers.contains(path) else { return }
    balancers.insert(path)
    try? await client.send("hub/balancer/set", Balancer(path: path, type: "available"))
  }

  // MARK: Wire

  struct Route: Encodable, Sendable {
    var device: String?
    var service: String?
  }

  struct LogRequest: Encodable, Sendable {
    var id: String
    var from: Int
  }

  struct Balancer: Encodable, Sendable {
    var path: String
    var type: String
  }

  static func code(of error: any Error) -> String? {
    (error as? ChannelError)?.code?.description
  }

  static func message(of error: any Error) -> String {
    (error as? ChannelError)?.text ?? error.localizedDescription
  }
}
