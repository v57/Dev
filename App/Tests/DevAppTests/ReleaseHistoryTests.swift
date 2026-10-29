import Foundation
import Testing

@testable import DevApp

@Suite struct ReleaseHistoryTests {
  @Test func artifactMarkersCarryKindPlatformAndAPathWithSpaces() {
    let artifact = WorkflowRun.Artifact(
      marker: "::artifact package windows /Users/me/My App/build/release/runs/x/windows/My-Windows-arm64.zip",
      stepID: "archive-windows")
    #expect(artifact?.kind == "package")
    #expect(artifact?.platform == "windows")
    #expect(artifact?.path == "/Users/me/My App/build/release/runs/x/windows/My-Windows-arm64.zip")
    #expect(artifact?.name == "My-Windows-arm64.zip")
    #expect(artifact?.platformTitle == "Windows")
    #expect(WorkflowRun.Artifact(marker: "::artifact /old/form/without/kind", stepID: "") == nil)
    #expect(WorkflowRun.Artifact(marker: "::step archive", stepID: "") == nil)
  }

  @Test func runsFromBeforeArtifactsStillDecode() throws {
    let old = #"""
      {"id":"6F1D3C1E-1B7A-4C55-9E4B-0E5E9A0C2D11","workflowID":"release","workflowName":"Release",
       "startedAt":0,"startedBy":"you","steps":[],"state":"passed"}
      """#
    let run = try JSONDecoder().decode(WorkflowRun.self, from: Data(old.utf8))
    #expect(run.files.isEmpty)
    #expect(run.output == nil)
    #expect(run.bundle == nil)
  }

  @Test func aRunKnowsItsPlatformsSizeAndBundle() {
    var run = WorkflowRun(workflowID: "release", workflowName: "Release", startedBy: "you")
    run.output = "/p/build/release/runs/r"
    run.artifacts = [
      .init(path: "/p/build/release/runs/r/linux/A-Linux-arm64.tar.gz", kind: "package", platform: "linux", stepID: "l", size: 30),
      .init(path: "/p/build/release/runs/r/macos/A.dmg", kind: "package", platform: "macos", stepID: "m", size: 10),
      .init(path: "/p/build/release/runs/r/A-1.0-7.zip", kind: "bundle", platform: "all", stepID: "b", size: 40),
      .init(path: "/p/.build/screenshots", kind: "screenshots", platform: "macos", stepID: "s"),
    ]
    #expect(run.platforms == [.macos, .linux])
    #expect(run.totalSize == 40)
    #expect(run.bundle?.name == "A-1.0-7.zip")
    // Only the run's own folder is Dev's to delete.
    #expect(WorkflowStore.canDelete(run.files[0], of: run))
    #expect(!WorkflowStore.canDelete(run.files[3], of: run))
  }

  @Test func stepsKeepTheirPlatformAndVMRunner() throws {
    let json = #"""
      {"id":"archive-windows","name":"Archive · Windows","kind":"release","releaseStep":"archive",
       "platform":"windows","runner":"vm:Windows","parallel":true}
      """#
    let step = try JSONDecoder().decode(Workflow.Step.self, from: Data(json.utf8))
    #expect(step.releasePlatform == .windows)
    #expect(step.vmName == "Windows")
    #expect(step.commandLine == "release.sh --platform windows --host <Windows> archive")
    #expect(!step.publishes)
  }

  @Test func storeStepsPublish() {
    #expect(ReleaseStep.googleplay.publishes != nil)
    #expect(ReleaseStep.msstore.publishes != nil)
    #expect(ReleaseStep.bundle.publishes == nil)
    #expect(!ReleaseStep.bundle.takesPlatform)
    #expect(ReleaseStep.archive.takesPlatform)
  }

  @Test func aVMIsFoundByItsNewestDHCPLease() {
    let leases = """
      {
      \tname=ubuntu
      \tip_address=192.168.65.3
      \thw_address=1,2:57:80:a8:46:a5
      \tlease=0x6ae3b871
      }
      {
      \tname=ubuntu
      \tip_address=192.168.64.6
      \thw_address=1,2:57:80:a8:46:a5
      \tlease=0x6a000000
      }
      {
      \tname=windows
      \tip_address=192.168.64.7
      \thw_address=1,2:57:57:a:11:1
      \tlease=0x6ae3b000
      }
      """
    #expect(VMStore.leasedAddress(of: "02:57:80:a8:46:a5", in: leases) == "192.168.65.3")
    #expect(VMStore.leasedAddress(of: "02:57:57:0a:11:01", in: leases) == "192.168.64.7")
    #expect(VMStore.leasedAddress(of: "02:00:00:00:00:00", in: leases) == nil)
  }

  @Test func platformKeysAreWrittenOnlyWhenSet() {
    var config = ReleaseConfig.parse("SCHEME=Markdown\nWINDOWS_PRODUCT=MarkdownWinUI\n# mine\n")
    #expect(config["WINDOWS_PRODUCT"] == "MarkdownWinUI")
    var text = config.rendered()
    #expect(text.contains("WINDOWS_PRODUCT=MarkdownWinUI"))
    #expect(!text.contains("LINUX_PRODUCT="))
    #expect(text.contains("# mine"))
    // Its own comment isn't kept as a foreign line when read again.
    #expect(ReleaseConfig.parse(text).extraLines == ["# mine"])
    config["WINDOWS_PRODUCT"] = ""
    text = config.rendered()
    #expect(!text.contains(ReleaseConfig.platformComment))
  }
}
