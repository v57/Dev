//
//  ScreenshotsView.swift
//  Dev
//

import AppKit
import DevScreenshots
import DevScreenshotsCapture
import SwiftUI

/// The Screenshots tab: capture (the scenes in `.dev/screenshots.json`, through Dev's own
/// `dev-screenshots`), frame (the file's `framing` section), review and upload. The framing and
/// the captions are edited on the right; an agent can edit the same file over MCP, and the card at
/// the top says when one did.
struct ScreenshotsView: View {
  let root: URL
  let projectName: String

  @Environment(ScreenshotsStore.self) private var store
  @State private var locale: String?
  @State private var target: String?
  @State private var showsFinal = true
  /// The config as the reader is editing it; only its framing and captions are saved.
  @State private var draft: ScreenshotConfig?
  @State private var showsLog = false
  @State private var selectedScene: String?
  @State private var uploading = false

  var body: some View {
    let library = store.library(root)
    VStack(spacing: 0) {
      stageBar(library)
      Divider()
      HStack(spacing: 0) {
        grid(library)
          .frame(maxWidth: .infinity)
        Divider()
        inspector(library)
          .frame(width: 320)
      }
    }
    .toolbar {
      ToolbarItemGroup(placement: .primaryAction) {
        if store.phase(root) == .capturing {
          Button(role: .destructive) { store.cancelCapture(root) } label: { Label("Stop", systemImage: "stop.fill") }
        } else {
          Button { store.capture(root) } label: { Label("Capture", systemImage: "camera") }
            .help("Take the scenes in .dev/screenshots.json, then frame them")
            .disabled(store.phase(root) != .idle || library?.config == nil)
        }
        Button { uploading = true } label: { Label("Upload…", systemImage: "icloud.and.arrow.up") }
          .help("Upload the framed screenshots to App Store Connect")
          .disabled(library?.shots.contains { $0.final != nil } != true)
      }
    }
    .task(id: root) {
      await store.refresh(root)
      draft = store.config(root)
    }
    .onChange(of: store.config(root)) { _, config in
      // A file written elsewhere (an agent, a save) replaces the draft.
      draft = config
    }
    .sheet(isPresented: $showsLog) { logSheet }
    .sheet(isPresented: $uploading) {
      AppStoreUploadSheet(root: root, library: library)
    }
  }

  // MARK: - Stages

  private func stageBar(_ library: ScreenshotLibrary?) -> some View {
    let phase = store.phase(root)
    let captured = !(library?.shots.isEmpty ?? true)
    let processed = library?.shots.contains { $0.final != nil } ?? false
    let outdated = library?.outdated.count ?? 0
    return HStack(spacing: 10) {
      stage(1, "Capture", phase == .capturing
              ? (store.paused.contains(root) ? "Paused: switch back to the app" : "Taking the scenes…")
              : captureDetail(library),
            done: captured && phase != .capturing && outdated == 0, current: phase == .capturing || !captured,
            warning: captured && phase != .capturing && outdated > 0)
      connector(captured)
      stage(2, "Frame", phase == .processing ? "Framing…" :
              (store.reports[root].map { "\($0.rendered) pictures" } ?? "Not framed yet"),
            done: processed && phase != .processing, current: phase == .processing)
      connector(processed)
      stage(3, "Review", library?.status?.summary ?? "Nothing to review",
            done: false, current: processed && phase == .idle)
      connector(false)
      stage(4, "Upload", "App Store Connect", done: false, current: false)
      Spacer()
      if !store.logs[root, default: []].isEmpty {
        Button("Show Log") { showsLog = true }.buttonStyle(.link)
      }
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 10)
    .background(.background.secondary)
  }

  private func captureDetail(_ library: ScreenshotLibrary?) -> String {
    guard let library, let date = library.capturedAt else { return "Not captured yet" }
    let when = "Captured \(date.formatted(.relative(presentation: .named)))"
    let outdated = library.outdated.count
    return outdated == 0 ? when : "\(outdated) of \(library.status?.scenes.count ?? 0) scenes outdated"
  }

