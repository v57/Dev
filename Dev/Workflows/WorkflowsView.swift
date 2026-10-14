//
//  WorkflowsView.swift
//  Dev
//

import AppKit
import SwiftUI

/// The Workflows tab: a project's CI. Left, its workflows and their runs;
/// middle, the steps of the selected run (or of the workflow, before it ran);
/// right, the selected step — where it runs, what it runs, and its log.
/// Every edit is written to `.dev/workflows`, which agents edit over MCP too.
struct WorkflowsView: View {
  let root: URL
  let projectName: String

  @Environment(WorkflowStore.self) private var store
  @Environment(VMStore.self) private var vms
  @State private var workflowID: String?
  @State private var runID: UUID?
  @State private var stepID: String?
  @State private var version = ""
  @State private var confirmingRun: Workflow?
  @State private var editing: Workflow?
  @State private var saveError: String?
  @State private var releaseConfig: ReleaseConfig?
  @State private var showsReleaseSettings = false
  @State private var isDetecting = false

  var body: some View {
    let list = store.workflows(for: root)
    let workflow = list.first { $0.id == workflowID } ?? list.first
    HStack(spacing: 0) {
      sidebar(list, selected: workflow)
        .frame(width: 240)
      Divider()
      if let workflow {
        steps(workflow)
          .frame(maxWidth: .infinity)
        Divider()
        inspector(workflow)
          .frame(width: 300)
      } else {
        ContentUnavailableView("No workflows", systemImage: "shippingbox")
          .frame(maxWidth: .infinity)
      }
    }
    .toolbar {
      ToolbarItemGroup(placement: .primaryAction) {
        if store.isRunning(root) {
          Button(role: .destructive) { store.cancel(root) } label: {
            Label("Stop", systemImage: "stop.fill")
          }
          .help("Stop the run in flight")
        } else if let workflow {
          Button {
            if workflow.steps.contains(where: \.publishes) { confirmingRun = workflow } else { start(workflow, confirmed: false) }
          } label: {
            // Short, so it never crowds the project's tabs in the toolbar's centre.
            Label("Run", systemImage: "play.fill")
              .labelStyle(.titleAndIcon)
          }
          .help("Run \(workflow.name) now")
          .disabled(releaseConfig == nil && workflow.steps.contains { $0.kind != .command })
        }
      }
    }
    .task(id: root) {
      releaseConfig = ReleaseConfig.load(from: root)
      store.reload(root)
      if vms.machines.isEmpty { await vms.refresh() }
      // Design checks: Release Settings for the project as detected, never saved.
      if LaunchOptions.isScreenshotMode, LaunchOptions.open == "releaseSettings" {
        if releaseConfig == nil { releaseConfig = await ReleaseConfig.detect(in: root) }
        showsReleaseSettings = true
      }
    }
    .alert("Run \(confirmingRun?.name ?? "")?", isPresented: Binding(
      get: { confirmingRun != nil }, set: { if !$0 { confirmingRun = nil } })
    ) {
      Button("Cancel", role: .cancel) { confirmingRun = nil }
      Button("Run") {
        if let workflow = confirmingRun { start(workflow, confirmed: true) }
        confirmingRun = nil
      }
    } message: {
      let names = confirmingRun?.steps.filter(\.publishes).map(\.name).joined(separator: ", ") ?? ""
      Text("This run publishes: \(names). It sends the build outside this Mac.")
    }
    .alert(
      "\(store.confirmation?.workflowName ?? "") wants to publish",
      isPresented: Binding(get: { store.confirmation?.root == root }, set: { _ in })
    ) {
      Button("Don't Publish", role: .cancel) { if let c = store.confirmation { store.answer(c, false) } }
      Button("Publish") { if let c = store.confirmation { store.answer(c, true) } }
    } message: {
      let c = store.confirmation
      Text("Started by \(c?.startedBy ?? "you"). Next: \(c?.steps.joined(separator: ", ") ?? "").")
    }
    .alert(store.notice ?? "", isPresented: Binding(get: { store.notice != nil }, set: { if !$0 { store.notice = nil } })) {
      Button("OK") { store.notice = nil }
    }
    .alert(saveError ?? "", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
      Button("OK") { saveError = nil }
    }
    .sheet(isPresented: $showsReleaseSettings) {
      ReleaseSettingsSheet(config: releaseConfig ?? ReleaseConfig()) { edited in
        do {
          try edited.save(to: root)
          releaseConfig = edited
        } catch {
          saveError = error.localizedDescription
        }
      }
    }
    .sheet(item: $editing) { workflow in
      WorkflowSettingsSheet(workflow: workflow) { edited in
        save(edited)
      } onDelete: {
        store.delete(workflow.id, in: root)
        workflowID = nil
      }
    }
  }

