//
//  Create icon.swift
//  Dev
//
//  Created by Dmitry on 01.09.26.
//

import AppKit
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

  /// Non-nil binds this instance to a selected sidebar project (P40): the
  /// export target defaults to the project's root directory, so Export
  /// writes the project's own Assets.xcassets/AppIcon.appiconset without a
  /// folder picker. nil = the projectless tool (arbitrary target via
  /// NSOpenPanel, unchanged).
  var exportRootURL: URL?

  var body: some View {
    @Bindable var create = create
    HStack(spacing: 0) {
      controls.padding(20).frame(width: 300, alignment: .leading)
      Divider()
      previewPane.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
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
    return Form {
      Section("Symbol") {
        TextField("SF Symbol", text: $create.settings.symbol)
        Menu("Suggestions") {
          ForEach(["hammer.fill", "cylinder.split.1x2", "star.fill",
                   "drop.fill", "bolt.fill", "book.fill", "hexagon.fill"], id: \.self) { s in
            Button(s) { create.settings.symbol = s }
          }
        }
      }

      Section("Scale") {
        Slider(value: $create.settings.scale, in: 0.5...2.0, step: 0.25) {
          Text("Scale")
        } minimumValueLabel: {
          Text("50%")
        } maximumValueLabel: {
          Text("200%")
        }
        Text("\(Int(create.settings.scale * 100))%")
      }

      Section("Background") {
        Toggle("Gradient", isOn: $create.settings.gradient)
        ColorPicker("Top", selection: $create.settings.primary)
        ColorPicker("Bottom", selection: $create.settings.secondary)
          .disabled(!create.settings.gradient)
      }

      Section("Glyph") {
        ColorPicker("Color", selection: $create.settings.glyph)
      }

      Section("Quantize") {
        Picker("Palette", selection: $create.settings.palette) {
          ForEach([2, 4, 8, 16], id: \.self) { n in
            Text("\(n) colors").tag(n)
          }
        }
        .pickerStyle(.menu)
      }

      Section("Preview") {
        Toggle("Generated PNG", isOn: $create.settings.preview)
        if create.settings.preview && create.resultSize > 0 {
          Text("\(create.resultSize) bytes").font(.caption).foregroundStyle(.secondary)
        }
      }

      Section {
        Button {
          Task { await exportIconSet() }
        } label: {
          if isExporting {
            ProgressView().controlSize(.small)
          } else {
            Text(exportRootURL == nil ? "Export AppIcon.appiconset…" : "Export to Project")
          }
        }
        .disabled(isExporting)
        if let root = exportRootURL {
          Text("Writes \(root.lastPathComponent)/Assets.xcassets/AppIcon.appiconset")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .truncationMode(.middle)
            .help(root.appendingPathComponent("Assets.xcassets").appendingPathComponent("AppIcon.appiconset").path)
        }
      }
    }
    .formStyle(.grouped)
  }

  // MARK: - preview

  var previewPane: some View {
    GeometryReader { view in
      let side = min(view.size.width, view.size.height) * 0.8
      VStack(spacing: 12) {
        Spacer()
        if create.settings.preview, let result = create.result {
          Image(nsImage: result)
            .resizable().interpolation(.high)
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: side * 0.22))
        } else {
          liveIcon.frame(width: side, height: side)
        }
        HStack {
          liveIcon.frame(width: 80, height: 80)
          liveIcon.frame(width: 64, height: 64)
          liveIcon.frame(width: 48, height: 48)
        }
        Text(create.settings.preview ? "Rendered PNG" : "Live preview")
          .font(.caption).foregroundStyle(.secondary)
        Spacer()
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  var liveIcon: some View {
    GeometryReader { view in
      background.overlay {
        Image(systemName: create.settings.symbol)
          .font(.system(size: view.size.width * 0.5 * create.settings.scale))
          .foregroundStyle(create.settings.glyph.opacity(0.8))
          .shadow(radius: 16)
      }
      .clipShape(RoundedRectangle(cornerRadius: view.size.width * 0.25))
      .compatInteractiveGlass(in: RoundedRectangle(cornerRadius: view.size.width * 0.25))
    }
    .aspectRatio(1, contentMode: .fit)
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
      let raw = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("dev-raw-\(UUID().uuidString).png")
      try IconGenerator.writePng(icon, size: 1024, to: raw)
      defer { try? FileManager.default.removeItem(at: raw) }

      let quant = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("dev-quant-\(UUID().uuidString).png")
      try await IconGenerator.quantize(source: raw, to: quant, colors: create.settings.palette)
      defer { try? FileManager.default.removeItem(at: quant) }

      if let data = try? Data(contentsOf: quant) {
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
      alertMessage = "Exported to \(dir.path)/Assets.xcassets/AppIcon.appiconset"
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