  private func stage(
    _ number: Int, _ title: String, _ detail: String, done: Bool, current: Bool, warning: Bool = false
  ) -> some View {
    HStack(spacing: 8) {
      ZStack {
        Circle().fill(done ? Color.green : (warning ? Color.orange : (current ? Color.accentColor : Color.clear)))
        if !done && !current && !warning { Circle().strokeBorder(.tertiary, lineWidth: 1.5) }
        if done {
          Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.white)
        } else if warning {
          Image(systemName: "exclamationmark").font(.caption.weight(.bold)).foregroundStyle(.white)
        } else {
          Text("\(number)").font(.caption.weight(.bold)).foregroundStyle(current ? .white : .secondary)
        }
      }
      .frame(width: 22, height: 22)
      VStack(alignment: .leading, spacing: 1) {
        Text(title).fontWeight(.semibold)
        Text(detail).font(.caption).foregroundStyle(warning ? .orange : .secondary).lineLimit(1)
      }
    }
  }

  private func connector(_ done: Bool) -> some View {
    Capsule()
      .fill(done ? Color.green : Color.secondary.opacity(0.25))
      .frame(width: 28, height: 2)
  }

  // MARK: - Grid

  @ViewBuilder
  private func grid(_ library: ScreenshotLibrary?) -> some View {
    if let library, !library.shots.isEmpty {
      let current = currentLocale(library)
      let device = currentTarget(library)
      let overflowing = Set(store.reports[root]?.overflowing ?? [])
      VStack(spacing: 0) {
        HStack {
          Picker("Language", selection: Binding(get: { current }, set: { locale = $0 })) {
            ForEach(library.locales, id: \.self) { code in
              Text(Locale.current.localizedString(forIdentifier: code) ?? code).tag(code)
            }
          }
          .labelsHidden()
          .fixedSize()
          if library.targets.count > 1 {
            Picker("Device", selection: Binding(get: { device }, set: { target = $0 })) {
              ForEach(library.targets, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
          }
          Spacer()
          Picker("Show", selection: $showsFinal) {
            Text("Captured").tag(false)
            Text("Framed").tag(true)
          }
          .pickerStyle(.segmented)
          .labelsHidden()
          .fixedSize()
        }
        .padding(16)
        ScrollView {
          LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 16)], spacing: 18) {
            let shots = library.shots(in: current, on: device)
            ForEach(shots) { shot in
              Button {
                selectedScene = shot.name
                ScreenshotViewer.present(shots, selected: shot, framed: showsFinal)
              } label: {
                ScreenshotThumbnail(
                  shot: shot, preferFinal: showsFinal,
                  flag: overflowing.contains(shot.file) ? "Caption too long" : nil)
                  .padding(4)
                  .background(
                    RoundedRectangle(cornerRadius: 10)
                      .strokeBorder(selectedScene == shot.name ? Color.accentColor : .clear, lineWidth: 2))
              }
              .buttonStyle(.plain)
            }
          }
          .padding(.horizontal, 16)
          .padding(.bottom, 16)
        }
      }
    } else if let config = library?.config {
      ContentUnavailableView {
        Label("No screenshots yet", systemImage: "photo.on.rectangle")
      } description: {
        Text("Capture takes the \(config.scenes.count) scenes in .dev/screenshots.json: Dev builds the app, opens each scene from its launch arguments and saves the pictures in \(config.output).")
      } actions: {
        Button("Capture") { store.capture(root) }
          .disabled(store.phase(root) != .idle)
      }
    } else {
      ContentUnavailableView {
        Label("No screenshot scenes", systemImage: "photo.on.rectangle")
      } description: {
        Text(library?.configError
             ?? "Describe the app's screens in .dev/screenshots.json: each scene is the launch arguments that open it. Dev captures them, frames them for the App Store and uploads them.")
      } actions: {
        Button("Show Project in Finder") { NSWorkspace.shared.activateFileViewerSelecting([root]) }
      }
    }
  }

  private func currentLocale(_ library: ScreenshotLibrary) -> String {
    if let locale, library.locales.contains(locale) { return locale }
    return library.locales.first ?? ""
  }

  private func currentTarget(_ library: ScreenshotLibrary) -> String? {
    if let target, library.targets.contains(target) { return target }
    // The framed device first, so the Framed pictures are what shows.
    if library.config?.framedPlatform == .mac, library.targets.contains("Mac") { return "Mac" }
    return library.shots.first { $0.platform == library.config?.framedPlatform }?.target ?? library.targets.first
  }

  // MARK: - Inspector: the framing

  @ViewBuilder
  private func inspector(_ library: ScreenshotLibrary?) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        if let framing = store.config(root)?.framing, let author = framing.updatedBy, author.contains("MCP") {
          agentCard(framing, author: author)
        }
        if let error = store.errors[root] {
          Label(error, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.orange)
            .textSelection(.enabled)
        }
        if let config = draft {
          if config.framing != nil {
            framingEditor(library)
          } else {
            VStack(alignment: .leading, spacing: 8) {
              Text("Framing").font(.headline)
              Text("Framing puts each capture on a background under its translated caption, at an App Store size. Until it is set up, Dev frames with the defaults.")
                .font(.callout)
                .foregroundStyle(.secondary)
              Button("Set Up Framing") {
                draft?.framing = .starter(for: config.framedPlatform ?? .mac)
              }
            }
          }
        }
        checks(library)
      }
      .padding(16)
    }
    .background(.background.secondary)
  }

  private func agentCard(_ framing: ScreenshotConfig.Framing, author: String) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Image(systemName: "powerplug").foregroundStyle(Color.accentColor)
        Text("Set up by an agent").fontWeight(.semibold)
        Spacer()
        if let date = framing.updatedAt {
          Text(date, format: .relative(presentation: .named)).font(.caption).foregroundStyle(.secondary)
        }
      }
      Text("\(author) changed the framing. Review the pictures, or edit it below.")
        .font(.callout)
        .foregroundStyle(.secondary)
      Button("Show Screenshots File") {
        NSWorkspace.shared.activateFileViewerSelecting([ScreenshotConfig.url(in: root)])
      }
      .buttonStyle(.link)
    }
    .padding(12)
    .background(.background, in: RoundedRectangle(cornerRadius: 12))
    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
  }

  @ViewBuilder
  private func framingEditor(_ library: ScreenshotLibrary?) -> some View {
    let framing = Binding(
      get: { draft?.framing ?? ScreenshotConfig.Framing() }, set: { draft?.framing = $0 })
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Framing").font(.headline)
        Spacer()
        Text(".dev/screenshots.json")
          .font(.system(.caption, design: .monospaced))
          .foregroundStyle(.secondary)
      }
      LabeledContent("Size") {
        Picker("Size", selection: Binding(
          get: { [framing.wrappedValue.width, framing.wrappedValue.height] },
          set: { size in framing.wrappedValue.width = size[0]; framing.wrappedValue.height = size[1] })
        ) {
          ForEach(sizeOptions(framing.wrappedValue), id: \.self) { Text("\($0[0]) × \($0[1])").tag($0) }
        }
        .labelsHidden()
      }
      LabeledContent("Background") {
        ColorPicker("", selection: hexBinding(framing.background), supportsOpacity: false).labelsHidden()
      }
      LabeledContent("Caption size") {
        Stepper("\(Int(framing.wrappedValue.caption.fontSize)) pt", value: framing.caption.fontSize, in: 40...240, step: 5)
      }
      LabeledContent("Caption color") {
        ColorPicker("", selection: hexBinding(framing.caption.color), supportsOpacity: false).labelsHidden()
      }
      Toggle("Bold caption", isOn: framing.caption.bold)
      LabeledContent("Window") {
        HStack {
          Slider(value: framing.window.scale, in: 0.5...1)
          Text(framing.wrappedValue.window.scale, format: .percent.precision(.fractionLength(0)))
            .monospacedDigit().frame(width: 40)
        }
      }
      Picker("Window position", selection: framing.window.align) {
        Text("Bottom edge").tag(ScreenshotConfig.Framing.Align.bottom)
        Text("Floating").tag(ScreenshotConfig.Framing.Align.center)
      }
      Toggle("Window shadow", isOn: framing.window.shadow)

      Divider()
      Text("Scenes").font(.headline)
      Text("Captions are keys in \(framing.wrappedValue.caption.catalog): translate them in Localization.")
        .font(.caption)
        .foregroundStyle(.secondary)
      ForEach(Array((draft?.scenes ?? []).enumerated()), id: \.element.id) { index, scene in
        sceneEditor(index, scene, framing)
      }
      HStack {
        Button("Revert") { draft = store.config(root) }
          .disabled(draft == store.config(root))
        Spacer()
        Button("Save & Render") {
          guard let draft else { return }
          Task { await store.save(draft, in: root) }
        }
        .buttonStyle(.borderedProminent)
        .disabled(store.phase(root) != .idle || draft == nil)
      }
    }
  }

  private func sceneEditor(
    _ index: Int, _ scene: ScreenshotConfig.Scene, _ framing: Binding<ScreenshotConfig.Framing>
  ) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(scene.id).font(.callout.weight(.semibold))
        Spacer()
        ColorPicker("", selection: Binding(
          get: { Color(cgColor: ScreenshotProcessor.cgColor(framing.wrappedValue.background(of: scene.id))) },
          set: { color in framing.wrappedValue.backgrounds[scene.id] = color.hexString }), supportsOpacity: false)
          .labelsHidden()
      }
      TextField("Caption", text: Binding(
        get: { scene.caption ?? "" },
        set: { text in
          guard let draft, draft.scenes.indices.contains(index) else { return }
          self.draft?.scenes[index].caption = text.isEmpty ? nil : text
        }),
        prompt: Text("Caption"), axis: .vertical)
        .textFieldStyle(.roundedBorder)
    }
    .padding(10)
    .background(selectedScene == scene.id ? Color.accentColor.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
  }

  private func sizeOptions(_ framing: ScreenshotConfig.Framing) -> [[Int]] {
    let platform = draft?.framedPlatform ?? .mac
    var options = ScreenshotConfig.Framing.appStoreSizes[platform] ?? []
    let current = [framing.width, framing.height]
    if !options.contains(current) { options.insert(current, at: 0) }
    return options
  }

  private func hexBinding(_ hex: Binding<String>) -> Binding<Color> {
    Binding(
      get: { Color(cgColor: ScreenshotProcessor.cgColor(hex.wrappedValue)) },
      set: { color in hex.wrappedValue = color.hexString })
  }

  // MARK: - Checks

  private func checks(_ library: ScreenshotLibrary?) -> some View {
    let config = store.config(root)
    let framing = config?.framing
    let report = store.reports[root]
    var items: [(String, Color)] = []
    for problem in config?.problems() ?? [] { items.append((problem, .red)) }
    if let framing {
      if ScreenshotConfig.Framing.isAppStoreSize(width: framing.width, height: framing.height) {
        items.append(("\(framing.width) × \(framing.height) is an App Store Connect size", .green))
      }
      for problem in framing.problems() { items.append((problem, .red)) }
    }
    for scene in library?.outdated ?? [] {
      items.append(("\(scene.id): \(scene.state.reason ?? "")", .orange))
    }
    if let report {
      if report.overflowing.isEmpty {
        items.append(("Every caption fits in \(framing?.caption.maxLines ?? 2) lines", .green))
      } else {
        for item in report.overflowing { items.append(("Caption too long: \(item)", .red)) }
      }
      for error in report.errors { items.append((error, .red)) }
    }
    if let library, let platform = library.config?.framedPlatform {
      let missing = library.locales.filter { locale in
        library.shots(in: locale).contains { $0.platform == platform && $0.final == nil }
      }
      if !missing.isEmpty { items.append(("Not framed yet: \(missing.joined(separator: ", "))", .orange)) }
    }
    return VStack(alignment: .leading, spacing: 7) {
      Text("Checks").font(.headline)
      if items.isEmpty {
        Text("Capture and render to check the pictures.").font(.callout).foregroundStyle(.secondary)
      }
      ForEach(Array(items.enumerated()), id: \.offset) { _, item in
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Circle().fill(item.1).frame(width: 7, height: 7)
          Text(item.0).font(.callout)
        }
      }
    }
  }

  private var logSheet: some View {
    VStack(alignment: .leading) {
      Text("Capture Log").font(.headline)
      ScrollView {
        Text(store.logs[root, default: []].joined(separator: "\n"))
          .font(.system(.caption, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      HStack {
        Spacer()
        Button("Done") { showsLog = false }.keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(width: 680, height: 460)
  }
}

extension Color {
  /// `#RRGGBB` in sRGB.
  var hexString: String {
    guard let color = NSColor(self).usingColorSpace(.sRGB) else { return "#000000" }
    return String(format: "#%02X%02X%02X",
                  Int((color.redComponent * 255).rounded()), Int((color.greenComponent * 255).rounded()),
                  Int((color.blueComponent * 255).rounded()))
  }
}