  private func start(_ workflow: Workflow, confirmed: Bool) {
    store.start(workflow, in: root, version: version, confirmedPublishing: confirmed)
    runID = store.active[root]?.id
  }

  private func save(_ workflow: Workflow) {
    do { try store.save(workflow, in: root) } catch { saveError = error.localizedDescription }
  }

  // MARK: - Left: workflows and runs

  private func sidebar(_ list: [Workflow], selected: Workflow?) -> some View {
    List {
      Section("Workflows") {
        ForEach(list) { workflow in
          Button {
            workflowID = workflow.id
            runID = nil
            stepID = nil
          } label: {
            VStack(alignment: .leading, spacing: 2) {
              Text(workflow.name).fontWeight(.semibold)
              Text(workflow.trigger.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .listRowBackground(selected?.id == workflow.id ? Color.secondary.opacity(0.12) : Color.clear)
          .contextMenu {
            Button("Edit…") { editing = workflow }
            Button("Duplicate") {
              var copy = workflow
              copy.id = workflow.id + "-copy"
              copy.name = workflow.name + " Copy"
              save(copy)
            }
          }
        }
        Button {
          let id = "workflow-\(Int(Date().timeIntervalSince1970))"
          editing = Workflow(id: id, name: "New Workflow", steps: [
            Workflow.Step(id: "build", name: "Build", kind: .release, releaseStep: "build"),
          ])
        } label: {
          Label("New Workflow…", systemImage: "plus")
        }
        .buttonStyle(.link)
      }
      if let selected {
        Section("Runs") {
          let runs = store.runs(for: root).filter { $0.workflowID == selected.id }
          if runs.isEmpty {
            Text("No runs yet").foregroundStyle(.secondary)
          }
          ForEach(runs) { run in
            Button {
              runID = run.id
            } label: {
              HStack(spacing: 8) {
                Circle().fill(Self.color(for: run.state)).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                  Text(run.title.isEmpty ? run.startedAt.formatted(date: .abbreviated, time: .shortened) : run.title)
                    .monospacedDigit()
                  Text(runNote(run))
                    .font(.caption)
                    .foregroundStyle(run.state == .failed ? .red : .secondary)
                    .lineLimit(1)
                }
                Spacer(minLength: 0)
              }
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowBackground(currentRun(selected)?.id == run.id ? Color.secondary.opacity(0.12) : Color.clear)
          }
        }
      }
    }
    .listStyle(.sidebar)
  }

  private func runNote(_ run: WorkflowRun) -> String {
    switch run.state {
    case .running: return "Running · \(run.commit ?? "")"
    case .failed:
      let step = run.steps.first { $0.state == .failed }
      return "Failed · \(step?.name ?? "") · \(run.startedAt.formatted(date: .abbreviated, time: .omitted))"
    case .passed: return "Passed · \(run.startedAt.formatted(date: .abbreviated, time: .omitted))"
    case .cancelled: return "Cancelled · \(run.startedAt.formatted(date: .abbreviated, time: .omitted))"
    }
  }

  static func color(for state: WorkflowRun.State) -> Color {
    switch state {
    case .running: return .accentColor
    case .passed: return .green
    case .failed: return .red
    case .cancelled: return .secondary
    }
  }

  /// The run on screen: the one picked, else the one in flight, else none.
  private func currentRun(_ workflow: Workflow) -> WorkflowRun? {
    let runs = store.runs(for: root).filter { $0.workflowID == workflow.id }
    if let runID, let run = runs.first(where: { $0.id == runID }) { return run }
    if let active = store.active[root], active.workflowID == workflow.id { return active }
    return runs.first
  }

  // MARK: - Middle: steps

  private func steps(_ workflow: Workflow) -> some View {
    let run = currentRun(workflow)
    return VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 8) {
        if releaseConfig == nil, workflow.steps.contains(where: { $0.kind != .command }) {
          HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("This project has no release.env yet: release.sh steps need one.")
            Spacer()
            Button(isDetecting ? "Reading the project…" : "Set Up Release") {
              Task {
                isDetecting = true
                let detected = await ReleaseConfig.detect(in: root)
                isDetecting = false
                try? detected.save(to: root)
                releaseConfig = detected
                showsReleaseSettings = true
              }
            }
            .disabled(isDetecting)
          }
          .padding(10)
          .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        }
        HStack {
          Text(run.map { "\(workflow.name) \($0.version ?? "")" } ?? workflow.name)
            .font(.title2.weight(.bold))
            .lineLimit(1)
          Spacer()
          Button("Edit…") { editing = workflow }
          Button("Release Settings…") { showsReleaseSettings = true }
            .disabled(releaseConfig == nil)
            .help("The project's release.env: scheme, signing, notarization, GitHub and App Store Connect")
        }
        if run == nil || run?.state != .running {
          TextField("Version", text: $version, prompt: Text("Version for the next run (empty reads the project's)"))
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 360)
            .help("Passed to release.sh as --version; empty reads MARKETING_VERSION")
        }
        HStack(spacing: 6) {
          if let run {
            if let build = run.buildNumber {
              chip("Build \(build) = commit count", tint: .accentColor)
                .help("git rev-list --count HEAD")
            }
            if let commit = run.commit { chip(commit, monospaced: true) }
            chip("Started by \(run.startedBy)")
            if let finished = run.finishedAt {
              chip("\(finished.timeIntervalSince(run.startedAt).clock)")
            }
          } else {
            chip(workflow.trigger.summary)
            chip(workflow.steps.count == 1 ? "1 step" : "\(workflow.steps.count) steps")
          }
        }
      }
      .padding(16)

      List {
        ForEach(Array(stages(workflow).enumerated()), id: \.offset) { _, stage in
          if stage.count == 1, let step = stage.first {
            stepRow(step, run: run)
          } else {
            VStack(alignment: .leading, spacing: 6) {
              Text("At the same time")
                .font(.caption)
                .foregroundStyle(.secondary)
              ForEach(stage) { step in stepRow(step, run: run) }
            }
          }
        }
        .onMove { from, to in move(workflow, from: from, to: to) }
        Menu {
          ForEach(ReleaseStep.allCases) { step in
            Button(step.title) { add(Workflow.Step(id: uniqueID(step.rawValue, in: workflow), name: step.title, kind: .release, releaseStep: step.rawValue), to: workflow) }
          }
          Divider()
          Button("Screenshots") { add(Workflow.Step(id: uniqueID("screenshots", in: workflow), name: "Screenshots", kind: .screenshots), to: workflow) }
          Button("Command on This Mac") { add(Workflow.Step(id: uniqueID("command", in: workflow), name: "Command", kind: .command, command: "swift test"), to: workflow) }
          ForEach(vms.machines) { vm in
            Button("Command on \(vm.name)") {
              add(Workflow.Step(id: uniqueID("vm", in: workflow), name: "Test on \(vm.name)", kind: .command,
                                command: VMRunner.defaultCommand(for: root, system: VMSettings.load(vm.id).system ?? vm.guessedSystem),
                                runner: "vm:" + vm.name, parallel: true), to: workflow)
            }
          }
        } label: {
          Label("Add Step", systemImage: "plus")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .padding(.vertical, 6)
      }
      .listStyle(.inset)

      Divider()
      HStack(spacing: 6) {
        Text("Defined in")
        Text(".dev/workflows/\(workflow.id).json")
          .font(.system(.caption, design: .monospaced))
          .foregroundStyle(.primary)
        Text("· edited here or by an agent through MCP")
        Spacer()
        Button("Show File") {
          let url = Workflow.url(workflow.id, in: root)
          if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
          } else {
            save(workflow)
            NSWorkspace.shared.activateFileViewerSelecting([url])
          }
        }
        .buttonStyle(.link)
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      .padding(.horizontal, 16)
      .padding(.vertical, 8)
    }
  }

