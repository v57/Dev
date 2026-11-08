import CryptoKit
import Foundation
import GitHubKit
import Testing
import UpdateKit

@testable import DevApp

/// release.sh and Dev's publish, against the security audit's findings: release.env is data (M9), the GitHub token
/// never reaches the script (H1), Windows and Linux files are signed as they're published (M4), the App Store Connect
/// IDs live in one machine-wide file (L7), and the Android keystore password stays off the command line (M8).
@Suite(.serialized) struct ReleaseSecurityTests {
  static let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("Resources/release.sh")

  /// A temporary project folder with `release.env`.
  final class Project {
    let root: URL
    init(_ releaseEnv: String) throws {
      root = FileManager.default.temporaryDirectory.appendingPathComponent("release-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      try releaseEnv.write(to: root.appendingPathComponent("release.env"), atomically: true, encoding: .utf8)
    }
    deinit { try? FileManager.default.removeItem(at: root) }

    func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path) }

    /// release.sh's output (both streams) and status.
    func run(_ arguments: [String], environment: [String: String] = [:]) throws -> (output: String, status: Int32) {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/bin/bash")
      process.arguments = [ReleaseSecurityTests.script.path, "--project", root.path] + arguments
      process.currentDirectoryURL = root
      var env = ProcessInfo.processInfo.environment
      env["ASC_CONFIG"] = root.appendingPathComponent("no-asc.env").path
      env.merge(environment) { $1 }
      process.environment = env
      let pipe = Pipe()
      process.standardOutput = pipe
      process.standardError = pipe
      try process.run()
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      return (String(decoding: data, as: UTF8.self), process.terminationStatus)
    }
  }

  // MARK: M9: release.env is parsed, never sourced

  @Test func releaseEnvIsReadAsDataNotRun() throws {
    let project = try Project(
      """
      # hostile
      APP_NAME='My App'     # quoted, with a comment
      SCHEME=$(touch pwned-scheme)
      PROJECT="a;b`touch pwned-backtick`"
      TEAM_ID=ABC # comment
      DIRECT_SETTINGS='SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) DIRECT_DISTRIBUTION'
      PATH=/nowhere
      touch pwned-line
      $(touch pwned-key)=1
      """)
    let (output, status) = try project.run(["--dry-run", "--version", "1.0", "--build", "7", "bundle"])
    #expect(status == 0, "\(output)")
    for name in ["pwned-scheme", "pwned-backtick", "pwned-line", "pwned-key"] {
      #expect(!project.exists(name), "release.env ran code: \(name)")
    }
    // Values as written: quotes removed, comments dropped, nothing expanded; PATH isn't a release key.
    #expect(output.contains("My App 1.0 (7), macos, scheme $(touch pwned-scheme)"), "\(output)")
  }

  // MARK: L7: the App Store Connect IDs are this Mac's

  @Test func checkRefusesAReleaseEnvWithAppStoreConnectValues() throws {
    let project = try Project("SCHEME=App\nASC_KEY_ID=ABCDEF1234\n")
    let (output, status) = try project.run(["--dry-run", "check"])
    #expect(status != 0)
    #expect(output.contains("::fail check release.env holds ASC_* values"), "\(output)")
  }

  @Test func appStoreUploadTakesTheIDsFromTheMachineWideFile() throws {
    let project = try Project("SCHEME=App\nAPP_STORE=yes\nASC_KEY_ID=FROMREPO\n")
    let machine = project.root.appendingPathComponent("v57.env")
    try "ASC_KEY_ID=MACHINEKEY\nASC_ISSUER_ID=issuer-1\nASC_KEY_PATH=~/keys/AuthKey_MACHINEKEY.p8\n"
      .write(to: machine, atomically: true, encoding: .utf8)
    let (output, _) = try project.run(["--dry-run", "--version", "1.0", "appstore"], environment: ["ASC_CONFIG": machine.path])
    #expect(output.contains("-authenticationKeyID MACHINEKEY"), "\(output)")
    #expect(output.contains("-authenticationKeyPath \(NSHomeDirectory())/keys/AuthKey_MACHINEKEY.p8"), "\(output)")
    #expect(!output.contains("FROMREPO"))
  }

  @Test func devKeepsTheIDsInTheMachineWideFileOnly() throws {
    let project = try Project("APP_NAME=App\nSCHEME=App\nASC_KEY_ID=OLDVALUE\n")
    let machine = project.root.appendingPathComponent("asc/v57.env")
    let saved = AppStoreConnectKey.machineFile
    AppStoreConnectKey.machineFile = machine
    defer { AppStoreConnectKey.machineFile = saved }

    // An old release.env's value moves out on the first save.
    var config = try #require(ReleaseConfig.load(from: project.root))
    #expect(config["ASC_KEY_ID"] == "OLDVALUE")
    config["ASC_ISSUER_ID"] = "issuer"
    try config.save(to: project.root)
    let releaseEnv = try String(contentsOf: project.root.appendingPathComponent("release.env"), encoding: .utf8)
    #expect(!releaseEnv.contains("ASC_"), "\(releaseEnv)")
    #expect(AppStoreConnectKey.loadMachineValues(from: machine) == ["ASC_KEY_ID": "OLDVALUE", "ASC_ISSUER_ID": "issuer"])
    let mode = try FileManager.default.attributesOfItem(atPath: machine.path)[.posixPermissions] as? Int
    #expect(mode == 0o600)

    // Every project reads it, and saving one whose values didn't change leaves the file alone.
    let other = try Project("APP_NAME=Other\nSCHEME=Other\n")
    let loaded = try #require(ReleaseConfig.load(from: other.root))
    #expect(loaded["ASC_KEY_ID"] == "OLDVALUE")
    try "ASC_KEY_ID=CHANGED\n".write(to: machine, atomically: false, encoding: .utf8)
    try loaded.save(to: other.root)
    #expect(AppStoreConnectKey.loadMachineValues(from: machine) == ["ASC_KEY_ID": "CHANGED"])
  }

  // MARK: H1: no token in the script; the publish request

  @Test func releaseScriptsGetNoGitHubToken() {
    #expect(ReleaseRunner.environment().keys.allSatisfy { !$0.contains("TOKEN") && $0 != "GH_TOKEN" })
  }

  @Test func githubStepWritesWhatToPublishAndMarksWindowsAndLinuxFilesForSigning() throws {
    let project = try Project("APP_NAME=App\nSCHEME=App\nGITHUB_REPO=v57/App\nGITHUB_DRAFT=no\n")
    let base = project.root.appendingPathComponent("build/release/1.2.3")
    for (platform, file) in [("macos", "App.zip"), ("linux", "App-Linux-x64.tar.gz"), ("windows", "App-Windows-x64.zip")] {
      let folder = base.appendingPathComponent(platform)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try Data("x".utf8).write(to: folder.appendingPathComponent(file))
      try "package\t\(folder.appendingPathComponent(file).path)\n"
        .write(to: folder.appendingPathComponent("artifacts.tsv"), atomically: true, encoding: .utf8)
    }
    let (output, status) = try project.run(["--version", "1.2.3", "github"], environment: ["GH_TOKEN": ""])
    #expect(status == 0, "\(output)")
    let line = try #require(output.split(separator: "\n").first { $0.hasPrefix("::publish github ") })
    let file = try #require(GitHubReleaseRequest.file(fromMarker: String(line)))
    let request = try GitHubReleaseRequest.load(file)
    #expect(request.repository == "v57/App" && request.tag == "v1.2.3" && request.version == "1.2.3")
    #expect(request.draft == false && request.generateNotes == true)
    let signed = Set(request.files.filter { $0.sign == true }.map { URL(fileURLWithPath: $0.path).lastPathComponent })
    #expect(signed == ["App-Linux-x64.tar.gz", "App-Windows-x64.zip"])
    #expect(request.files.count == 3)
    #expect(!output.contains("gh "))
  }

  @Test func aPublishRequestGoesOnlyToTheProjectsRepositoryWithItsOwnFiles() throws {
    let project = try Project("SCHEME=App\n")
    let inside = project.root.appendingPathComponent("App.zip")
    try Data("x".utf8).write(to: inside)
    func request(_ repository: String, _ path: String, sign: Bool = false) -> GitHubReleaseRequest {
      GitHubReleaseRequest(
        format: 1, repository: repository, tag: "v1", version: "1", files: [.init(path: path, sign: sign)])
    }
    let folders = [project.root]
    #expect(throws: GitHubReleaseRequest.Problem.self) {
      try request("someone/else", inside.path).validated(allowedRepositories: ["v57/App"], folders: folders)
    }
    #expect(throws: GitHubReleaseRequest.Problem.self) {
      try request("v57/App", "/etc/hosts").validated(allowedRepositories: ["v57/App"], folders: folders)
    }
    #expect(throws: GitHubReleaseRequest.Problem.self) {
      try request("v57/App", project.root.appendingPathComponent("../../etc/hosts").path)
        .validated(allowedRepositories: ["v57/App"], folders: folders)
    }
    _ = try request("V57/app", inside.path, sign: true).validated(allowedRepositories: ["v57/App"], folders: folders)
  }

  // MARK: M4: Windows and Linux files are signed on the way out

  @Test func publishingSignsTheMarkedFilesAndUploadsTheirSignatures() async throws {
    let project = try Project("SCHEME=App\n")
    let linux = project.root.appendingPathComponent("App-Linux-x64.tar.gz")
    let mac = project.root.appendingPathComponent("App.zip")
    try Data(repeating: 7, count: 100_000).write(to: linux)
    try Data("mac".utf8).write(to: mac)
    let seed = Curve25519.Signing.PrivateKey()
    let secret = Data([1, 2, 3, 4, 5, 6, 7, 8]) + seed.rawRepresentation
    let transport = RecordingTransport()
    let request = GitHubReleaseRequest(
      format: 1, repository: "v57/App", tag: "v1.2.3", title: "App 1.2.3", version: "1.2.3", generateNotes: true,
      draft: true, files: [.init(path: mac.path, platform: "macos", sign: false), .init(path: linux.path, platform: "linux", sign: true)])
    let release = try await GitHubReleasePublisher.publish(
      request, api: GitHubAPI(token: "test-token", transport: transport), signingKey: { secret }, log: { _ in })
    #expect(release.id == 9)
    #expect(transport.uploadedNames == ["App.zip", "App-Linux-x64.tar.gz", "App-Linux-x64.tar.gz.minisig"])
    let signature = try String(contentsOf: linux.appendingPathExtension("minisig"), encoding: .utf8)
    try Minisign.verifyRelease(
      file: linux, signature: signature, publicKey: Minisign.publicKey(secretKey: secret),
      fileName: "App-Linux-x64.tar.gz", version: "1.2.3")
    // The real key isn't this one: a release signed with it would be refused by the apps.
    #expect(throws: (any Error).self) {
      try Minisign.verifyRelease(file: linux, signature: signature, fileName: "App-Linux-x64.tar.gz", version: "1.2.3")
    }
    #expect(transport.authorizations.allSatisfy { $0 == "Bearer test-token" })
  }

  // MARK: M8: the keystore password stays off the command line and out of the log

  @Test func androidSigningPassesThePasswordThroughTheEnvironment() throws {
    let password = "s3cret-keystore-pass"
    let project = try Project(
      "APP_NAME=App\nSCHEME=App\nPLATFORM=android\nANDROID_KEYSTORE=release.keystore\nSWIFTUI_PATH=swiftui\n")
    let root = project.root
    try "// swift-tools-version: 6.0\n".write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
    try Data().write(to: root.appendingPathComponent("release.keystore"))
    func tool(_ path: String, _ body: String) throws {
      let url = root.appendingPathComponent(path)
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try ("#!/bin/bash\n" + body).write(to: url, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
    try tool("bin/security", "echo '\(password)'\n")
    try tool("swiftui/Android/scripts/build-app", "exit 0\n")
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("swiftui/Android/demo/build/outputs/apk/release"), withIntermediateDirectories: true)
    try Data().write(to: root.appendingPathComponent("swiftui/Android/demo/build/outputs/apk/release/app.apk"))
    try tool(
      "sdk/build-tools/36.0.0/apksigner",
      "printf '%s\\n' \"$@\" > \"\(root.path)/apksigner-args\"\nprintf '%s' \"$V57_KS_PASS\" > \"\(root.path)/apksigner-env\"\n")
    let (output, status) = try project.run(
      ["--version", "1.0", "archive"],
      environment: ["PATH": root.appendingPathComponent("bin").path + ":/usr/bin:/bin", "ANDROID_HOME": root.appendingPathComponent("sdk").path])
    #expect(status == 0, "\(output)")
    #expect(!output.contains(password), "the password is in the log")
    let arguments = try String(contentsOf: root.appendingPathComponent("apksigner-args"), encoding: .utf8)
    #expect(!arguments.contains(password), "the password is on apksigner's command line")
    #expect(arguments.contains("env:V57_KS_PASS"))
    #expect(try String(contentsOf: root.appendingPathComponent("apksigner-env"), encoding: .utf8) == password)
  }
}

/// Answers GitHub's release calls: no release for the tag yet, then a new release, then each upload.
final class RecordingTransport: HTTPTransport, @unchecked Sendable {
  private let lock = NSLock()
  private(set) var uploadedNames: [String] = []
  private(set) var authorizations: [String] = []

  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let url = request.url!
    let (status, body): (Int, String) = lock.withLock {
      authorizations.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
      if url.host == "uploads.github.com" {
        let name = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "name" }?.value ?? ""
        uploadedNames.append(name)
        return (201, #"{"id":\#(uploadedNames.count),"name":"\#(name)","size":1,"browser_download_url":"u"}"#)
      }
      if request.httpMethod == "GET" { return (404, #"{"message":"Not Found"}"#) }
      return (201, #"{"id":9,"tag_name":"v1.2.3","name":"App 1.2.3","draft":true,"html_url":"https://github.com/v57/App/releases/tag/v1.2.3","assets":[]}"#)
    }
    return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
  }
}
