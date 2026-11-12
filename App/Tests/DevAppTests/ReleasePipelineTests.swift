import Foundation
import Testing

@testable import DevApp

/// release.sh's choices for a v57 app's release, run with --dry-run: the version release.env names, the arm64-only
/// archive of an app that links arm64-only binaries, and --local test builds that never publish.
@Suite(.serialized) struct ReleasePipelineTests {
  typealias Project = ReleaseSecurityTests.Project

  @Test func theVersionComesFromReleaseEnvUnlessARunGivesOne() throws {
    let project = try Project("APP_NAME=App\nSCHEME=App\nVERSION=0.1.0\n")
    let (output, status) = try project.run(["--dry-run", "--build", "7", "bundle"])
    #expect(status == 0, "\(output)")
    #expect(output.contains("App 0.1.0 (7), macos"), "\(output)")
    let (given, _) = try project.run(["--dry-run", "--version", "2.0", "--build", "7", "bundle"])
    #expect(given.contains("App 2.0 (7), macos"), "\(given)")
  }

  @Test func appleSiliconAloneArchivesArm64AndShipsItAsTheApp() throws {
    let project = try Project("APP_NAME=App\nSCHEME=App\nDIRECT_ARCHS=arm64\nNOTARY_PROFILE=notary\n")
    let (archive, status) = try project.run(["--dry-run", "--version", "0.1.0", "archive"])
    #expect(status == 0, "\(archive)")
    #expect(archive.contains("ARCHS=arm64 archive"), "\(archive)")
    let (direct, _) = try project.run(["--dry-run", "--version", "0.1.0", "direct"])
    #expect(direct.contains("/App.zip"), "\(direct)")
    #expect(!direct.contains("AppleSilicon") && !direct.contains("lipo"), "\(direct)")

    let universal = try Project("APP_NAME=App\nSCHEME=App\nDIRECT_ARCHS='universal arm64'\nNOTARY_PROFILE=notary\n")
    let (both, _) = try universal.run(["--dry-run", "--version", "0.1.0", "archive", "direct"])
    #expect(!both.contains("ARCHS=arm64"), "\(both)")
    #expect(both.contains("/App-AppleSilicon.zip"), "\(both)")
  }

  @Test func aLocalBuildUsesTheSiblingCheckoutsAndIsNeverPublished() throws {
    let project = try Project("APP_NAME=App\nSCHEME=App\nPROJECT=App.xcodeproj\nGITHUB_REPO=v57/App\nAPP_STORE=yes\n")
    try FileManager.default.createDirectory(
      at: project.root.appendingPathComponent("App-Local.xcworkspace"), withIntermediateDirectories: true)
    let (build, status) = try project.run(["--dry-run", "--local", "--version", "0.1.0", "build"])
    #expect(status == 0, "\(build)")
    #expect(build.contains("-workspace App-Local.xcworkspace"), "\(build)")
    let (pinned, _) = try project.run(["--dry-run", "--version", "0.1.0", "build"])
    #expect(pinned.contains("-project App.xcodeproj"), "\(pinned)")

    for step in ["github", "appstore"] {
      let (output, status) = try project.run(["--dry-run", "--local", "--version", "0.1.0", step])
      #expect(status != 0)
      #expect(output.contains("::fail \(step) a --local build is a test build"), "\(output)")
    }
  }

  @Test func devKeepsTheVersionAndLinuxCategoriesItEdits() throws {
    let config = ReleaseConfig.parse("SCHEME=App\nVERSION=0.1.0\nLINUX_CATEGORIES='AudioVideo;Video;'\n")
    #expect(config["VERSION"] == "0.1.0" && config["LINUX_CATEGORIES"] == "AudioVideo;Video;")
    #expect(config.extraLines.isEmpty)
    let rendered = config.rendered()
    #expect(rendered.contains("TEAM_ID=\nVERSION=0.1.0\n"), "\(rendered)")
    #expect(rendered.contains("LINUX_CATEGORIES='AudioVideo;Video;'") || rendered.contains("LINUX_CATEGORIES=AudioVideo;Video;"))
  }
}
