//
//  ProjectOverviewView.swift
//  Dev
//

import AppKit
import DevScreenshots
import DevScreenshotsCapture
import ComponentKit
import SwiftUI

// MARK: - Facts

/// What the Overview says about a project beyond the sidebar row: its git
/// state, what kind of project it is, and its app icon files. Read off the main
/// actor when the Overview opens.
nonisolated struct ProjectFacts: Sendable {
  var branch: String?
  var commit: String?
  /// `git rev-list --count HEAD`: the build number the next run gets.
  var commitCount: Int?
  var lastCommit: Date?
  var latestTag: String?
  var kind = "Folder"
  var icon = IconFacts()

  struct IconFacts: Sendable {
    var hasSet = false
    var sizes = 0
    var smallest = 0
    var largest = 0
    var bytes: Int64 = 0
    var hasIconComposer = false
    var modified: Date?
  }

  static func load(root: URL, iconSet: URL?) async -> ProjectFacts {
    var facts = ProjectFacts()
    async let branch = LineProcess.run("/usr/bin/git", ["rev-parse", "--abbrev-ref", "HEAD"], directory: root)
    async let commit = LineProcess.run("/usr/bin/git", ["rev-parse", "--short", "HEAD"], directory: root)
    async let count = LineProcess.run("/usr/bin/git", ["rev-list", "--count", "HEAD"], directory: root)
    async let date = LineProcess.run("/usr/bin/git", ["log", "-1", "--format=%ct"], directory: root)
    async let tag = LineProcess.run("/usr/bin/git", ["describe", "--tags", "--abbrev=0"], directory: root)
    let trimmed = { (result: (status: Int32, output: String)) -> String? in
      result.status == 0 ? result.output.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty : nil
    }
    facts.branch = trimmed(await branch)
    facts.commit = trimmed(await commit)
    facts.commitCount = trimmed(await count).flatMap(Int.init)
    facts.lastCommit = trimmed(await date).flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
    facts.latestTag = trimmed(await tag)

    let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
    if names.contains(where: { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }) {
      let platform = ReleaseConfig.load(from: root)?["PLATFORM"]
      facts.kind = platform == "ios" ? "iOS app · Xcode project" : (platform == "macos" ? "macOS app · Xcode project" : "Xcode project")
    } else if names.contains("Package.swift") {
      facts.kind = "Swift package"
    } else if names.contains("package.json") {
      facts.kind = "Node project"
    } else if names.contains("Cargo.toml") {
      facts.kind = "Rust project"
    }

    let set = iconSet ?? root.appendingPathComponent("Assets.xcassets/AppIcon.appiconset")
    if let data = try? Data(contentsOf: set.appendingPathComponent("Contents.json")),
       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let images = json["images"] as? [[String: Any]] {
      let files = images.compactMap { $0["filename"] as? String }
      facts.icon.hasSet = !files.isEmpty
      facts.icon.sizes = files.count
      var pixels: [Int] = []
      for file in files {
        let url = set.appendingPathComponent(file)
        facts.icon.bytes += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        let size = ScreenshotLibrary.pixelSize(url)
        if size.0 > 0 { pixels.append(size.0) }
      }
      facts.icon.smallest = pixels.min() ?? 0
      facts.icon.largest = pixels.max() ?? 0
      facts.icon.modified = (try? set.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
    facts.icon.hasIconComposer = FileManager.default.fileExists(atPath: root.appendingPathComponent("AppIcon.icon").path)
      || FileManager.default.fileExists(atPath: set.deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("AppIcon.icon").path)
    return facts
  }
}

// MARK: - Overview

/// A project's front page: what it is, and how its localization, app icon,
/// workflows and App Store screenshots stand — each card a click from its tab.
struct ProjectOverviewView: View {
  let model: SidebarViewModel
  let row: SidebarProjectRow

  @Environment(WorkflowStore.self) private var workflows
  @Environment(ScreenshotsStore.self) private var screenshots
  @State private var facts = ProjectFacts()
  @State private var locale: String?

  var body: some View {
    ScrollView {
      // The header, the cards and the screenshots come in as they near the screen.
      KitLazyStack(alignment: .leading, spacing: 20) {
        header
        Grid(horizontalSpacing: 16, verticalSpacing: 16) {
          GridRow {
            localizationCard
            iconCard
            workflowsCard
          }
        }
        screenshotsSection
      }
      .padding(.horizontal, 24)
      .padding(.vertical, 20)
      .frame(maxWidth: 1100, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
    .task(id: row.id) {
      guard let root = row.rootURL else { return }
      facts = await ProjectFacts.load(root: root, iconSet: row.iconURL)
      await screenshots.refresh(root)
    }
  }

  // MARK: header

  private var header: some View {
    HStack(spacing: 16) {
      iconImage(size: 60)
      VStack(alignment: .leading, spacing: 5) {
        Text(row.name)
          .kitFont(.largeTitle)
        HStack(spacing: 8) {
          if let branch = facts.branch {
            RefChip(RefChip.Ref(name: branch, isCurrent: true, detail: facts.commit))
          }
          Text(facts.kind)
          if let count = facts.commitCount {
            Text("·")
            Text("Next build \(count + 1)")
              .help("The build number is the commit count (git rev-list --count HEAD)")
          }
          if let last = facts.lastCommit {
            Text("·")
            Text("Last commit \(last, format: .relative(presentation: .named))")
          }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
      }
      Spacer()
      if let root = row.rootURL {
        Button {
          ProjectOpener.open(root)
        } label: {
          Label("Open in \(ProjectOpener.appName)", systemImage: "arrow.up.forward.app")
        }
        .controlSize(.large)
      }
    }
  }

  // MARK: cards

  private var localizationCard: some View {
    OverviewCard(title: "Localization", systemImage: "globe", trailing: row.catalogExists ? row.catalogURL.lastPathComponent : nil) {
      if row.languages.isEmpty {
        Text(row.catalogExists ? "Open Localization to read the catalog." : "This project has no String Catalog yet.")
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        Text("\(row.keyCount) strings · \(row.languages.count) languages")
          .font(.callout)
          .foregroundStyle(.secondary)
        VStack(spacing: 7) {
          ForEach(row.languages.prefix(5)) { language in
            HStack(spacing: 10) {
              Text(language.name)
                .lineLimit(1)
                .frame(width: 84, alignment: .leading)
              ProgressView(value: language.fraction)
                .progressViewStyle(.linear)
              Text(language.fraction, format: .percent.precision(.fractionLength(0)))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
            }
            .font(.callout)
          }
        }
      }
    } footer: {
      if row.needsReview > 0 {
        Label("\(row.needsReview) need review", systemImage: "circle.fill")
          .labelStyle(DotLabelStyle(color: .orange))
          .foregroundStyle(.orange)
      }
      let missing = row.languages.reduce(0) { $0 + $1.missing }
      if missing > 0 {
        Text("\(missing) missing").foregroundStyle(.secondary)
      }
      Spacer()
      Button(row.needsReview > 0 ? "Review" : "Open") { model.projectTool = .localization }
        .buttonStyle(.kitPrimary)
    }
  }

  private var iconCard: some View {
    OverviewCard(
      title: "App Icon", systemImage: "app.badge",
      trailing: facts.icon.modified.map { "Exported \($0.formatted(date: .abbreviated, time: .omitted))" }
    ) {
      HStack(alignment: .center, spacing: 16) {
        if facts.icon.hasSet {
          iconImage(size: 96)
        } else {
          RoundedRectangle(cornerRadius: 22)
            .strokeBorder(.tertiary, style: StrokeStyle(lineWidth: 1.5, dash: [5]))
            .frame(width: 96, height: 96)
            .overlay(Image(systemName: "app.dashed").font(.title).foregroundStyle(.secondary))
        }
        if facts.icon.hasSet {
          Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
            GridRow {
              Text("Source").foregroundStyle(.secondary)
              Text("\(facts.icon.largest) × \(facts.icon.largest) px").fontWeight(.semibold)
            }
            GridRow {
              Text("Sizes").foregroundStyle(.secondary)
              Text("\(facts.icon.sizes), from \(facts.icon.smallest) to \(facts.icon.largest) px")
            }
            GridRow {
              Text("Files").foregroundStyle(.secondary)
              Text("PNG · \(facts.icon.bytes.byteString) in all")
            }
            GridRow {
              Text("Glass").foregroundStyle(.secondary)
              Text(facts.icon.hasIconComposer ? "AppIcon.icon" : "No Icon Composer file")
            }
          }
          .font(.callout)
        } else {
          Text("No AppIcon.appiconset yet.")
            .foregroundStyle(.secondary)
        }
      }
    } footer: {
      Spacer()
      Button(facts.icon.hasSet ? "Edit Icon" : "Make an Icon") { model.projectTool = .icon }
    }
  }

  @ViewBuilder
  private var workflowsCard: some View {
    let root = row.rootURL
    let list = root.map { workflows.workflows(for: $0) } ?? []
    let active = root.flatMap { workflows.active[$0] }
    OverviewCard(title: "Workflows", systemImage: "shippingbox", trailing: list.isEmpty ? nil : "\(list.count) workflows") {
      if let active {
        // The run's progress is the live icon's ring: steps passed or skipped of all its steps.
        let done = active.steps.filter { $0.state == .passed || $0.state == .skipped }.count
        HStack {
          LiveIcon(
            systemImage: "play", hue: .accent,
            status: .working(progress: Double(done) / Double(max(active.steps.count, 1))), size: 22)
          Text("\(active.workflowName) \(active.title)").fontWeight(.semibold)
          Spacer()
          Text(active.steps.first { $0.state == .running }?.name ?? "Starting")
            .foregroundStyle(Color.accentColor)
        }
        .padding(10)
        .kitSurface(.raised, cornerRadius: KitMetrics.radiusLarge)
      }
      VStack(alignment: .leading, spacing: 6) {
        ForEach(list) { workflow in
          let last = root.flatMap { workflows.lastRun(of: workflow.id, in: $0) }
          HStack(spacing: 8) {
            LiveIcon(
              systemImage: "play", hue: .gray,
              status: last.map { WorkflowsView.status(for: $0.state) } ?? .idle, size: 18)
            Text(workflow.name)
            Spacer()
            Text(last.map { "\($0.state.rawValue) · \($0.title)" } ?? workflow.trigger.summary)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
          .font(.callout)
        }
      }
    } footer: {
      Spacer()
      Button(active != nil ? "Open Run" : "Open Workflows") { model.projectTool = .workflows }
    }
  }

  // MARK: screenshots

  @ViewBuilder
  private var screenshotsSection: some View {
    let library = row.rootURL.flatMap { screenshots.library($0) }
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 10) {
        Text("App Store Screenshots")
          .font(.title3.weight(.semibold))
        if let library, let first = library.shots.first {
          Text("\(first.pixelWidth) × \(first.pixelHeight)" + (library.build.map { " · build \($0)" } ?? ""))
            .foregroundStyle(.secondary)
          let outdated = library.outdated.count
          if outdated > 0 {
            // dev-screenshots' status: commits under `watch`, or edited scenes, since the pictures.
            Chip(outdated == library.status?.scenes.count ? "Outdated" : "\(outdated) scenes outdated", hue: .orange)
          }
        }
        Spacer()
        if let library, library.locales.count > 1 {
          let current = currentLocale(library)
          KitMenuButton(Self.languageName(current), systemImage: "globe") {
            KitMenuOptions(
              selection: Binding(get: { current }, set: { locale = $0 }),
              options: library.locales.prefix(6).map { (Self.languageName($0), $0) })
          }
        }
        Button("Open Screenshots") { model.projectTool = .screenshots }
          .buttonStyle(.kit)
      }
      if let library, !library.shots.isEmpty {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 5), spacing: 14) {
          ForEach(overviewShots(library)) { shot in
            Button {
              // Both appearances of the shown device, so the viewer's Dark toggle has the dark ones.
              let shots = library.shots(in: shot.locale, on: shot.target)
              ScreenshotViewer.present(shots, selected: shot, framed: true)
            } label: {
              ScreenshotThumbnail(shot: shot, preferFinal: true)
            }
            .buttonStyle(.kitHoverEffect)
          }
        }
      } else {
        HStack {
          Text(library?.config == nil
               ? "No screenshot scenes. Describe them in .dev/screenshots.json, and the Screenshots tab captures them and frames them for the App Store."
               : "No screenshots captured yet. The Screenshots tab takes the scenes in .dev/screenshots.json and frames them for the App Store.")
            .foregroundStyle(.secondary)
          Spacer()
        }
      }
    }
    .padding(18)
    .kitSurface(.card, cornerRadius: KitMetrics.radiusXL)
  }

  static func languageName(_ code: String) -> String {
    Locale.current.localizedString(forIdentifier: code) ?? code
  }

  private func currentLocale(_ library: ScreenshotLibrary) -> String {
    if let locale, library.locales.contains(locale) { return locale }
    return library.locales.first ?? ""
  }

  /// One picture per scene: the light one on the first device, framed when it can be.
  private func overviewShots(_ library: ScreenshotLibrary) -> [ScreenshotLibrary.Shot] {
    let shots = library.shots(in: currentLocale(library))
    let framed = shots.first { $0.final != nil }?.target
    let target = framed ?? shots.first?.target
    let appearance = library.config?.appearances.first ?? .light
    return shots.filter { $0.target == target && $0.appearance == appearance }
  }

  @ViewBuilder
  private func iconImage(size: CGFloat) -> some View {
    if let image = row.iconImage {
      Image(nsImage: image)
        .resizable()
        .interpolation(.high)
        .aspectRatio(contentMode: .fit)
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
    } else {
      RoundedRectangle(cornerRadius: size * 0.225)
        .fill(.quaternary)
        .frame(width: size, height: size)
        .overlay(Image(systemName: "folder").font(.system(size: size * 0.4)).foregroundStyle(.secondary))
    }
  }
}

// MARK: - Pieces

/// One Overview card: a title row, its body and a footer of actions.
struct OverviewCard<Content: View, Footer: View>: View {
  let title: String
  let systemImage: String
  var trailing: String?
  @ViewBuilder let content: () -> Content
  @ViewBuilder let footer: () -> Footer

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      RichHeader(title, meta: trailing.map { [$0] } ?? [], systemImage: systemImage)
        .padding(.horizontal, -6)
      content()
      Spacer(minLength: 0)
      HStack(spacing: 12) { footer() }
        .kitFont(.callout)
        .buttonStyle(.kit)
    }
    .padding(14)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .kitSurface(.card, cornerRadius: KitMetrics.radiusXL)
  }
}

