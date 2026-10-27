//
//  Create icon.swift
//  Dev
//
//  Created by Dmitry on 01.09.26.
//

import AppKit
import ComponentKit
import SwiftUI

/// An icon's flat sources: one background color and one glyph color (opacity allowed). Icon Composer adds the
/// rest: the background's top light, the glyph's glass, its shadow and specular edge.
struct IconSettings: Hashable {
  var symbol: String = "hammer.fill"
  /// Glyph size as a fraction of the 50% baseline (±). Range 0.5...2.0 (50%–200%).
  var scale: CGFloat = 1
  var background: Color = Color(.displayP3, red: 0.918, green: 0.208, blue: 0.282, opacity: 1)
  var glyph: Color = Color(white: 1)
}

@Observable class CreateIcon {
  var settings: IconSettings = IconSettings()
  /// actool's render of `rendered`, the settings it was made from.
  var render: IconGenerator.Render?
  var rendered: IconSettings?
  var isRendering = false
  var renderError: String?
}

struct CreateIconView: View {
  @Environment(CreateIcon.self) var create
  @State private var isExporting = false
  @State private var alertMessage: String?
  /// Which macOS 26 icon appearance the preview shows.
  @State private var appearance: IconAppearance = .default

  /// Non-nil binds this instance to a selected sidebar project (P40): the
  /// export target defaults to the project's root directory, so Export
  /// writes the project's own Assets.xcassets/AppIcon.appiconset without a
  /// folder picker. nil = the projectless tool (arbitrary target via
  /// NSOpenPanel, unchanged).
  var exportRootURL: URL?

  var body: some View {
    HStack(spacing: 0) {
      ScrollView {
        controls.padding(KitMetrics.gutter * 2)
      }
      .frame(width: 300)
      Divider()
      previewPane.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .kitPane()
    .task(id: create.settings) {
      // Each change waits a moment, so a slider drag renders once at its end.
      try? await Task.sleep(for: .milliseconds(350))
      guard !Task.isCancelled else { return }
      await renderIcon()
    }
    .kitNotice(
      alertMessage ?? "", isPresented: Binding(get: { alertMessage != nil }, set: { if !$0 { alertMessage = nil } }))
  }

  // MARK: - controls

  var controls: some View {
    @Bindable var create = create
    return KitLazyStack(alignment: .leading, spacing: 18) {
      FormCard("Symbol") {
        FormRow("SF Symbol", systemImage: "square.grid.2x2", hue: .indigo,
                field: TextField("SF Symbol", text: $create.settings.symbol))
        KitMenuButton("Suggestions", systemImage: "sparkles") {
          ForEach(["hammer.fill", "cylinder.split.1x2", "star.fill",
                   "drop.fill", "bolt.fill", "book.fill", "hexagon.fill"], id: \.self) { s in
            Button(s, systemImage: s) { create.settings.symbol = s }
          }
        }
        .padding(12)
      }

      FormCard("Scale") {
        FormRow("Scale", help: "\(Int(create.settings.scale * 100))%",
                systemImage: "arrow.up.left.and.arrow.down.right", hue: .gray) {
          KitSlider("Scale", value: $create.settings.scale, in: 0.5...2.0, step: 0.25) { "\(Int($0 * 100))%" }
            .frame(width: 120)
        }
      }

      FormCard("Colors") {
        FormRow("Background", help: "Icon Composer lights it from the top", systemImage: "square.fill", hue: .pink) {
          ColorPicker("Background", selection: $create.settings.background, supportsOpacity: false).labelsHidden()
        }
        FormRow("Glyph", help: "Opacity allowed; it becomes glass", systemImage: "drop.fill", hue: .pink) {
          ColorPicker("Glyph", selection: $create.settings.glyph).labelsHidden()
        }
      }

      FormCard("Icon Composer") {
        FormRow("Render", help: renderStatus, systemImage: "sparkles", hue: .blue) {
          EmptyView()
        }
        .status(create.isRendering ? .working : .idle)
      }

      VStack(alignment: .leading, spacing: 6) {
        Button {
          Task { await exportIconSet() }
        } label: {
          Label(
            exportRootURL == nil ? "Export AppIcon.appiconset…" : "Export to Project",
            systemImage: "square.and.arrow.up")
        }
        .buttonStyle(.kitPrimary)
        .status(isExporting ? .working : .idle)
        .disabled(isExporting)
        if let root = exportRootURL {
          Text("Writes \(root.lastPathComponent)/AppIcon.icon and Assets.xcassets/AppIcon.appiconset")
            .kitFont(.caption)
            .lineLimit(2)
            .truncationMode(.middle)
            .help(root.appendingPathComponent("AppIcon.icon").path)
        }
      }
      .padding(.horizontal, 12)
    }
  }

  // MARK: - preview

  var previewPane: some View {
    ScrollView {
      VStack(spacing: 24) {
        HStack(alignment: .bottom, spacing: 22) {
          icon(appearance).frame(width: 288, height: 288)
            .padding(.trailing, 14)
          ForEach([128, 64, 32, 16], id: \.self) { size in
            VStack(spacing: 6) {
              icon(appearance).frame(width: CGFloat(size), height: CGFloat(size))
              Text("\(size) pt").kitFont(.caption)
            }
          }
        }
        .padding(.top, 36)
        .frame(maxWidth: .infinity)
        appearances
      }
      .padding(KitMetrics.gutter * 3)
    }
  }

  /// The four appearances as the kit's tall choice cards, each showing the icon in its Dock; the one the big
  /// preview shows is picked.
  private var appearances: some View {
    LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
      ForEach(IconAppearance.allCases) { item in
        ChoiceCard(isOn: $appearance.picks(item)) {
          HStack(spacing: 8) {
            Tile(systemImage: item.systemImage, hue: item == appearance ? .accent : .gray, size: 18, style: .solid)
            VStack(alignment: .leading, spacing: 0) {
              Text(item.title).kitFont(.headline)
              Text(item.subtitle).kitFont(.caption)
            }
            Spacer(minLength: 0)
          }
          .padding(.horizontal, 2)
          dockScene(item)
        }
      }
    }
    .kitChoiceCardStyle(.tall)
    .frame(maxWidth: 680)
  }

