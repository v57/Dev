//
//  VMsView.swift
//  Dev
//

import AppKit
import SwiftUI

/// The VMs tool: the UTM virtual machines on this Mac, started and stopped from
/// here, and "Run on VM" — copy a project into a Linux or Windows guest and build
/// or test it there.
struct VMsView: View {
  @Environment(VMStore.self) private var store
  let projects: [SidebarProjectRow]

  @State private var selectedVM: String?

  var body: some View {
    HSplitView {
      machineList
        .frame(minWidth: 240, idealWidth: 280, maxWidth: 340)
      Group {
        if let vm = store.machines.first(where: { $0.id == selectedVM }) {
          VMDetail(vm: vm, projects: projects, runner: store.runner(for: vm))
            .id(vm.id)
        } else {
          ContentUnavailableView(
            "Pick a virtual machine", systemImage: "desktopcomputer",
            description: Text("Start it, then run a project's build or tests inside it."))
        }
      }
      .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
    }
    .task {
      await store.refresh()
      if selectedVM == nil { selectedVM = store.machines.first?.id }
    }
  }

  private var machineList: some View {
    VStack(spacing: 0) {
      List(selection: $selectedVM) {
        ForEach(store.machines) { vm in
          HStack {
            Image(systemName: vm.guessedSystem == .windows ? "pc" : "terminal")
              .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
              Text(vm.name)
              Text(statusText(vm)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Circle()
              .fill(vm.status.isRunning ? Color.green : vm.status.isBusy ? .orange : .secondary.opacity(0.4))
              .frame(width: 8, height: 8)
          }
          .tag(vm.id)
        }
      }
      if let error = store.error {
        Text(error).font(.caption).foregroundStyle(.red).padding(8)
      }
      Divider()
      HStack {
        Button {
          Task { await store.refresh() }
        } label: {
          Label("Refresh", systemImage: "arrow.clockwise")
        }
        .disabled(store.isRefreshing)
        Spacer()
        Button("Open UTM") {
          NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/UTM.app"))
        }
      }
      .padding(8)
    }
  }

  private func statusText(_ vm: VirtualMachine) -> String {
    if store.pending.contains(vm.id) { return "working…" }
    if vm.status.isRunning, let address = store.addresses[vm.id] { return "running · \(address)" }
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
      Form {
        Section {
          HStack {
            Text(vm.name).font(.headline)
            Text(vm.status.rawValue).foregroundStyle(.secondary)
            Spacer()
            if vm.status.isRunning {
              Button("Suspend") { Task { await store.suspend(vm) } }
              Button("Stop") { Task { await store.stop(vm) } }
            } else {
              Button("Start") { Task { await store.start(vm) } }
                .buttonStyle(.borderedProminent)
            }
          }
          .disabled(store.pending.contains(vm.id) || vm.status.isBusy)
        }
        Section("Connection") {
          Picker("System", selection: Binding(
            get: { system }, set: { settings.system = $0; settings.save(vm.id) })) {
            ForEach(VirtualMachine.System.allCases, id: \.self) { Text($0.title).tag($0) }
          }
          TextField("SSH user", text: $settings.user)
            .onSubmit { settings.save(vm.id) }
          TextField("Host", text: $settings.host, prompt: Text(address ?? "found automatically"))
            .onSubmit { settings.save(vm.id); Task { await resolve() } }
          HStack {
            if isResolving {
              ProgressView().controlSize(.small)
              Text("Looking for the VM's address…").foregroundStyle(.secondary)
            } else if let target {
              Text("ssh \(target)").font(.callout.monospaced()).textSelection(.enabled)
              Spacer()
              Button("Open in Terminal") { openTerminal(target) }
            } else {
              Text(vm.status.isRunning
                ? "No address yet. Enter the VM's host, or wait for it to finish booting."
                : "Start the VM to connect.")
                .foregroundStyle(.secondary)
              Spacer()
              if vm.status.isRunning { Button("Retry") { Task { await resolve() } } }
            }
          }
          .font(.callout)
        }
        Section("Run on VM") {
          Picker("Project", selection: $projectID) {
            Text("Choose…").tag(URL?.none)
            ForEach(projects.filter { $0.rootURL != nil }) { row in
              Text(row.name).tag(row.rootURL)
            }
          }
          TextField("Command", text: $command, prompt: Text("swift build"))
            .font(.body.monospaced())
          HStack {
            Text(system == .windows
              ? "Copied with tar to dev-sync\\<project> in the user's home."
              : "Mirrored with rsync to ~/dev-sync/<project>; runs in a login shell.")
              .font(.caption).foregroundStyle(.secondary)
            Spacer()
            if runner.isRunning {
              Button("Stop", role: .destructive) { runner.cancel() }
            } else {
              Button("Run") {
                guard let root = projectID, let target else { return }
                settings.save(vm.id)
                runner.run(project: root, on: target, system: system, command: command)
              }
              .keyboardShortcut(.defaultAction)
              .disabled(projectID == nil || target == nil || command.isEmpty)
            }
          }
        }
      }
      .formStyle(.grouped)
      .frame(maxHeight: 460)
      Divider()
      logView
    }
    .task(id: vm.status) { await resolve() }
    .onChange(of: projectID) { _, root in
      if let root { command = VMRunner.defaultCommand(for: root, system: system) }
    }
    .onDisappear { settings.save(vm.id) }
  }

  private var logView: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 1) {
          ForEach(Array(runner.log.enumerated()), id: \.offset) { index, line in
            Text(line)
              .font(.system(.caption, design: .monospaced))
              .foregroundStyle(line.hasPrefix("::") ? Color.accentColor
                : line.contains("error") ? .red : .primary)
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
              .id(index)
          }
          if let status = runner.exitStatus {
            Label(status == 0 ? "Finished" : "Exited with \(status)",
                  systemImage: status == 0 ? "checkmark.circle.fill" : "xmark.octagon.fill")
              .foregroundStyle(status == 0 ? .green : .red)
              .padding(.top, 6)
          }
        }
        .padding(10)
      }
      .onChange(of: runner.log.count) { _, count in proxy.scrollTo(count - 1, anchor: .bottom) }
    }
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
    NSWorkspace.shared.open(file)
  }
}

/// The sidebar's VMs row: how many VMs are running.
struct VMsSidebarRow: View {
  @Environment(VMStore.self) private var store

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "desktopcomputer")
        .font(.system(size: 15))
        .foregroundStyle(.tertiary)
        .frame(width: 24, height: 24)
      VStack(alignment: .leading, spacing: 1) {
        Text("Virtual Machines")
          .lineLimit(1)
        Text(status)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer(minLength: 0)
    }
    .task { await store.refresh() }
  }

  private var status: String {
    if VMStore.utmctl == nil { return "UTM not installed" }
    let running = store.machines.filter(\.status.isRunning).count
    if store.machines.isEmpty { return "No VMs" }
    return running == 0 ? "\(store.machines.count) stopped" : "\(running) running"
  }
}