/// A small coloured dot in front of a label.
struct DotLabelStyle: LabelStyle {
  let color: Color

  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 5) {
      Circle().fill(color).frame(width: 7, height: 7)
      configuration.title
        .foregroundStyle(.kitLabel)
    }
  }
}

/// One screenshot at thumbnail size, with its name and an "outdated" dot.
struct ScreenshotThumbnail: View {
  let shot: ScreenshotLibrary.Shot
  /// Show the framed picture when there is one.
  var preferFinal = true
  var flag: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      let picture = shot.picture(framed: preferFinal)
      ZStack(alignment: .topTrailing) {
        AsyncImageFile(url: picture.url)
          .aspectRatio(CGFloat(max(picture.width, 1)) / CGFloat(max(picture.height, 1)), contentMode: .fit)
          .clipShape(RoundedRectangle(cornerRadius: 8))
          .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
        if let flag {
          Text(flag)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(.red, in: Capsule())
            .foregroundStyle(.white)
            .padding(6)
        }
      }
      // The picture tilts and lights under the pointer; the caption stays outside the effect.
      .kitHoverEffect(in: .rect(cornerRadius: 8))
      HStack(spacing: 6) {
        Text(shot.title)
          .lineLimit(1)
        Spacer(minLength: 0)
        if let reason = shot.state.reason {
          Circle().fill(.orange).frame(width: 7, height: 7).help("Needs a new capture: \(reason)")
        }
      }
      .font(.caption)
    }
    .kitContextMenu {
      Button("Show in Finder", systemImage: "folder") {
        NSWorkspace.shared.activateFileViewerSelecting([shot.final ?? shot.captured])
      }
    }
  }
}

