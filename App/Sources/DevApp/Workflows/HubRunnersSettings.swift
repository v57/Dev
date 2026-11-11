//
//  HubRunnersSettings.swift
//  Dev
//

import ComponentKit
import DevRunners
import Foundation
import SwiftUI

/// Dev's workflow runners on the user's Hub: off until the reader turns them on and names a hub (Settings ▸
/// Runners). Dev then connects while it runs, in-process; the runners themselves are `dev-runner` services that
/// `hub-launcher` keeps alive on the devices the user opts in. Nothing of Dev's reaches a hub before that.
@MainActor
enum Runners {
  static let enabledKey = "HubRunnersEnabled"
  static let addressKey = "HubRunnersAddress"

  /// The one connection, for every window and the Settings window.
  static let shared = HubRunners(identity: identity)

  /// Dev's key on hubs: the Keychain, or a file named by `-DevRunnersKeyFile` (a throwaway hub's tests).
  private static var identity: HubRunners.Identity {
    if let path = UserDefaults.standard.string(forKey: "DevRunnersKeyFile"), !path.isEmpty {
      return .file(URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
    }
    return .keychain("dev.v57.dev.hub-runners")
  }

  static var isOn: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
  static var address: String { UserDefaults.standard.string(forKey: addressKey) ?? "" }

  /// Connects or disconnects to match the settings.
  static func apply() {
    if isOn, !address.trimmingCharacters(in: .whitespaces).isEmpty {
      shared.connect(to: address)
    } else {
      shared.disconnect()
    }
  }
}

/// Settings ▸ Runners: the hub, Dev's key there, and the runners it has.
struct RunnersSettingsView: View {
  @AppStorage(Runners.enabledKey) private var isOn = false
  @AppStorage(Runners.addressKey) private var address = ""
  @State private var draft = ""
  @State private var copied = false

  var body: some View {
    let runners = Runners.shared
    VStack(alignment: .leading, spacing: 18) {
      FormCard(
        footer: "Workflow steps that run on Hub runners go to the dev-runner services on your devices. Dev connects only while this is on."
      ) {
        FormRow("Use runners on a Hub", systemImage: "point.3.connected.trianglepath.dotted", hue: .orange,
                status: Self.status(of: runners.status)) {
          Toggle("Use runners on a Hub", isOn: $isOn).labelsHidden().toggleStyle(.kitSwitch)
        }
        FormRow("Hub address", help: Self.help(for: runners.status), systemImage: "network", hue: .blue,
                field: TextField("ws://mac-studio.local:1997", text: $draft)
                  .onSubmit { address = draft }) {
          Button("Connect") { address = draft }
            .buttonStyle(.kit)
            .disabled(draft == address && runners.status != .off)
        }
        FormRow("Dev's key", help: "An owner of the hub adds it as an owner, or grants it hub/devices and dev-runner/.",
                systemImage: "key", hue: .gray) {
          Button(copied ? "Copied" : "Copy Key") {
            KitPasteboard.copy(runners.publicKey)
            copied = true
          }
          .buttonStyle(.kit)
        }
      }
      if isOn {
        FormCard("Runners", footer: runners.runners.isEmpty ? "No dev-runner services on this hub yet." : nil) {
          RunnerRows(runners: runners.runners)
        }
      }
    }
    .onAppear { draft = address }
    .onChange(of: isOn) { Runners.apply() }
    .onChange(of: address) { Runners.apply() }
  }

  static func status(of status: HubRunners.Status) -> WorkStatus {
    switch status {
    case .off: .idle
    case .connecting: .working()
    case .connected: .done
    case .notAllowed, .refused: .failed
    }
  }

  static func help(for status: HubRunners.Status) -> String {
    switch status {
    case .off: String(localized: "Off")
    case .connecting: String(localized: "Connecting…")
    case .connected: String(localized: "Connected")
    case .notAllowed: String(localized: "Connected, but this hub doesn't let Dev see its runners yet")
    case .refused(let why): why
    }
  }
}

/// One row per runner: its system, tools, load and the job it runs.
struct RunnerRows: View {
  let runners: [HubRunner]

  var body: some View {
    ForEach(runners) { runner in
      FormRow(runner.name, help: Self.detail(of: runner), systemImage: Self.systemImage(of: runner),
              hue: runner.trusted ? .green : .gray,
              status: runner.isBusy ? .working() : .idle) {
        if !runner.trusted {
          Chip("Not an approved device", systemImage: "exclamationmark.shield", hue: .orange)
        } else if let job = runner.info?.job {
          Chip("\(job.workflow) · \(job.step)", systemImage: "hammer", hue: .blue)
        } else if runner.info != nil {
          Chip("Free", hue: .green)
        }
      }
    }
  }

  static func systemImage(of runner: HubRunner) -> String {
    switch runner.info?.os {
    case "macos": "laptopcomputer"
    case "windows": "pc"
    default: "server.rack"
    }
  }

  /// "macOS 27.2 · arm64 · Xcode 27.2 · Swift 6.4.2 · 3 free simulators · CPU 80% free · 120 GB free"
  static func detail(of runner: HubRunner) -> String {
    guard let info = runner.info else { return String(localized: "Waiting for its status…") }
    var parts = ["\(info.systemTitle) \(info.osVersion ?? "")".trimmingCharacters(in: .whitespaces), info.arch]
    if let xcode = info.xcode { parts.append("Xcode \(xcode)") }
    if let swift = info.swift { parts.append("Swift \(swift)") }
    let simulators = info.simulators.filter(\.free).count
    if simulators > 0 { parts.append(String(localized: "\(simulators) free simulators")) }
    parts.append(String(localized: "CPU \(Int((info.cpu.free * 100).rounded()))% free"))
    parts.append(String(localized: "\(ByteCountFormatter.string(fromByteCount: info.disk.free, countStyle: .file)) free"))
    return parts.joined(separator: " · ")
  }
}