  private func stages(_ workflow: Workflow) -> [[Workflow.Step]] {
    var stages: [[Workflow.Step]] = []
    for step in workflow.steps {
      if step.parallel, !stages.isEmpty { stages[stages.count - 1].append(step) } else { stages.append([step]) }
    }
    return stages
  }

  private func stepRow(_ step: Workflow.Step, run: WorkflowRun?) -> some View {
    let state = run?.steps.first { $0.id == step.id }
    return Button {
      stepID = step.id
    } label: {
      HStack(spacing: 12) {
        StepStateIcon(state: state?.state)
        VStack(alignment: .leading, spacing: 2) {
          Text(step.name).fontWeight(.semibold)
          Text(state?.note ?? step.runnerTitle)
            .font(.caption)
            .foregroundStyle(state?.state == .failed ? .red : .secondary)
            .lineLimit(1)
        }
        Spacer()
        if let duration = state?.duration {
          Text(duration.clock)
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(state?.state == .running ? Color.accentColor : .secondary)
        }
      }
      .padding(.vertical, 4)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .listRowBackground(stepID == step.id ? Color.secondary.opacity(0.12) : Color.clear)
  }

  private func chip(_ text: String, tint: Color = .secondary, monospaced: Bool = false) -> some View {
    Text(text)
      .lineLimit(1)
      .fixedSize()
      .font(monospaced ? .system(.caption, design: .monospaced) : .caption)
      .padding(.horizontal, 8)
      .padding(.vertical, 2)
      .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
      .foregroundStyle(tint == .secondary ? Color.primary : tint)
  }

  // MARK: - Right: the step

  @ViewBuilder
  private func inspector(_ workflow: Workflow) -> some View {
    let step = workflow.steps.first { $0.id == stepID } ?? workflow.steps.first
    let run = currentRun(workflow)
    if let step, let index = workflow.steps.firstIndex(of: step) {
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          TextField("Name", text: binding(workflow, index, \.name))
            .textFieldStyle(.plain)
            .font(.headline)
          field("Runs On") {
            Picker("Runs On", selection: binding(workflow, index, \.runner)) {
              Text("This Mac").tag("mac")
              if step.kind == .command {
                ForEach(vms.machines) { vm in Text("\(vm.name) (VM)").tag("vm:" + vm.name) }
                if let name = step.vmName, !vms.machines.contains(where: { $0.name == name }) {
                  Text("\(name) (VM)").tag(step.runner)
                }
              }
            }
            .labelsHidden()
          }
          field("Command") {
            if step.kind == .command {
              TextEditor(text: Binding(
                get: { step.command ?? "" },
                set: { value in update(workflow) { $0.steps[index].command = value } }))
                .font(.system(.callout, design: .monospaced))
                .frame(minHeight: 60)
                .padding(4)
                .background(.background, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
            } else {
              Text(step.commandLine)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
            }
          }
          Toggle("Run at the same time as the step before", isOn: binding(workflow, index, \.parallel))
            .disabled(index == 0)
          Toggle("Keep going when a step fails", isOn: Binding(
            get: { workflow.continueOnFailure },
            set: { value in update(workflow) { $0.continueOnFailure = value } }))
          if let run, let state = run.steps.first(where: { $0.id == step.id }) {
            field("Log") {
              let lines = store.logs[run.id]?[step.id] ?? state.logTail
              ScrollView {
                Text(lines.suffix(400).joined(separator: "\n"))
                  .font(.system(.caption, design: .monospaced))
                  .textSelection(.enabled)
                  .frame(maxWidth: .infinity, alignment: .leading)
              }
              .frame(minHeight: 180, maxHeight: 320)
              .padding(8)
              .background(.background, in: RoundedRectangle(cornerRadius: 8))
              .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
            }
          }
          Button("Remove Step", role: .destructive) {
            update(workflow) { $0.steps.remove(at: index) }
            stepID = nil
          }
          .buttonStyle(.link)
          .disabled(store.isRunning(root))
        }
        .padding(16)
      }
      .background(.background.secondary)
    } else {
      ContentUnavailableView("No steps", systemImage: "list.bullet")
    }
  }