/// An image file loaded off the main actor, so a strip of 2880-pixel PNGs
/// does not stall scrolling.
struct AsyncImageFile: View {
  let url: URL
  @State private var image: NSImage?

  var body: some View {
    Group {
      if let image {
        Image(nsImage: image)
          .resizable()
          .interpolation(.high)
      } else {
        Rectangle().fill(.quaternary)
      }
    }
    .task(id: url) {
      image = await Task.detached(priority: .utility) { () -> NSImage? in
        ImageThumbnails.thumbnail(url, maxPixel: 900)
      }.value
    }
  }
}

nonisolated enum ImageThumbnails {
  /// A downscaled copy through ImageIO, never the full-size bitmap.
  static func thumbnail(_ url: URL, maxPixel: Int) -> NSImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixel,
      kCGImageSourceCreateThumbnailWithTransform: true,
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
    return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
  }
}

// MARK: - Opening a project

/// Opens a project folder in the app chosen in Settings ▸ General.
enum ProjectOpener {
  static let key = "general.openProjectsIn"

  enum Target: String, CaseIterable, Identifiable {
    case xcode, code, finder
    var id: String { rawValue }
    var title: String {
      switch self {
      case .xcode: "Xcode"
      case .code: "Code"
      case .finder: "Finder"
      }
    }
  }

  static var target: Target {
    Target(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .xcode
  }

  static var appName: String { target.title }

  /// Xcode opens the project's .xcworkspace/.xcodeproj/Package.swift; Code and
  /// Finder open the folder.
  static func open(_ root: URL) {
    switch target {
    case .finder:
      NSWorkspace.shared.open(root)
    case .code:
      openWith(bundleID: "dev.v57.code", url: root)
    case .xcode:
      let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
      let file = names.first { $0.hasSuffix(".xcworkspace") }
        ?? names.first { $0.hasSuffix(".xcodeproj") }
        ?? (names.contains("Package.swift") ? "Package.swift" : nil)
      openWith(bundleID: "com.apple.dt.Xcode", url: file.map { root.appendingPathComponent($0) } ?? root)
    }
  }

  private static func openWith(bundleID: String, url: URL) {
    guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
      NSWorkspace.shared.open(url)
      return
    }
    NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
  }
}
