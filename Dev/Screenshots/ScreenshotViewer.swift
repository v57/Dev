//
//  ScreenshotViewer.swift
//  Dev
//

import DevDesktop
import DevGraphics
import DevScreenshots
import PlatformImage
import SwiftUI

/// Full-screen preview of a list of screenshots, opened by a click on one in the Overview or the
/// Screenshots tab. ← and → step through the list, D (or the toggle) shows every picture's dark
/// capture instead of its light one, Esc or Space closes.
@MainActor @Observable
final class ScreenshotViewer {
  /// One scene of the list, with its light and dark capture.
  struct Slot: Identifiable {
    let id: String
    var light: ScreenshotLibrary.Shot?
    var dark: ScreenshotLibrary.Shot?

    /// The capture in the appearance asked for, else the other one.
    func shot(dark wantsDark: Bool) -> ScreenshotLibrary.Shot {
      (wantsDark ? dark ?? light : light ?? dark)!
    }
  }

  let slots: [Slot]
  let framed: Bool
  var index: Int
  /// Applies to the whole list: stepping keeps it.
  var dark: Bool
  private var images: [URL: Image] = [:]
  private var loading: Set<URL> = []

  private init(slots: [Slot], index: Int, dark: Bool, framed: Bool) {
    self.slots = slots
    self.index = index
    self.dark = dark
    self.framed = framed
  }

  var slot: Slot { slots[index] }
  var shot: ScreenshotLibrary.Shot { slot.shot(dark: dark) }
  var hasBothAppearances: Bool { slots.contains { $0.light != nil && $0.dark != nil } }

  func step(_ offset: Int) {
    guard !slots.isEmpty else { return }
    index = (index + offset + slots.count) % slots.count
    preload()
  }

  func toggleDark() {
    guard hasBothAppearances else { return }
    dark.toggle()
    preload()
  }

  /// The picture at screen size, once it has loaded.
  func image(_ shot: ScreenshotLibrary.Shot) -> Image? {
    images[shot.picture(framed: framed).url]
  }

  /// Loads the shown picture and its neighbours, so stepping doesn't wait.
  func preload() {
    for offset in [0, 1, -1] {
      let slot = slots[(index + offset + slots.count) % slots.count]
      load(slot.shot(dark: dark).picture(framed: framed).url)
    }
  }

  private func load(_ url: URL) {
    guard images[url] == nil, !loading.contains(url) else { return }
    loading.insert(url)
    let maxPixel = DevDesktop.largestScreenPixels
    Task {
      let bitmap = await Task.detached(priority: .userInitiated) {
        ImageFile.thumbnail(at: url, maxPixel: maxPixel)
      }.value
      loading.remove(url)
      images[url] = bitmap.flatMap { Image(rgba: $0.rgba, width: $0.width, height: $0.height) }
    }
  }

  // MARK: - Presenting

  /// Shows `shots` full screen from `selected`: each scene once, in the list's order, with its
  /// light and dark capture paired, in the selected one's appearance.
  static func present(_ shots: [ScreenshotLibrary.Shot], selected: ScreenshotLibrary.Shot, framed: Bool) {
    var slots: [Slot] = []
    for shot in shots {
      let id = "\(shot.locale)/\(shot.target)/\(shot.name)"
      let i = slots.firstIndex { $0.id == id } ?? {
        slots.append(Slot(id: id))
        return slots.count - 1
      }()
      if shot.appearance == .dark { slots[i].dark = shot } else { slots[i].light = shot }
    }
    let id = "\(selected.locale)/\(selected.target)/\(selected.name)"
    guard let index = slots.firstIndex(where: { $0.id == id }) else { return }
    let viewer = ScreenshotViewer(slots: slots, index: index, dark: selected.appearance == .dark, framed: framed)
    viewer.preload()
    FullScreenViewer.present(ScreenshotViewerView(viewer: viewer) { dismiss() }) { key in
      switch key {
      case .previous: viewer.step(-1)
      case .next: viewer.step(1)
      case .close: dismiss()
      case .character("d"): viewer.toggleDark()
      case .character: return false
      }
      return true
    }
  }

  /// Whether pictures open full screen here (else a click on one does nothing).
  static var isAvailable: Bool { FullScreenViewer.isAvailable }

  static func dismiss(animated: Bool = true) {
    FullScreenViewer.dismiss(animated: animated)
  }
}

