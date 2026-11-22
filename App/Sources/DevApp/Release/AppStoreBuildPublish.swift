//
//  AppStoreBuildPublish.swift
//  Dev
//

import Foundation

/// What release.sh's appstore step uploaded (`<output>/app-store-upload.json`, named on a `::publish appstore FILE`
/// line): Dev waits for App Store Connect to process that build and attaches it to its version, in-process with the
/// App Store Connect key. Nothing is ever submitted for review.
nonisolated struct AppStoreUploadRequest: Codable, Equatable, Sendable {
  var bundleID: String
  var platform: String
  var version: String
  var build: String

  static func file(fromMarker line: String) -> URL? {
    let prefix = "::publish appstore "
    guard line.hasPrefix(prefix) else { return nil }
    let path = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    return path.isEmpty ? nil : URL(fileURLWithPath: path)
  }

  static func load(_ file: URL) throws -> AppStoreUploadRequest {
    let request = try JSONDecoder().decode(AppStoreUploadRequest.self, from: Data(contentsOf: file))
    guard !request.bundleID.isEmpty, !request.version.isEmpty, !request.build.isEmpty else {
      throw AppStoreConnectAPI.Failure(message: "\(file.lastPathComponent) names no bundle ID, version or build.")
    }
    return request
  }
}

nonisolated enum AppStoreBuildPublisher {
  /// How long a build may take to process before Dev stops waiting (App Store Connect usually needs 5–30 minutes).
  static let processingTimeout: TimeInterval = 90 * 60

  /// Waits until App Store Connect has processed the uploaded build, then attaches it to its version on the platform
  /// (made when the app has none: `AppStoreConnectAPI.version`). A build App Store Connect marks invalid fails; one
  /// still processing after the timeout fails too, and the next run can attach it. `sleep` is injected for tests.
  static func attach(
    _ request: AppStoreUploadRequest, api: AppStoreConnectAPI, poll: TimeInterval = 30,
    timeout: TimeInterval = processingTimeout,
    sleep: @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
    log: @Sendable (String) -> Void
  ) async throws {
    let platform = AppStoreConnectAPI.ascPlatform(request.platform)
    let appID = try await api.appID(bundleID: request.bundleID)
    log("Waiting for App Store Connect to process \(request.version) (\(request.build))")
    let path = "/v1/builds?filter[app]=\(appID)&filter[version]=\(request.build)"
      + "&filter[preReleaseVersion.version]=\(request.version)&filter[preReleaseVersion.platform]=\(platform)&limit=1"
    var waited: TimeInterval = 0
    var lastState = ""
    var build: [String: Any]?
    while true {
      if let found = AppStoreConnectAPI.data(try await api.request("GET", path)).first {
        let state = AppStoreConnectAPI.attribute(found, "processingState") as? String ?? ""
        if state != lastState {
          log("Build \(request.build): \(state.isEmpty ? "uploaded" : state.lowercased())")
          lastState = state
        }
        switch state {
        case "VALID":
          build = found
        case "FAILED", "INVALID":
          throw AppStoreConnectAPI.Failure(
            message: "App Store Connect marked build \(request.build) \(state.lowercased()): its email to the account says why.")
        default: break
        }
      }
      if build != nil { break }
      guard waited < timeout else {
        throw AppStoreConnectAPI.Failure(
          message: "Build \(request.build) is still processing after \(Int(timeout / 60)) minutes; run the step again to attach it.")
      }
      try await sleep(poll)
      waited += poll
    }
    guard let build, let buildID = build["id"] as? String else { return }
    if AppStoreConnectAPI.attribute(build, "usesNonExemptEncryption") == nil {
      log("The build has no export compliance answer (ITSAppUsesNonExemptEncryption): App Store Connect asks for it before submitting")
    }

    let version = try await api.version(request.version, appID: appID, platform: request.platform, progress: log)
    guard AppStoreConnectAPI.editableStates.contains(version.state) else {
      throw AppStoreConnectAPI.Failure(
        message: "Version \(request.version) is \(version.state.lowercased()), so its build can't change.")
    }
    _ = try await api.request("PATCH", "/v1/appStoreVersions/\(version.id)/relationships/build", body: [
      "data": ["type": "builds", "id": buildID],
    ])
    log("Attached build \(request.build) to version \(request.version); nothing was submitted for review")
  }
}