  private func field<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(title)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      content()
    }
  }

  // MARK: - Editing

  private func update(_ workflow: Workflow, _ change: (inout Workflow) -> Void) {
    var edited = workflow
    change(&edited)
    save(edited)
  }

  private func binding<Value>(_ workflow: Workflow, _ index: Int, _ path: WritableKeyPath<Workflow.Step, Value>) -> Binding<Value> {
    Binding(
      get: { workflow.steps[index][keyPath: path] },
      set: { value in update(workflow) { $0.steps[index][keyPath: path] = value } })
  }

  private func add(_ step: Workflow.Step, to workflow: Workflow) {
    update(workflow) { $0.steps.append(step) }
    stepID = step.id
  }

  private func move(_ workflow: Workflow, from: IndexSet, to: Int) {
    // Stages are rows; moving a row moves its steps.
    var stages = stages(workflow)
    stages.move(fromOffsets: from, toOffset: to)
    update(workflow) { edited in
      edited.steps = stages.enumerated().flatMap { _, stage in
        stage.enumerated().map { offset, step in
          var step = step
          step.parallel = offset > 0
          return step
        }
      }
    }
  }

  private func uniqueID(_ base: String, in workflow: Workflow) -> String {
    var id = base
    var n = 2
    while workflow.steps.contains(where: { $0.id == id }) {
      id = "\(base)-\(n)"
      n += 1
    }
    return id
  }
}