private struct ScreenshotViewerView: View {
  let viewer: ScreenshotViewer
  let close: () -> Void

  var body: some View {
    let shot = viewer.shot
    let picture = shot.picture(framed: viewer.framed)
    ZStack {
      Rectangle()
        .fill(Color.black.opacity(0.9))
        .background(.ultraThinMaterial)
        .ignoresSafeArea()
        .onTapGesture(perform: close)
      VStack(spacing: 0) {
        topBar(shot)
        ZStack {
          if let image = viewer.image(shot) {
            image
              .resizable()
              .interpolation(.high)
          } else {
            AsyncImageFile(url: picture.url)
          }
        }
        .aspectRatio(CGFloat(max(picture.width, 1)) / CGFloat(max(picture.height, 1)), contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.5), radius: 24, y: 8)
        .padding(.horizontal, 90)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .leading) { arrow("chevron.left") { viewer.step(-1) } }
        .overlay(alignment: .trailing) { arrow("chevron.right") { viewer.step(1) } }
        if viewer.slots.count > 1 { filmstrip }
      }
      .padding(.vertical, 20)
    }
    .environment(\.colorScheme, .dark)
  }

  private func topBar(_ shot: ScreenshotLibrary.Shot) -> some View {
    HStack(spacing: 14) {
      VStack(alignment: .leading, spacing: 2) {
        Text(shot.name).font(.headline)
        Text(detail(shot)).font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
      if viewer.hasBothAppearances {
        Button { viewer.toggleDark() } label: {
          Label("Dark", systemImage: viewer.dark ? "moon.fill" : "moon")
            .font(.callout.weight(.medium))
            .padding(.horizontal, 12)
            .frame(height: 28)
            .foregroundStyle(viewer.dark ? Color.black : .white)
            .background(viewer.dark ? Color.white : Color.white.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
        .help(viewer.dark ? "Show the light captures (D)" : "Show the dark captures (D)")
      }
      Button(action: close) {
        Image(systemName: "xmark")
          .font(.body.weight(.semibold))
          .frame(width: 28, height: 28)
          .background(.white.opacity(0.12), in: Circle())
      }
      .buttonStyle(.plain)
      .help("Close (Esc)")
    }
    .foregroundStyle(.white)
    .padding(.horizontal, 28)
    .padding(.top, 16)
    .padding(.bottom, 14)
  }

  private func detail(_ shot: ScreenshotLibrary.Shot) -> String {
    var parts = ["\(viewer.index + 1) of \(viewer.slots.count)"]
    parts.append(Locale.current.localizedString(forIdentifier: shot.locale) ?? shot.locale)
    parts.append(shot.target)
    if shot.appearance != (viewer.dark ? .dark : .light) {
      parts.append(viewer.dark ? "no dark capture" : "no light capture")
    }
    return parts.joined(separator: " · ")
  }

  private func arrow(_ symbol: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.title2.weight(.semibold))
        .foregroundStyle(.white)
        .frame(width: 44, height: 44)
        .background(.white.opacity(0.1), in: Circle())
    }
    .buttonStyle(.plain)
    .padding(.horizontal, 24)
    .opacity(viewer.slots.count > 1 ? 1 : 0)
  }

  private var filmstrip: some View {
    GeometryReader { geometry in
      ScrollViewReader { proxy in
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 10) {
            ForEach(Array(viewer.slots.enumerated()), id: \.element.id) { index, slot in
              let shot = slot.shot(dark: viewer.dark)
              let picture = shot.picture(framed: viewer.framed)
              AsyncImageFile(url: picture.url)
                .aspectRatio(CGFloat(max(picture.width, 1)) / CGFloat(max(picture.height, 1)), contentMode: .fit)
                .frame(height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5)
                  .strokeBorder(index == viewer.index ? Color.white : .clear, lineWidth: 2))
                .opacity(index == viewer.index ? 1 : 0.55)
                .id(slot.id)
                .onTapGesture { viewer.step(index - viewer.index) }
            }
          }
          .padding(.horizontal, 28)
          // Centred while the strip fits.
          .frame(minWidth: geometry.size.width)
        }
        .onChange(of: viewer.index, initial: true) { _, _ in
          withAnimation { proxy.scrollTo(viewer.slot.id, anchor: .center) }
        }
      }
    }
    .frame(height: 64)
    .padding(.top, 18)
  }
}
