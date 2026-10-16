//
//  Create icon.swift
//  Dev
//
//  Created by Dmitry on 01.09.26.
//

import AppKit
import ComponentKit
import SwiftUI

struct IconSettings: Hashable {
  var symbol: String = "hammer.fill"
  /// Glyph size as a fraction of the 50% baseline (±). Range 0.5...2.0 (50%–200%).
  var scale: CGFloat = 1
  var primary: Color = Color(.displayP3, red: 0.918, green: 0.208, blue: 0.282, opacity: 1)
  var secondary: Color = .orange
  var glyph: Color = Color(white: 1)
  var gradient: Bool = false
  /// Flat palette size after ImageMagick quantization (2/4/8/16).
  var palette: Int = 2
  /// Switched between live SwiftUI view and the generated PNG.
  var preview: Bool = false
}

@Observable class CreateIcon {
  var settings: IconSettings = IconSettings()
  var result: NSImage?
  var resultSize: Int64 = 0
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
      guard create.settings.preview else { return }
      await generateImage()
    }
    .alert(alertMessage ?? "", isPresented: Binding(
      get: { alertMessage != nil },
      set: { if !$0 { alertMessage = nil } }
    )) {
      Button("OK") { alertMessage = nil }
    }
  }

  // MARK: - controls

  var controls: some View {
    @Bindable var create = create
    return VStack(alignment: .leading, spacing: 18) {
      FormCard("Symbol") {
        FormRow("SF Symbol", systemImage: "square.grid.2x2", hue: .indigo,
                field: TextField("SF Symbol", text: $create.settings.symbol))
        Menu("Suggestions") {
          ForEach(["hammer.fill", "cylinder.split.1x2", "star.fill",
                   "drop.fill", "bolt.fill", "book.fill", "hexagon.fill"], id: \.self) { s in
            Button(s) { create.settings.symbol = s }
          }
        }
        .buttonStyle(.kit)
        .fixedSize()
        .padding(12)
      }

      FormCard("Scale") {
        FormRow("Scale", help: "\(Int(create.settings.scale * 100))%",
                systemImage: "arrow.up.left.and.arrow.down.right", hue: .gray) {
          KitSlider("Scale", value: $create.settings.scale, in: 0.5...2.0, step: 0.25) { "\(Int($0 * 100))%" }
            .frame(width: 120)
        }
      }

      FormCard("Background") {
        FormRow("Gradient", systemImage: "drop.fill", hue: .pink) {
          Toggle("Gradient", isOn: $create.settings.gradient).labelsHidden().toggleStyle(.kitSwitch)
        }
        FormRow("Top", systemImage: "drop.fill", hue: .pink) {
          ColorPicker("Top", selection: $create.settings.primary).labelsHidden()
        }
        FormRow("Bottom", systemImage: "drop.fill", hue: .pink) {
          ColorPicker("Bottom", selection: $create.settings.secondary).labelsHidden()
        }
        .disabled(!create.settings.gradient)
      }

      FormCard("Glyph") {
        FormRow("Color", systemImage: "drop.fill", hue: .pink) {
          ColorPicker("Color", selection: $create.settings.glyph).labelsHidden()
        }
      }

      FormCard("Quantize") {
        FormRow("Palette", systemImage: "square.grid.2x2", hue: .purple) {
          Picker("Palette", selection: $create.settings.palette) {
            ForEach([2, 4, 8, 16], id: \.self) { n in
              Text("\(n) colors").tag(n)
            }
          }
          .pickerStyle(.menu)
          .labelsHidden()
          .fixedSize()
        }
      }

      FormCard("Preview") {
        FormRow(
          "Generated PNG",
          help: create.settings.preview && create.resultSize > 0
            ? "\(create.resultSize) bytes" : "Shows the quantized PNG instead of the live view",
          systemImage: "photo", hue: .blue
        ) {
          Toggle("Generated PNG", isOn: $create.settings.preview).labelsHidden().toggleStyle(.kitSwitch)
        }
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
          Text("Writes \(root.lastPathComponent)/Assets.xcassets/AppIcon.appiconset")
            .kitFont(.caption)
            .lineLimit(2)
            .truncationMode(.middle)
            .help(root.appendingPathComponent("Assets.xcassets").appendingPathComponent("AppIcon.appiconset").path)
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
          Group {
            if create.settings.preview, appearance == .default, let result = create.result {
              Image(nsImage: result)
                .resizable().interpolation(.high)
                .frame(width: 232, height: 232)
                .clipShape(RoundedRectangle(cornerRadius: 232 * 0.22))
            } else {
              liveIcon(appearance).frame(width: 232, height: 232)
            }
          }
          .shadow(color: .black.opacity(0.25), radius: 20, y: 10)
          .padding(.trailing, 14)
          ForEach([128, 64, 32, 16], id: \.self) { size in
            VStack(spacing: 6) {
              liveIcon(appearance).frame(width: CGFloat(size), height: CGFloat(size))
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
      liveIcon(item).frame(width: 36, height: 36)
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

  func liveIcon(_ appearance: IconAppearance) -> some View {
    GeometryReader { view in
      ZStack {
        appearanceBackground(appearance)
        Image(systemName: create.settings.symbol)
          .font(.system(size: view.size.width * 0.5 * create.settings.scale))
          .foregroundStyle(glyphStyle(appearance))
          .shadow(radius: view.size.width > 100 ? 16 : 2)
      }
      .clipShape(RoundedRectangle(cornerRadius: view.size.width * 0.225))
      .overlay(
        RoundedRectangle(cornerRadius: view.size.width * 0.225)
          .strokeBorder(appearance == .clear ? Color.white.opacity(0.6) : .clear, lineWidth: 1.5))
      .compatInteractiveGlass(in: RoundedRectangle(cornerRadius: view.size.width * 0.225))
    }
    .aspectRatio(1, contentMode: .fit)
  }

  /// The background for the appearance the preview shows: the icon's own in
  /// Default, near black in Dark, frosted in Clear, a dark tint in Tinted.
  @ViewBuilder
  func appearanceBackground(_ appearance: IconAppearance) -> some View {
    switch appearance {
    case .default: background
    case .dark: Rectangle().fill(Color(white: 0.11))
    case .clear: Rectangle().fill(.white.opacity(0.22))
    case .tinted: Rectangle().fill(Color(red: 0.12, green: 0.16, blue: 0.25))
    }
  }

  func glyphStyle(_ appearance: IconAppearance) -> Color {
    switch appearance {
    case .default: create.settings.glyph.opacity(0.8)
    case .dark: create.settings.primary
    case .clear: .white
    case .tinted: Color(red: 0.66, green: 0.76, blue: 0.95)
    }
  }

  @ViewBuilder
  var background: some View {
    if create.settings.gradient {
      Rectangle().fill(LinearGradient(
        colors: [create.settings.primary, create.settings.secondary],
        startPoint: .top, endPoint: .bottom))
    } else {
      Rectangle().fill(create.settings.primary)
    }
  }

  // MARK: - generation

  func generateImage() async {
    do {
      // Render the master, then quantize the SAME way export does so the
      // preview shows the real flat-palette output (not the smooth master).
      let icon = try IconGenerator.renderMaster(
        symbol: create.settings.symbol,
        scale: create.settings.scale,
        primary: create.settings.primary,
        secondary: create.settings.secondary,
        glyphColor: create.settings.glyph,
        gradient: create.settings.gradient)
      let files = try await IconGenerator.palettePNGs(
        of: icon, sizes: [1024], colors: create.settings.palette)
      if let data = files.first?.data {
        create.result = NSImage(data: data)
        create.resultSize = Int64(data.count)
      }
    } catch {
      create.result = nil
      create.resultSize = 0
      alertMessage = error.localizedDescription
    }
  }

  func exportIconSet() async {
    isExporting = true
    defer { isExporting = false }
    // Project-bound: the target IS the project root (no picker). Projectless:
    // prompt for an arbitrary folder, as before.
    guard let dir = exportRootURL ?? chooseDirectory() else { return }
    do {
      try await IconGenerator.exportIconSet(
        symbol: create.settings.symbol,
        scale: create.settings.scale,
        primary: create.settings.primary,
        secondary: create.settings.secondary,
        glyphColor: create.settings.glyph,
        gradient: create.settings.gradient,
        palette: create.settings.palette,
        to: dir)
      try IconGenerator.exportIconComposer(
        symbol: create.settings.symbol,
        scale: create.settings.scale,
        primary: create.settings.primary,
        glyphColor: create.settings.glyph,
        gradient: create.settings.gradient,
        to: dir)
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
