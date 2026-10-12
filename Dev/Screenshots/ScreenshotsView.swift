//
//  ScreenshotsView.swift
//  Dev
//

import AppKit
import SwiftUI

/// The Screenshots tab: capture (the project's screenshot UI test, through
/// release.sh), post-process (the recipe in `.dev/screenshots.json`), review
/// and upload. The recipe is edited on the right; an agent can edit the same
/// file over MCP, and the card at the top says when one did.
struct ScreenshotsView: View {
  let root: URL
  let projectName: String

  @Environment(ScreenshotsStore.self) private var store
  @State private var locale: String?
  @State private var showsFinal = true
  @State private var draft: ScreenshotRecipe?
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
            .help("Run the screenshot UI test for every locale, then post-process")
            .disabled(store.phase(root) != .idle)
        }
        Button { uploading = true } label: { Label("Upload…", systemImage: "icloud.and.arrow.up") }
          .help("Upload the final screenshots to App Store Connect")
          .disabled(library?.shots.contains { $0.final != nil } != true)
      }
    }
    .task(id: root) {
      await store.refresh(root)
      draft = store.recipe(root)
    }
    .onChange(of: store.recipe(root)) { _, recipe in
      // A recipe written elsewhere (an agent, a render) replaces the draft.
      draft = recipe
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
    let changed = library?.shots.filter(\.changed).count ?? 0
    return HStack(spacing: 10) {
      stage(1, "Capture", phase == .capturing ? "Running the UI test…" :
              (library?.capturedAt.map { "Captured \($0.formatted(.relative(presentation: .named)))" } ?? "Not captured yet"),
            done: captured && phase != .capturing, current: phase == .capturing || !captured)
      connector(captured)
      stage(2, "Post-Process", phase == .processing ? "Applying the recipe…" :
              (store.reports[root].map { "\($0.rendered) pictures" } ?? "Recipe not applied"),
            done: processed && phase != .processing, current: phase == .processing)
      connector(processed)
      stage(3, "Review", changed > 0 ? "\(changed) changed since the last version" : "Nothing changed",
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

  private func stage(_ number: Int, _ title: String, _ detail: String, done: Bool, current: Bool) -> some View {
    HStack(spacing: 8) {
      ZStack {
        Circle().fill(done ? Color.green : (current ? Color.accentColor : Color.clear))
        if !done && !current { Circle().strokeBorder(.tertiary, lineWidth: 1.5) }
        if done {
          Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.white)
        } else {
          Text("\(number)").font(.caption.weight(.bold)).foregroundStyle(current ? .white : .secondary)
        }
      }
      .frame(width: 22, height: 22)
      VStack(alignment: .leading, spacing: 1) {
        Text(title).fontWeight(.semibold)
        Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
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
          Spacer()
          Picker("Show", selection: $showsFinal) {
            Text("Captured").tag(false)
            Text("Final").tag(true)
          }
          .pickerStyle(.segmented)
          .labelsHidden()
          .fixedSize()
        }
        .padding(16)
        ScrollView {
          LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 16)], spacing: 18) {
            ForEach(library.shots(in: current)) { shot in
              Button {
                selectedScene = shot.name
              } label: {
                ScreenshotThumbnail(
                  shot: shot, preferFinal: showsFinal,
                  flag: overflowing.contains("\(shot.locale)/\(shot.name)") ? "Caption too long" : nil)
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
    } else {
      ContentUnavailableView {
        Label("No screenshots yet", systemImage: "photo.on.rectangle")
      } description: {
        Text(ReleaseConfig.load(from: root)?["SCREENSHOT_TEST"].isEmpty == false
             ? "Capture runs the project's screenshot UI test for every locale in release.env."
             : "Set SCREENSHOT_TEST in the project's release.env (Workflows ▸ Release Settings…) to the UI test that takes the pictures, then capture.")
      } actions: {
        Button("Capture") { store.capture(root) }
          .disabled(store.phase(root) != .idle)
      }
    }
  }

  private func currentLocale(_ library: ScreenshotLibrary) -> String {
    if let locale, library.locales.contains(locale) { return locale }
    return library.locales.first ?? ""
  }

  // MARK: - Inspector: the recipe

  @ViewBuilder
  private func inspector(_ library: ScreenshotLibrary?) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        if let recipe = store.recipe(root), let author = recipe.updatedBy, author.contains("MCP") {
          agentCard(recipe, author: author)
        }
        if let error = store.errors[root] {
          Label(error, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.orange)
            .textSelection(.enabled)
        }
        if draft != nil {
          recipeEditor(library)
        } else {
          VStack(alignment: .leading, spacing: 8) {
            Text("Post-Processing Recipe").font(.headline)
            Text("A recipe puts each capture on a background with a translated caption, at an App Store size. Dev writes a starter one the first time it processes.")
              .font(.callout)
              .foregroundStyle(.secondary)
            Button("Create Recipe") {
              let names = Array(Set(library?.shots.map(\.name) ?? [])).sorted()
              draft = ScreenshotRecipe.starter(for: names, platform: ReleaseConfig.load(from: root)?["PLATFORM"] ?? "macos")
            }
          }
        }
        checks(library)
      }
      .padding(16)
    }
    .background(.background.secondary)
  }

  private func agentCard(_ recipe: ScreenshotRecipe, author: String) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Image(systemName: "powerplug").foregroundStyle(Color.accentColor)
        Text("Set up by an agent").fontWeight(.semibold)
        Spacer()
        if let date = recipe.updatedAt {
          Text(date, format: .relative(presentation: .named)).font(.caption).foregroundStyle(.secondary)
        }
      }
      Text("\(author) changed the recipe. Review the pictures, or edit the recipe below.")
        .font(.callout)
        .foregroundStyle(.secondary)
      Button("Show Recipe File") {
        NSWorkspace.shared.activateFileViewerSelecting([ScreenshotRecipe.url(in: root)])
      }
      .buttonStyle(.link)
    }
    .padding(12)
    .background(.background, in: RoundedRectangle(cornerRadius: 12))
    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
  }

  @ViewBuilder
  private func recipeEditor(_ library: ScreenshotLibrary?) -> some View {
    let binding = Binding(get: { draft ?? ScreenshotRecipe() }, set: { draft = $0 })
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Post-Processing Recipe").font(.headline)
        Spacer()
        Text(".dev/screenshots.json")
          .font(.system(.caption, design: .monospaced))
          .foregroundStyle(.secondary)
      }
      LabeledContent("Size") {
        Picker("Size", selection: Binding(
          get: { "\(binding.wrappedValue.width)x\(binding.wrappedValue.height)" },
          set: { value in
            let parts = value.split(separator: "x").compactMap { Int($0) }
            if parts.count == 2 { draft?.width = parts[0]; draft?.height = parts[1] }
          })
        ) {
          ForEach(sizeOptions(binding.wrappedValue), id: \.self) { Text($0.replacingOccurrences(of: "x", with: " × ")).tag($0) }
        }
        .labelsHidden()
      }
      LabeledContent("Background") {
        ColorPicker("", selection: hexBinding(binding, \.background), supportsOpacity: false).labelsHidden()
      }
      LabeledContent("Caption size") {
        Stepper("\(Int(binding.wrappedValue.caption.fontSize)) pt", value: binding.caption.fontSize, in: 40...240, step: 5)
      }
      LabeledContent("Caption color") {
        ColorPicker("", selection: hexBinding(binding, \.caption.color), supportsOpacity: false).labelsHidden()
      }
      Toggle("Bold caption", isOn: binding.caption.bold)
      LabeledContent("Window") {
        HStack {
          Slider(value: binding.window.scale, in: 0.5...1)
          Text(binding.wrappedValue.window.scale, format: .percent.precision(.fractionLength(0)))
            .monospacedDigit().frame(width: 40)
        }
      }
      Picker("Window position", selection: binding.window.align) {
        Text("Bottom edge").tag("bottom")
        Text("Floating").tag("center")
      }
      Toggle("Window shadow", isOn: binding.window.shadow)

      Divider()
      Text("Scenes").font(.headline)
      Text("Captions are keys in \(binding.wrappedValue.caption.catalog): translate them in Localization.")
        .font(.caption)
        .foregroundStyle(.secondary)
      ForEach(sceneNames(library, binding.wrappedValue), id: \.self) { name in
        sceneEditor(name, binding)
      }
      HStack {
        Button("Revert") { draft = store.recipe(root) }
          .disabled(draft == store.recipe(root))
        Spacer()
        Button("Save & Render") {
          guard let recipe = draft else { return }
          Task {
            let keys = recipe.scenes.compactMap(\.caption).filter { !$0.isEmpty }
            try? CaptionCatalog.addMissingKeys(keys, to: root.appendingPathComponent(recipe.caption.catalog))
            await store.save(recipe, in: root)
          }
        }
        .buttonStyle(.borderedProminent)
        .disabled(store.phase(root) != .idle || draft == nil)
      }
    }
  }

  private func sceneEditor(_ name: String, _ binding: Binding<ScreenshotRecipe>) -> some View {
    let index = binding.wrappedValue.scenes.firstIndex { $0.match == name }
    let scene = index.map { binding.wrappedValue.scenes[$0] } ?? ScreenshotRecipe.Scene(match: name)
    let update: ((inout ScreenshotRecipe.Scene) -> Void) -> Void = { change in
      var edited = scene
      change(&edited)
      if let index { draft?.scenes[index] = edited } else { draft?.scenes.append(edited) }
    }
    return VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(name).font(.callout.weight(.semibold))
        Spacer()
        ColorPicker("", selection: Binding(
          get: { Color(cgColor: ScreenshotProcessor.cgColor(scene.background ?? binding.wrappedValue.background)) },
          set: { color in update { $0.background = color.hexString } }), supportsOpacity: false)
          .labelsHidden()
      }
      TextField("Caption", text: Binding(
        get: { scene.caption ?? "" }, set: { text in update { $0.caption = text.isEmpty ? nil : text } }),
        prompt: Text("Caption"), axis: .vertical)
        .textFieldStyle(.roundedBorder)
    }
    .padding(10)
    .background(selectedScene == name ? Color.accentColor.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
  }

  private func sceneNames(_ library: ScreenshotLibrary?, _ recipe: ScreenshotRecipe) -> [String] {
    var names = recipe.scenes.map(\.match)
    for name in Set(library?.shots.map(\.name) ?? []).sorted() where !names.contains(where: { name.hasPrefix($0) }) {
      names.append(name)
    }
    return names
  }

  private func sizeOptions(_ recipe: ScreenshotRecipe) -> [String] {
    let platform = ReleaseConfig.load(from: root)?["PLATFORM"] ?? "macos"
    let sizes = platform == "ios" ? ScreenshotRecipe.iPhoneSizes + ScreenshotRecipe.iPadSizes : ScreenshotRecipe.macSizes
    var options = sizes.map { "\($0.0)x\($0.1)" }
    let current = "\(recipe.width)x\(recipe.height)"
    if !options.contains(current) { options.insert(current, at: 0) }
    return options
  }

  private func hexBinding(_ recipe: Binding<ScreenshotRecipe>, _ path: WritableKeyPath<ScreenshotRecipe, String>) -> Binding<Color> {
    Binding(
      get: { Color(cgColor: ScreenshotProcessor.cgColor(recipe.wrappedValue[keyPath: path])) },
      set: { color in draft?[keyPath: path] = color.hexString })
  }

  // MARK: - Checks

  private func checks(_ library: ScreenshotLibrary?) -> some View {
    let recipe = store.recipe(root)
    let report = store.reports[root]
    var items: [(String, Color)] = []
    if let recipe {
      items.append(ScreenshotRecipe.isAppStoreSize(width: recipe.width, height: recipe.height)
        ? ("\(recipe.width) × \(recipe.height) is an App Store Connect size", .green)
        : ("\(recipe.width) × \(recipe.height) is not an App Store Connect size", .red))
    }
    if let report {
      if report.overflowing.isEmpty {
        items.append(("Every caption fits in \(recipe?.caption.maxLines ?? 2) lines", .green))
      } else {
        for item in report.overflowing { items.append(("Caption too long: \(item)", .red)) }
      }
      for error in report.errors { items.append((error, .red)) }
    }
    if let library {
      let missing = library.locales.filter { locale in library.shots(in: locale).contains { $0.final == nil } }
      if !missing.isEmpty { items.append(("Not rendered yet: \(missing.joined(separator: ", "))", .orange)) }
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
