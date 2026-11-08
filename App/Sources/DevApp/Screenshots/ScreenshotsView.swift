//
//  ScreenshotsView.swift
//  Dev
//

import Foundation
import DevScreenshots
import DevScreenshotsCapture
import ComponentKit
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
            .kitHelp("Capture", meta: "Take the scenes in .dev/screenshots.json, then frame them", systemImage: "camera")
            .disabled(store.phase(root) != .idle || library?.config == nil)
        }
        Button { uploading = true } label: { Label("Upload…", systemImage: "icloud.and.arrow.up") }
          .kitHelp("Upload", meta: "Upload the framed screenshots to App Store Connect", systemImage: "icloud.and.arrow.up")
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
    .kitSheet(isPresented: $showsLog) { logSheet }
    .kitSheet(isPresented: $uploading) {
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
      stage(1, String(localized: "Capture"), phase == .capturing
              ? (store.paused.contains(root) ? String(localized: "Paused: switch back to the app") : String(localized: "Taking the scenes…"))
              : captureDetail(library),
            done: captured && phase != .capturing && outdated == 0, current: phase == .capturing || !captured,
            warning: captured && phase != .capturing && outdated > 0)
      connector(captured)
      stage(2, String(localized: "Frame"), phase == .processing ? String(localized: "Framing…") :
              (store.reports[root].map { String(localized: "\($0.rendered) pictures") } ?? String(localized: "Not framed yet")),
            done: processed && phase != .processing, current: phase == .processing)
      connector(processed)
      stage(3, String(localized: "Review"), library?.status?.summary ?? String(localized: "Nothing to review"),
            done: false, current: processed && phase == .idle)
      connector(false)
      stage(4, String(localized: "Upload"), "App Store Connect", done: false, current: false)
      Spacer()
      if !store.logs[root, default: []].isEmpty {
        Button("Show Log") { showsLog = true }.buttonStyle(.kitPlain)
      }
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 10)
    .kitPane(.secondary)
  }

  private func captureDetail(_ library: ScreenshotLibrary?) -> String {
    guard let library, let date = library.capturedAt else { return String(localized: "Not captured yet") }
    let when = String(localized: "Captured \(date.formatted(.relative(presentation: .named)))")
    let outdated = library.outdated.count
    return outdated == 0 ? when : String(localized: "\(outdated) of \(library.status?.scenes.count ?? 0) scenes outdated")
  }

  private func stage(
    _ number: Int, _ title: String, _ detail: String, done: Bool, current: Bool, warning: Bool = false
  ) -> some View {
    HStack(spacing: 8) {
      ZStack {
        Circle().fill(done ? Hue.green.fill : (warning ? Hue.orange.fill : (current ? Hue.accent.fill : Hue.gray.soft(0))))
        if !done && !current && !warning { Circle().strokeBorder(.kitTertiary, lineWidth: 1.5) }
        if done {
          Image(systemName: "checkmark").kitFont(.caption).fontWeight(.bold).foregroundStyle(.white)
        } else if warning {
          Image(systemName: "exclamationmark").kitFont(.caption).fontWeight(.bold).foregroundStyle(.white)
        } else {
          Text("\(number)").kitFont(.caption).fontWeight(.bold).foregroundStyle(current ? .white : .secondary)
        }
      }
      .frame(width: 22, height: 22)
      VStack(alignment: .leading, spacing: 1) {
        Text(title).fontWeight(.semibold)
        Text(detail).kitFont(.caption).foregroundStyle(warning ? .orange : .secondary).lineLimit(1)
      }
    }
  }

  private func connector(_ done: Bool) -> some View {
    Capsule()
      .fill(done ? Hue.green.fill : Hue.gray.soft(0.25))
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
          KitPicker(
            "Language", selection: Binding(get: { current }, set: { locale = $0 }),
            segments: library.locales.map { KitSegment(ProjectOverviewView.languageName($0), value: $0, systemImage: "globe") })
          if library.targets.count > 1 {
            KitPicker(
              "Device", selection: Binding(get: { device }, set: { target = $0 }),
              options: library.targets.map { ("\($0)", $0) })
          }
          Spacer()
          KitSegmented(selection: $showsFinal, options: [("Captured", false), ("Framed", true)])
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
                  flag: overflowing.contains(shot.file) ? String(localized: "Caption too long") : nil)
                  .padding(4)
                  .background(
                    RoundedRectangle(cornerRadius: KitMetrics.radiusLarge)
                      .strokeBorder(selectedScene == shot.name ? Hue.accent.fill : Hue.accent.soft(0), lineWidth: 2))
              }
              .buttonStyle(.kitHoverEffect)
            }
          }
          .padding(.horizontal, 16)
          .padding(.bottom, 16)
        }
      }
    } else if let config = library?.config {
      EmptyState(
        systemImage: "photo.on.rectangle", title: "No Screenshots Yet",
        message: "Capture takes the \(config.scenes.count) scenes in .dev/screenshots.json: Dev builds the app, opens each scene from its launch arguments and saves the pictures in \(config.output)."
      ) {
        Button("Capture") { store.capture(root) }
          .buttonStyle(.kitPrimary)
          .disabled(store.phase(root) != .idle)
      }
    } else {
      EmptyState(
        systemImage: "photo.on.rectangle", title: String(localized: "No Screenshot Scenes"),
        message: library?.configError.map { "\($0)" }
          ?? String(localized: "Describe the app's screens in .dev/screenshots.json: each scene is the launch arguments that open it. Dev captures them, frames them for the App Store and uploads them.")
      ) {
        Button("Show Project in \(KitDesktop.fileManagerName)") { KitDesktop.reveal([root]) }
          .buttonStyle(.kit)
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
            .kitFont(.callout)
            .foregroundStyle(Hue.orange.text)
            .textSelection(.enabled)
        }
        if let config = draft {
          if config.framing != nil {
            framingEditor(library)
          } else {
            VStack(alignment: .leading, spacing: 8) {
              Text("Framing").kitFont(.headline)
              Text("Framing puts each capture on a background under its translated caption, at an App Store size. Until it is set up, Dev frames with the defaults.")
                .kitFont(.callout)
                .foregroundStyle(.kitSecondary)
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
    .kitPane(.secondary)
  }

  private func agentCard(_ framing: ScreenshotConfig.Framing, author: String) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Image(systemName: "powerplug").foregroundStyle(Hue.accent.text)
        Text("Set up by an agent").fontWeight(.semibold)
        Spacer()
        if let date = framing.updatedAt {
          Text(date, format: .relative(presentation: .named)).kitFont(.caption).foregroundStyle(.kitSecondary)
        }
      }
      Text("\(author) changed the framing. Review the pictures, or edit it below.")
        .kitFont(.callout)
        .foregroundStyle(.kitSecondary)
      Button("Show Screenshots File") {
        KitDesktop.reveal([ScreenshotConfig.url(in: root)])
      }
      .buttonStyle(.kitPlain)
    }
    .padding(12)
    .kitSurface(.card)
  }

  @ViewBuilder
  private func framingEditor(_ library: ScreenshotLibrary?) -> some View {
    let framing = Binding(
      get: { draft?.framing ?? ScreenshotConfig.Framing() }, set: { draft?.framing = $0 })
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Framing").kitFont(.headline)
        Spacer()
        Text(".dev/screenshots.json")
          .kitFont(.monoSmall)
          .foregroundStyle(.kitSecondary)
      }
      LabeledContent("Size") {
        KitPicker(
          "Size",
          selection: Binding(
            get: { [framing.wrappedValue.width, framing.wrappedValue.height] },
            set: { size in framing.wrappedValue.width = size[0]; framing.wrappedValue.height = size[1] }),
          options: sizeOptions(framing.wrappedValue).map { ("\($0[0]) × \($0[1])", $0) })
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
      Toggle("Bold caption", isOn: framing.caption.bold).toggleStyle(.kitSwitch)
      LabeledContent("Window") {
        HStack {
          Slider(value: framing.window.scale, in: 0.5...1)
          Text(framing.wrappedValue.window.scale, format: .percent.precision(.fractionLength(0)))
            .monospacedDigit().frame(width: 40)
        }
      }
      LabeledContent("Window position") {
        KitSegmented(
          selection: framing.window.align,
          options: [("Bottom edge", ScreenshotConfig.Framing.Align.bottom), ("Floating", .center)])
      }
      Toggle("Window shadow", isOn: framing.window.shadow).toggleStyle(.kitSwitch)

      Divider()
      Text("Scenes").kitFont(.headline)
      Text("Captions are keys in \(framing.wrappedValue.caption.catalog): translate them in Localization.")
        .kitFont(.caption)
        .foregroundStyle(.kitSecondary)
      ForEach(Array((draft?.scenes ?? []).enumerated()), id: \.element.id) { index, scene in
        sceneEditor(index, scene, framing)
      }
      HStack {
        Button("Revert") { draft = store.config(root) }
          .buttonStyle(.kit)
          .disabled(draft == store.config(root))
        Spacer()
        Button("Save & Render") {
          guard let draft else { return }
          Task { await store.save(draft, in: root) }
        }
        .buttonStyle(.kitPrimary)
        .disabled(store.phase(root) != .idle || draft == nil)
      }
    }
  }

  private func sceneEditor(
    _ index: Int, _ scene: ScreenshotConfig.Scene, _ framing: Binding<ScreenshotConfig.Framing>
  ) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(scene.id).kitFont(.callout).fontWeight(.semibold)
        Spacer()
        ColorPicker("", selection: Binding(
          get: { Color(hex: framing.wrappedValue.background(of: scene.id)) ?? .black },
          set: { color in framing.wrappedValue.backgrounds[scene.id] = color.hex() }), supportsOpacity: false)
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
    .background(Hue.accent.soft(selectedScene == scene.id ? 0.08 : 0), in: RoundedRectangle(cornerRadius: KitMetrics.radiusLarge))
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
      get: { Color(hex: hex.wrappedValue) ?? .black },
      set: { color in hex.wrappedValue = color.hex() })
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
        items.append((String(localized: "\(framing.width) × \(framing.height) is an App Store Connect size"), .green))
      }
      for problem in framing.problems() { items.append((problem, .red)) }
    }
    for scene in library?.outdated ?? [] {
      items.append(("\(scene.id): \(scene.state.reason ?? "")", .orange))
    }
    if let report {
      if report.overflowing.isEmpty {
        items.append((String(localized: "Every caption fits in \(framing?.caption.maxLines ?? 2) lines"), .green))
      } else {
        for item in report.overflowing { items.append((String(localized: "Caption too long: \(item)"), .red)) }
      }
      for error in report.errors { items.append((error, .red)) }
    }
    if let library, let platform = library.config?.framedPlatform {
      let missing = library.locales.filter { locale in
        library.shots(in: locale).contains { $0.platform == platform && $0.final == nil }
      }
      if !missing.isEmpty { items.append((String(localized: "Not framed yet: \(missing.joined(separator: ", "))"), .orange)) }
    }
    return VStack(alignment: .leading, spacing: 7) {
      Text("Checks").kitFont(.headline)
      if items.isEmpty {
        Text("Capture and render to check the pictures.").kitFont(.callout).foregroundStyle(.kitSecondary)
      }
      ForEach(Array(items.enumerated()), id: \.offset) { _, item in
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Circle().fill(item.1).frame(width: 7, height: 7)
          Text(item.0).kitFont(.callout)
        }
      }
    }
  }

  private var logSheet: some View {
    KitSheet(title: "Capture Log", systemImage: "camera", width: 680) {
      KitCodeBlock(lines: store.logs[root, default: []], maxHeight: .infinity, followsEnd: true, font: .monoSmall)
        .frame(height: 360)
    } footer: {
      Spacer()
      Button("Done") { showsLog = false }.buttonStyle(.kitPrimary).keyboardShortcut(.defaultAction)
    }
  }
}
