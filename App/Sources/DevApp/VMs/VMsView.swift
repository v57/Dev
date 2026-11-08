//
//  VMsView.swift
//  Dev
//

import Foundation
import ComponentKit
import SwiftUI

/// The VMs tool: the UTM virtual machines on this Mac, started and stopped from
/// here, and "Run on VM" — copy a project into a Linux or Windows guest and build
/// or test it there.
struct VMsView: View {
  @Environment(VMStore.self) private var store
  let projects: [SidebarProjectRow]

  @State private var selectedVM: String?

  var body: some View {
    ResizableSplit("vms.listWidth", pane: .leading, width: 280, range: 240...340, mainMinWidth: 380) {
      Group {
        if let vm = store.machines.first(where: { $0.id == selectedVM }) {
          VMDetail(vm: vm, projects: projects, runner: store.runner(for: vm))
            .id(vm.id)
        } else {
          EmptyState(
            systemImage: "desktopcomputer", title: "Pick a Virtual Machine",
            message: "Start it, then run a project's build or tests inside it.")
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } pane: {
      machineList
    }
    .task {
      await store.refresh()
      if selectedVM == nil { selectedVM = store.machines.first?.id }
    }
  }

  private var machineList: some View {
    VStack(spacing: 0) {
      KitList(selection: $selectedVM) {
        ForEach(store.machines) { vm in
          SidebarRow(
            value: vm.id, vm.name, subtitle: statusText(vm),
            systemImage: vm.guessedSystem == .windows ? "pc" : "terminal",
            status: store.pending.contains(vm.id) ? .working : .idle
          ) {
            StatusDot(hue: vm.status.isRunning ? .green : vm.status.isBusy ? .orange : .gray, isHollow: !vm.status.isRunning && !vm.status.isBusy)
          }
        }
      }
      if let error = store.error {
        Text(error).kitFont(.caption).foregroundStyle(Hue.red.text).padding(8)
      }
      HStack {
        Button("Refresh", systemImage: "arrow.clockwise") {
          Task { await store.refresh() }
        }
        .buttonStyle(.kit)
        .disabled(store.isRefreshing)
        Spacer()
        Button("Open UTM") {
          KitDesktop.open(URL(fileURLWithPath: "/Applications/UTM.app"))
        }
        .buttonStyle(.kit)
      }
      .controlSize(.small)
      .padding(KitMetrics.gutter)
    }
    .kitPane(.secondary)
  }

  private func statusText(_ vm: VirtualMachine) -> String {
    if store.pending.contains(vm.id) { return String(localized: "working…") }
    if vm.status.isRunning, let address = store.addresses[vm.id] { return String(localized: "running · \(address)") }
    return vm.status.rawValue
  }
}

/// One VM: its controls, how to reach it, and the Run on VM form and log.
private struct VMDetail: View {
  let vm: VirtualMachine
  let projects: [SidebarProjectRow]
  let runner: VMRunner
  @Environment(VMStore.self) private var store

  @State private var settings: VMSettings
  @State private var projectID: URL?
  @State private var command = ""
  @State private var address: String?
  @State private var isResolving = false

  init(vm: VirtualMachine, projects: [SidebarProjectRow], runner: VMRunner) {
    self.vm = vm
    self.projects = projects
    self.runner = runner
    var settings = VMSettings.load(vm.id)
    if settings.user.isEmpty { settings.user = VMStore.sshUser(for: vm) }
    if settings.system == nil { settings.system = vm.guessedSystem }
    _settings = State(initialValue: settings)
  }

  private var system: VirtualMachine.System { settings.system ?? vm.guessedSystem }
  private var roots: [URL] { projects.compactMap(\.rootURL) }
  private var target: String? {
    guard let address else { return nil }
    return settings.user.isEmpty ? address : "\(settings.user)@\(address)"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ScrollView {
        VStack(spacing: KitMetrics.gutter) {
          FormCard {
            FormRow(
              vm.name, help: vm.status.rawValue, systemImage: system == .windows ? "pc" : "terminal",
              hue: vm.status.isRunning ? .green : .gray
            ) {
              HStack {
                if vm.status.isRunning {
                  Button("Suspend") { Task { await store.suspend(vm) } }
                  Button("Stop") { Task { await store.stop(vm) } }
                } else {
                  Button("Start") { Task { await store.start(vm) } }
                    .buttonStyle(.kitPrimary)
                }
              }
              .buttonStyle(.kit)
              .disabled(store.pending.contains(vm.id) || vm.status.isBusy)
            }
          }
          FormCard("Connection") {
            FormRow("System", systemImage: "cpu") {
              KitPicker(
                "System",
                selection: Binding(get: { system }, set: { settings.system = $0; settings.save(vm.id) }),
                segments: VirtualMachine.System.allCases.map { KitSegment($0.title, value: $0) })
            }
            FormRow(
              "SSH user", systemImage: "person",
              field: TextField("SSH user", text: $settings.user).onSubmit { settings.save(vm.id) })
            FormRow(
              "Host", help: isResolving ? "Looking for the VM's address…" : nil, systemImage: "network",
              status: isResolving ? .working : .idle,
              field: TextField("Host", text: $settings.host, prompt: Text(address ?? "found automatically"))
                .onSubmit { settings.save(vm.id); Task { await resolve() } })
            if let target {
              FormRow("ssh \(target)", help: "Signs in with your SSH key", systemImage: "terminal", hue: .green) {
                Button("Open in Terminal") { openTerminal(target) }.buttonStyle(.kit)
              }
            } else if !isResolving {
              FormRow(
                "No address yet",
                help: vm.status.isRunning
                  ? "Enter the VM's host, or wait for it to finish booting." : "Start the VM to connect.",
                systemImage: "terminal", hue: .gray
              ) {
                if vm.status.isRunning { Button("Retry") { Task { await resolve() } }.buttonStyle(.kit) }
              }
            }
          }
          FormCard(
            "Run on VM",
            footer: system == .windows
              ? "Copied with tar to dev-sync\\<project> in the user's home."
              : "Mirrored with rsync to ~/dev-sync/<project>; runs in a login shell."
          ) {
            FormRow("Project", systemImage: "folder") {
              KitPicker(
                "Project", selection: $projectID,
                segments: [KitSegment("Choose…", value: URL?.none)]
                  + projects.filter { $0.rootURL != nil }.map { KitSegment($0.name, value: $0.rootURL) })
            }
            FormRow(
              "Command", systemImage: "chevron.left.forwardslash.chevron.right",
              field: TextField("Command", text: $command, prompt: Text("swift build")).kitFont(.mono))
            FormRow(runner.isRunning ? "Running…" : "Run", systemImage: "play", hue: runner.isRunning ? .green : .accent) {
              if runner.isRunning {
                Button("Stop", role: .destructive) { runner.cancel() }
                  .buttonStyle(.kit)
              } else {
                Button("Run") {
                  guard let root = projectID, let target else { return }
                  settings.save(vm.id)
                  runner.run(project: root, on: target, system: system, command: command)
                }
                .buttonStyle(.kitPrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(projectID == nil || target == nil || command.isEmpty)
              }
            }
          }
        }
        .padding(KitMetrics.gutter)
      }
      .frame(maxHeight: 460)
      logView
    }
    .task(id: vm.status) { await resolve() }
    .onChange(of: projectID) { _, root in
      if let root { command = VMRunner.defaultCommand(for: root, system: system) }
    }
    .onDisappear { settings.save(vm.id) }
  }

  private var logView: some View {
    VStack(alignment: .leading, spacing: 6) {
      KitCodeBlock(
        lines: runner.log, maxHeight: .infinity, followsEnd: true, font: .monoSmall,
        placeholder: "The run's output shows here."
      ) { line in
        line.hasPrefix("::") ? .accent : line.contains("error") ? .red : nil
      }
      if let status = runner.exitStatus {
        StatusLabel(status == 0 ? "Finished" : "Exited with \(status)", hue: status == 0 ? .green : .red)
      }
    }
    .padding(KitMetrics.gutter)
  }

  private func resolve() async {
    guard vm.status.isRunning || !settings.host.isEmpty else { address = nil; return }
    isResolving = true
    store.forgetAddress(of: vm)
    address = await store.address(of: vm)
    isResolving = false
  }

  /// A `.command` file opens in Terminal without asking for Automation access.
  private func openTerminal(_ target: String) {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("dev-ssh.command")
    try? "#!/bin/sh\nexec ssh \(target)\n".write(to: file, atomically: true, encoding: .utf8)
    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    KitDesktop.open(file)
  }
}

/// The sidebar's VMs row: how many VMs are running.
struct VMsSidebarRow: View {
  @Environment(VMStore.self) private var store

  var body: some View {
    SidebarRow(value: SidebarSelection.vms, "Virtual Machines", systemImage: "desktopcomputer") {
      if running > 0 {
        HStack(spacing: 4) {
          StatusDot(hue: .green)
          Text("\(running) on").foregroundStyle(.kitSecondary)
        }
      }
    }
    .task { await store.refresh() }
    .kitHelp("Virtual Machines", meta: status, systemImage: "desktopcomputer")
  }

  private var running: Int { store.machines.filter(\.status.isRunning).count }

  private var status: LocalizedStringKey {
    if VMStore.utmctl == nil { return "UTM is not installed" }
    if store.machines.isEmpty { return "No virtual machines" }
    return running == 0 ? "\(store.machines.count) stopped" : "\(running) running"
  }
}