  /// The icon among others in a Dock, on the ground the appearance stands on.
  private func dockScene(_ item: IconAppearance) -> some View {
    HStack(spacing: 8) {
      ForEach([Color.blue, Color.white], id: \.self) { color in
        RoundedRectangle(cornerRadius: 8).fill(color).frame(width: 36, height: 36)
      }
      icon(item).frame(width: 44, height: 44)
      ForEach([Color.mint, Color.orange], id: \.self) { color in
        RoundedRectangle(cornerRadius: 8).fill(color).frame(width: 36, height: 36)
      }
    }
    .padding(6)
    .background(item.dock, in: RoundedRectangle(cornerRadius: 14))
    .padding(.bottom, 10)
    .frame(maxWidth: .infinity, minHeight: 128, alignment: .bottom)
    .background(item.stage, in: RoundedRectangle(cornerRadius: KitMetrics.radius, style: .continuous))
    .accessibilityLabel("\(item.title) Dock preview")
  }

  /// The icon as macOS shows it at this size, margin included: Icon Composer's render in Default once it matches
  /// the settings, the live approximation otherwise and in the other appearances (the system draws those itself).
  @ViewBuilder
  func icon(_ appearance: IconAppearance) -> some View {
    if appearance == .default, create.rendered == create.settings, let image = create.render?.image {
      Image(nsImage: image).resizable().interpolation(.high).aspectRatio(1, contentMode: .fit)
    } else {
      liveIcon(appearance)
    }
  }

  /// An approximation of Icon Composer's look, drawn at once while the render runs: the background lit from the
  /// top, the glyph's glass fading downward with a soft shadow, on the macOS icon grid (824 of 1024 points).
  func liveIcon(_ appearance: IconAppearance) -> some View {
    GeometryReader { view in
      let side = view.size.width * 824 / 1024
      let shape = RoundedRectangle(cornerRadius: side * 0.225, style: .continuous)
      ZStack {
        appearanceBackground(appearance)
        Image(systemName: create.settings.symbol)
          .font(.system(size: side * 1024 / 824 * 0.5 * create.settings.scale))
          .foregroundStyle(glyphStyle(appearance))
          .shadow(color: .black.opacity(0.2), radius: side * 0.02, y: side * 0.015)
      }
      .frame(width: side, height: side)
      .clipShape(shape)
      .overlay(shape.strokeBorder(.white.opacity(appearance == .clear ? 0.6 : 0.18), lineWidth: max(0.5, side / 160)))
      .compatInteractiveGlass(in: shape)
      .shadow(color: .black.opacity(0.2), radius: side * 0.03, y: side * 0.02)
      .frame(width: view.size.width, height: view.size.height)
    }
    .aspectRatio(1, contentMode: .fit)
  }