/// A step's state as a symbol: done, running, failed, skipped or waiting.
struct StepStateIcon: View {
  let state: WorkflowRun.StepState?

  var body: some View {
    Group {
      switch state {
      case .passed:
        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
      case .failed:
        Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
      case .running:
        ProgressView().controlSize(.small)
      case .skipped:
        Image(systemName: "arrow.uturn.forward.circle").foregroundStyle(.secondary)
      case .waiting, nil:
        Image(systemName: "circle.dashed").foregroundStyle(.tertiary)
      }
    }
    .font(.title3)
    .frame(width: 22, height: 22)
  }
}

/// A workflow's name and triggers, and its deletion.
struct WorkflowSettingsSheet: View {
  @State var workflow: Workflow
  let onSave: (Workflow) -> Void
  let onDelete: () -> Void
  @Environment(\.dismiss) private var dismiss

  init(workflow: Workflow, onSave: @escaping (Workflow) -> Void, onDelete: @escaping () -> Void) {
    _workflow = State(initialValue: workflow)
    self.onSave = onSave
    self.onDelete = onDelete
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Workflow").font(.headline)
      Form {
        TextField("Name", text: $workflow.name)
        Section("Runs on its own") {
          TextField("Every commit on branch", text: optional(\.trigger.branch), prompt: Text("main"))
          TextField("New tags matching", text: optional(\.trigger.tag), prompt: Text("v*"))
          TextField("Every day at", text: optional(\.trigger.daily), prompt: Text("02:00"))
          Text("Dev checks these while it is open: there is no server, so nothing runs while the Mac sleeps or Dev is quit.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .formStyle(.grouped)
      HStack {
        Button("Delete Workflow", role: .destructive) {
          onDelete()
          dismiss()
        }
        Spacer()
        Button("Cancel") { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Save") {
          onSave(workflow)
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(workflow.name.trimmingCharacters(in: .whitespaces).isEmpty)
      }
    }
    .padding(20)
    .frame(width: 460, height: 380)
  }

  private func optional(_ path: WritableKeyPath<Workflow, String?>) -> Binding<String> {
    Binding(get: { workflow[keyPath: path] ?? "" }, set: { workflow[keyPath: path] = $0.isEmpty ? nil : $0 })
  }
}
