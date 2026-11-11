import Foundation
import Testing

@testable import DevRunners

@Suite struct RunnerPlanTests {
  let repo = "https://github.com/v57/Demo.git"
  let allowed = ["https://github.com/v57/"]

  func runner(_ id: String, os: String = "macos", arch: String = "arm64", xcode: String? = "27.2", swift: String? = "6.4.2",
              simulators: [RunnerInfo.Simulator] = [], busy: Bool = false, trusted: Bool = true, cpu: Double = 0.5,
              repos: [String]? = nil) -> HubRunner {
    let job = busy ? RunnerInfo.Job(id: "x", workflow: "ci", step: "s", state: "running", startedAt: "") : nil
    return HubRunner(
      id: id, deviceID: "device-\(id)", deviceName: id, trusted: trusted,
      info: RunnerInfo(name: id, os: os, arch: arch, xcode: xcode, swift: swift, simulators: simulators,
                       repos: repos ?? allowed, job: job, cpuFree: cpu))
  }

  @Test func requirementsFromTheStep() {
    #expect(RunnerRequirement(runner: "mac") == nil)
    #expect(RunnerRequirement(runner: "vm:Ubuntu") == nil)
    #expect(RunnerRequirement(runner: "hub") == RunnerRequirement())
    #expect(RunnerRequirement(runner: "hub:macos") == RunnerRequirement(os: "macos"))
    #expect(RunnerRequirement(runner: "hub:mac") == RunnerRequirement(os: "macos"))
    #expect(RunnerRequirement(runner: "hub:linux-x86_64") == RunnerRequirement(os: "linux", arch: "x64"))
    #expect(RunnerRequirement(runner: "hub:macos", requires: RunnerRequirement(xcode: "27", simulator: "iPhone"))
            == RunnerRequirement(os: "macos", xcode: "27", simulator: "iPhone"))
    #expect(RunnerRequirement(os: "macos", xcode: "27", simulator: "iPhone").summary == "macOS · Xcode 27 · iPhone")
  }

  @Test func matching() {
    let iphone = RunnerInfo.Simulator(name: "iPhone 18", udid: "u", runtime: "iOS 27.2", free: true)
    let booted = RunnerInfo.Simulator(name: "iPhone 18", udid: "v", runtime: "iOS 27.2", free: false)
    let mac = runner("mac", simulators: [iphone]).info!
    let linux = runner("linux", os: "linux", xcode: nil, swift: "6.3").info!
    #expect(RunnerRequirement(os: "macos").isMet(by: mac))
    #expect(!RunnerRequirement(os: "macos").isMet(by: linux))
    #expect(RunnerRequirement(xcode: "27").isMet(by: mac))
    #expect(!RunnerRequirement(xcode: "27.3").isMet(by: mac))
    #expect(!RunnerRequirement(xcode: "").isMet(by: linux))
    #expect(RunnerRequirement(swift: "6.3").isMet(by: linux))
    #expect(!RunnerRequirement(swift: "6.4").isMet(by: linux))
    #expect(RunnerRequirement(simulator: "iphone").isMet(by: mac))
    #expect(RunnerRequirement(simulator: "iOS 27").isMet(by: mac))
    #expect(!RunnerRequirement(simulator: "iPhone").isMet(by: runner("m2", simulators: [booted]).info!))
  }

  @Test func jobsPerShard() {
    let one = RunnerPlan.jobs(run: "R", workflow: "ci", step: "build", shards: nil, repo: repo, commit: "c")
    #expect(one.map(\.id) == ["R.build.0"])
    #expect(one[0].shard == nil)
    let three = RunnerPlan.jobs(run: "R", workflow: "ci", step: "test", shards: 3, repo: repo, commit: "c")
    #expect(three.map(\.id) == ["R.test.0", "R.test.1", "R.test.2"])
    #expect(three.map { $0.shard?.index } == [0, 1, 2])
    #expect(three.allSatisfy { $0.shard?.count == 3 })
    #expect(RunnerPlan.jobs(run: "R", workflow: "ci", step: "t", shards: 500, repo: repo, commit: "c").count == 64)
  }

  @Test func equalJobsGoThroughTheBalancer() {
    let runners = [runner("a"), runner("b", os: "linux", xcode: nil)]
    #expect(RunnerPlan.route(RunnerRequirement(), repo: repo, runners: runners) == .balanced(path: "dev-runner/run"))
    // Only the Mac can: the macOS path, where every runner can take it
    #expect(RunnerPlan.route(RunnerRequirement(os: "macos"), repo: repo, runners: runners)
            == .balanced(path: "dev-runner/run/macos-arm64"))
  }

  @Test func specialJobsGoToAFreeRunner() {
    let iphone = RunnerInfo.Simulator(name: "iPhone 18", udid: "u", runtime: "iOS 27.2", free: true)
    let runners = [runner("plain"), runner("sims", simulators: [iphone], cpu: 0.2), runner("sims2", simulators: [iphone], cpu: 0.9)]
    let needs = RunnerRequirement(simulator: "iPhone")
    guard case .runner(let pick, let path) = RunnerPlan.route(needs, repo: repo, runners: runners) else {
      Issue.record("expected a runner")
      return
    }
    #expect(pick.id == "sims2")
    #expect(path == "dev-runner/run/macos-arm64")
    guard case .runner(let next, _) = RunnerPlan.route(needs, repo: repo, runners: runners, reserved: ["sims2"]) else {
      Issue.record("expected a runner")
      return
    }
    #expect(next.id == "sims")
    #expect(RunnerPlan.route(needs, repo: repo, runners: runners, reserved: ["sims", "sims2"]) == .wait)
  }

  @Test func onlyTrustedRunnersThatAllowTheRepository() {
    let untrusted = [runner("a", trusted: false)]
    #expect(RunnerPlan.route(RunnerRequirement(), repo: repo, runners: untrusted) == .none)
    let elsewhere = [runner("a", repos: ["https://github.com/someone/"])]
    #expect(RunnerPlan.route(RunnerRequirement(), repo: repo, runners: elsewhere) == .none)
    // A trusted runner beside an untrusted one: Dev picks it, the balancer could hand the job to either
    let mixed = [runner("a"), runner("b", trusted: false)]
    guard case .runner(let pick, _) = RunnerPlan.route(RunnerRequirement(), repo: repo, runners: mixed) else {
      Issue.record("expected a runner")
      return
    }
    #expect(pick.id == "a")
  }

  @Test func repositoryURLs() {
    #expect(RepoURL.normalized("https://GitHub.com/v57/Dev.git/") == "https://github.com/v57/Dev")
    #expect(RepoURL.normalized("git@github.com:v57/Dev.git") == "ssh://git@github.com/v57/Dev")
    #expect(RepoURL.normalized("/srv/git/demo.git") == "file:///srv/git/demo")
    #expect(RepoURL.normalized("--upload-pack=x") == nil)
    #expect(RepoURL.normalized("ext::sh") == nil)
    #expect(RepoURL.normalized("http://example.com/a") == nil)
    #expect(RepoURL.normalized("https://h/a/../b") == nil)
    #expect(RepoURL.isAllowed("https://github.com/v57/Dev", by: allowed))
    #expect(!RepoURL.isAllowed("https://github.com/v57x/Dev", by: allowed))
    #expect(RepoURL.isAllowed("/srv/git/demo", by: ["file:///srv/git/demo"]))
  }

  @Test func hubAddresses() {
    #expect(HubRunners.url("1997")?.absoluteString == "ws://127.0.0.1:1997")
    #expect(HubRunners.url("mac.local:1997")?.absoluteString == "ws://mac.local:1997")
    #expect(HubRunners.url("wss://hub.example.com")?.absoluteString == "wss://hub.example.com")
    #expect(HubRunners.url("") == nil)
  }
}