  /// The background for the appearance the preview shows: the icon's own, lit from the top, in Default; near
  /// black in Dark, frosted in Clear, a dark tint in Tinted.
  @ViewBuilder
  func appearanceBackground(_ appearance: IconAppearance) -> some View {
    switch appearance {
    case .default:
      let color = create.settings.background
      Rectangle().fill(LinearGradient(
        colors: [color.mix(with: .white, by: 0.22), color], startPoint: .top, endPoint: .center))
    case .dark: Rectangle().fill(Color(white: 0.11))
    case .clear: Rectangle().fill(.white.opacity(0.22))
    case .tinted: Rectangle().fill(Color(red: 0.12, green: 0.16, blue: 0.25))
    }
  }

  func glyphStyle(_ appearance: IconAppearance) -> LinearGradient {
    let glyph = create.settings.glyph
    let colors: [Color] =
      switch appearance {
      case .default: [glyph, glyph.mix(with: create.settings.background, by: 0.3)]
      case .dark: [create.settings.background, create.settings.background.opacity(0.7)]
      case .clear: [.white, .white.opacity(0.7)]
      case .tinted: [Color(red: 0.66, green: 0.76, blue: 0.95), Color(red: 0.66, green: 0.76, blue: 0.95).opacity(0.7)]
      }
    return LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
  }

  private var renderStatus: String {
    if let error = create.renderError { return error }
    if create.isRendering { return "Rendering with actool…" }
    guard let render = create.render else { return "actool renders the icon as Icon Composer draws it" }
    let size = ByteCountFormatter.string(fromByteCount: Int64(render.catalogBytes), countStyle: .file)
    return "Assets.car \(size); release archives store it as HEVC"
  }

  // MARK: - generation

  func renderIcon() async {
    let settings = create.settings
    create.isRendering = true
    defer { create.isRendering = false }
    do {
      let render = try await IconGenerator.render(
        symbol: settings.symbol, scale: settings.scale,
        background: IconColor(settings.background), glyph: IconColor(settings.glyph))
      guard !Task.isCancelled else { return }
      create.render = render
      create.rendered = settings
      create.renderError = nil
    } catch {
      guard !Task.isCancelled else { return }
      create.renderError = "\(error)"
    }
  }

  func exportIconSet() async {
    isExporting = true
    defer { isExporting = false }
    // Project-bound: the target IS the project root (no picker). Projectless:
    // prompt for an arbitrary folder, as before.
    guard let dir = exportRootURL ?? chooseDirectory() else { return }
    do {
      try await IconGenerator.export(
        symbol: create.settings.symbol, scale: create.settings.scale,
        background: IconColor(create.settings.background), glyph: IconColor(create.settings.glyph), to: dir)
      alertMessage = "Exported \(dir.path)/Assets.xcassets/AppIcon.appiconset and \(dir.path)/AppIcon.icon"
    } catch {
      alertMessage = error.localizedDescription
    }
  }

  private func chooseDirectory() -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.message = "Choose a folder to write Assets.xcassets into"
    return panel.runModal() == .OK ? panel.url : nil
  }
}

#Preview {
  CreateIconView().environment(CreateIcon())
    .frame(maxWidth: .infinity, maxHeight: .infinity)
}

/// The appearances macOS 26 draws an app icon in, for the preview.
enum IconAppearance: String, CaseIterable, Identifiable {
  case `default`, dark, clear, tinted

  var id: String { rawValue }

  var title: String {
    switch self {
    case .default: "Default"
    case .dark: "Dark"
    case .clear: "Clear"
    case .tinted: "Tinted"
    }
  }

  /// The line under the title on its card.
  var subtitle: String {
    switch self {
    case .default: "Light Dock"
    case .dark: "Dark Dock"
    case .clear: "Glass on a photo"
    case .tinted: "Monochrome"
    }
  }

  var systemImage: String {
    switch self {
    case .default: "sun.max"
    case .dark: "moon"
    case .clear: "eye"
    case .tinted: "circle.lefthalf.filled"
    }
  }

  /// The ground behind the Dock: a desktop in that appearance.
  var stage: LinearGradient {
    let colors: [Color] =
      switch self {
      case .default: [Color(red: 0.82, green: 0.87, blue: 0.95), Color(red: 0.95, green: 0.9, blue: 0.85)]
      case .dark: [Color(red: 0.13, green: 0.15, blue: 0.27), Color(red: 0.25, green: 0.18, blue: 0.3)]
      case .clear: [Color(red: 0.4, green: 0.52, blue: 0.78), Color(red: 0.78, green: 0.55, blue: 0.72)]
      case .tinted: [Color(white: 0.2), Color(white: 0.3)]
      }
    return LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
  }

  /// The Dock's own glass in that appearance.
  var dock: Color {
    switch self {
    case .default: .white.opacity(0.7)
    case .clear: .white.opacity(0.3)
    case .dark, .tinted: .black.opacity(0.45)
    }
  }
}
