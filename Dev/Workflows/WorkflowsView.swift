//
//  WorkflowsView.swift
//  Dev
//

import AppKit
import ComponentKit
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
    KitWindowLayout {
      sidebar(list, selected: workflow)
        .frame(width: 240)
        .kitPane(.secondary)
      if let workflow {
        steps(workflow)
          .frame(maxWidth: .infinity)
          .kitPane()
        inspector(workflow)
          .frame(width: 310)
      } else {
        EmptyState(systemImage: "shippingbox", title: "No Workflows")
          .kitPane()
      }
    }
    .toolbar {
      KitToolbarItem(placement: .primaryAction) {
        ToolGroup {
          if store.isRunning(root) {
            Button("Stop", systemImage: "stop.fill", role: .destructive) { store.cancel(root) }
              .help("Stop the run in flight")
          } else if let workflow {
            // Short, so it never crowds the project's tabs in the toolbar's centre.
            Button("Run", systemImage: "play.fill") {
              if workflow.steps.contains(where: \.publishes) { confirmingRun = workflow } else { start(workflow, confirmed: false) }
            }
            .help("Run \(workflow.name) now")
            .disabled(releaseConfig == nil && workflow.steps.contains { $0.kind != .command })
          }
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

  /// A row of the left list: a workflow, or one of its runs.
  private nonisolated enum Pick: Hashable, Sendable {
    case workflow(String)
    case run(UUID)
  }

  /// The list holds two marks: the run the middle shows is selected, its workflow is current (selected itself
  /// before it ever ran).
  private func pick(_ selected: Workflow?) -> Binding<Pick?> {
    Binding(
      get: {
        guard let selected else { return nil }
        if let run = currentRun(selected) { return .run(run.id) }
        return .workflow(selected.id)
      },
      set: { pick in
        switch pick {
        case .workflow(let id):
          workflowID = id
          runID = nil
          stepID = nil
        case .run(let id):
          runID = id
        case nil:
          break
        }
      })
  }

  private func sidebar(_ list: [Workflow], selected: Workflow?) -> some View {
    KitList(selection: pick(selected)) {
      KitSection(
        "Workflows", meta: list.count == 1 ? "1 workflow" : "\(list.count) workflows",
        systemImage: "play", hue: .blue
      ) {
        ForEach(list) { workflow in
          SidebarRow(value: Pick.workflow(workflow.id), workflow.name, subtitle: workflow.trigger.summary) {
            EmptyView()
          }
          .isCurrent(selected?.id == workflow.id)
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
      } accessory: {
        Button("New Workflow…", systemImage: "plus") {
          let id = "workflow-\(Int(Date().timeIntervalSince1970))"
          editing = Workflow(id: id, name: "New Workflow", steps: [
            Workflow.Step(id: "build", name: "Build", kind: .release, releaseStep: "build"),
          ])
        }
        .help("New Workflow…")
      }
      if let selected {
        let runs = store.runs(for: root).filter { $0.workflowID == selected.id }
        KitSection(
          "Runs", meta: runs.isEmpty ? "None yet" : "\(runs.count) run\(runs.count == 1 ? "" : "s")",
          systemImage: "clock", hue: .gray, status: runs.first?.state == .running ? .working : .idle
        ) {
          if runs.isEmpty {
            Text("Runs show here when a workflow starts.")
              .kitFont(.caption)
              .padding(.horizontal, 6)
              .padding(.bottom, 4)
          }
          ForEach(runs) { run in
            SidebarRow(
              value: Pick.run(run.id),
              run.title.isEmpty ? run.startedAt.formatted(date: .abbreviated, time: .shortened) : run.title,
              systemImage: "play", hue: .gray, status: Self.status(for: run.state)
            )
            .subtitle {
              Text(runNote(run)).foregroundStyle(run.state == .failed ? AnyShapeStyle(Hue.red.text) : AnyShapeStyle(.kitSecondary))
            }
          }
        }
      }
    }
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

  /// A run's state as the kit's work status: its live icon carries it.
  static func status(for state: WorkflowRun.State) -> WorkStatus {
    switch state {
    case .running: .working
    case .passed: .done
    case .failed: .failed
    case .cancelled: .paused()
    }
  }

  /// A step's state as the kit's work status.
  static func status(for state: WorkflowRun.StepState) -> WorkStatus {
    switch state {
    case .waiting: .idle
    case .running: .working
    case .passed: .done
    case .failed: .failed
    case .skipped: .paused()
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
      VStack(alignment: .leading, spacing: 10) {
        if releaseConfig == nil, workflow.steps.contains(where: { $0.kind != .command }) {
          Banner(
            "This project has no release.env yet.", message: "release.sh steps need one.",
            systemImage: "exclamationmark.triangle", hue: .orange
          ) {
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
          .padding([.horizontal, .top], -KitMetrics.gutter)
          .padding(.bottom, 4)
        }
        HStack {
          Text(run.map { "\(workflow.name) \($0.version ?? "")" } ?? workflow.name)
            .kitFont(.title1)
            .lineLimit(1)
          Spacer()
          Button("Edit…") { editing = workflow }
          Button("Release Settings…") { showsReleaseSettings = true }
            .disabled(releaseConfig == nil)
            .help("The project's release.env: scheme, signing, notarization, GitHub and App Store Connect")
        }
        .buttonStyle(.kit)
        if run == nil || run?.state != .running {
          TextField("Version", text: $version, prompt: Text("Version for the next run (empty reads the project's)"))
            .kitField()
            .frame(maxWidth: 380)
            .help("Passed to release.sh as --version; empty reads MARKETING_VERSION")
        }
        HStack(spacing: 6) {
          if let run {
            if let build = run.buildNumber {
              Chip("Build \(build) = commit count", hue: .accent)
                .help("git rev-list --count HEAD")
            }
            if let commit = run.commit { Chip(Text(commit).monospaced(), style: .quiet) }
            Chip("Started by \(run.startedBy)")
            if let finished = run.finishedAt {
              Chip("\(finished.timeIntervalSince(run.startedAt).clock)")
            }
          } else {
            Chip(workflow.trigger.summary)
            Chip(workflow.steps.count == 1 ? "1 step" : "\(workflow.steps.count) steps")
          }
        }
      }
      .padding(16)

      List {
        ForEach(Array(stages(workflow).enumerated()), id: \.offset) { _, stage in
          if stage.count == 1, let step = stage.first {
            stepRow(step, run: run)
          } else {
            VStack(alignment: .leading, spacing: 2) {
              Text("At the same time")
                .kitFont(.caption)
                .padding(.horizontal, 6)
              ForEach(stage) { step in stepRow(step, run: run) }
            }
            .padding(2)
            .background(.kitField, in: RoundedRectangle(cornerRadius: KitMetrics.radiusLarge, style: .continuous))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
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
        .buttonStyle(.kitPlain)
        .foregroundStyle(Hue.accent.text)
        .fixedSize()
        .padding(.vertical, 6)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
      }
      .listStyle(.plain)
      .scrollContentBackground(.hidden)

      StatusBar {
        Text("Defined in")
        Text(".dev/workflows/\(workflow.id).json")
          .kitFont(.mono)
          .foregroundStyle(.kitLabel)
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
        .buttonStyle(.kitPlain)
        .foregroundStyle(Hue.accent.text)
      }
      .foregroundStyle(.kitSecondary)
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
      LaneItem(
        step.name, subtitle: state?.note ?? step.runnerTitle, subtitleHue: state?.state == .failed ? .red : nil,
        isSelected: isSelectedStep(step)
      ) {
        StepStateIcon(state: state?.state)
      }
      .overlay(alignment: .trailing) {
        if let duration = state?.duration {
          Count(duration.clock).padding(.trailing, 8)
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .listRowBackground(Color.clear)
    .listRowSeparator(.hidden)
    .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
  }

  /// The step the inspector shows: the picked one, else the first.
  private func isSelectedStep(_ step: Workflow.Step) -> Bool {
    guard let stepID else {
      return store.workflows(for: root).first { $0.steps.contains(step) }?.steps.first == step
    }
    return stepID == step.id
  }

  // MARK: - Right: the step

  @ViewBuilder
  private func inspector(_ workflow: Workflow) -> some View {
    let step = workflow.steps.first { $0.id == stepID } ?? workflow.steps.first
    let run = currentRun(workflow)
    if let step, let index = workflow.steps.firstIndex(of: step) {
      KitInspector(width: nil) {
        InspectorHeader(
          step.name, meta: ["Step \(index + 1) of \(workflow.steps.count)", step.runnerTitle],
          systemImage: step.kind == .command ? "terminal" : "hammer",
          status: run.flatMap { $0.steps.first { $0.id == step.id } }.map { Self.status(for: $0.state) } ?? .idle)
        FormCard {
          FormRow("Name", systemImage: "character.cursor.ibeam", hue: .gray,
                  field: TextField("Name", text: binding(workflow, index, \.name)))
          FormRow("Runs On", help: step.runnerTitle, systemImage: "laptopcomputer", hue: .gray) {
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
            .fixedSize()
          }
          if step.kind == .command {
            FormRow("Command", systemImage: "apple.terminal", hue: .green, field: TextField(
              "Command",
              text: Binding(
                get: { step.command ?? "" },
                set: { value in update(workflow) { $0.steps[index].command = value } }),
              axis: .vertical
            ).kitFont(.mono))
          } else {
            FormRow("Command", systemImage: "apple.terminal", hue: .green, field: Text(step.commandLine)
              .kitFont(.mono)
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading))
          }
          FormRow("Run at the same time as the step before", systemImage: "arrow.left.and.right", hue: .gray) {
            Toggle("Run at the same time as the step before", isOn: binding(workflow, index, \.parallel))
              .labelsHidden()
              .toggleStyle(.kitSwitch)
          }
          .disabled(index == 0)
          FormRow("Keep going when a step fails", systemImage: "arrow.triangle.branch", hue: .orange) {
            Toggle("Keep going when a step fails", isOn: Binding(
              get: { workflow.continueOnFailure },
              set: { value in update(workflow) { $0.continueOnFailure = value } }))
              .labelsHidden()
              .toggleStyle(.kitSwitch)
          }
        }
        if let run, let state = run.steps.first(where: { $0.id == step.id }) {
          let lines = store.logs[run.id]?[step.id] ?? state.logTail
          RunBlocks {
            RunBlock(
              step.name, command: step.commandLine, status: Self.status(for: state.state),
              duration: state.duration?.clock, output: lines.suffix(400).joined(separator: "\n"))
          }
        }
        Button("Remove Step", role: .destructive) {
          update(workflow) { $0.steps.remove(at: index) }
          stepID = nil
        }
        .buttonStyle(.kit)
        .disabled(store.isRunning(root))
      }
    } else {
      EmptyState(systemImage: "list.bullet", title: "No Steps").kitPane(.secondary)
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

/// A step's state in its live icon: done, running, failed, skipped or waiting.
struct StepStateIcon: View {
  let state: WorkflowRun.StepState?

  var body: some View {
    switch state {
    case .passed: LiveIcon(systemImage: "checkmark", hue: .green, status: .done, size: 22)
    case .failed: LiveIcon(systemImage: "xmark", hue: .red, status: .failed, size: 22)
    case .running: LiveIcon(systemImage: "hammer", status: .working, size: 22)
    case .skipped: LiveIcon(systemImage: "arrow.uturn.forward", hue: .gray, status: .paused(), size: 22)
    case .waiting, nil: LiveIcon(systemImage: "circle.dashed", hue: .gray, status: .idle, size: 22)
    }
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
