//
//  MCPServer.swift
//  Dev
//

import AppKit
import Foundation

/// Dev's MCP server: `Dev.app/Contents/MacOS/Dev --mcp` speaks the Model
/// Context Protocol over stdin/stdout (one JSON-RPC message per line), so an
/// agent can set up a project's screenshot post-processing and its CI:
///
///   claude mcp add dev -- /Applications/Dev.app/Contents/MacOS/Dev --mcp
///
/// Reading and editing files (recipes, workflows) and rendering screenshots
/// happen in this process. Starting a run is asked of the open app, which owns
/// the runs, the VMs and the reader's confirmation. Every tool checks the
/// permission set for it in Settings ▸ Agents.
nonisolated enum MCPServer {
  static func run() -> Never {
    let queue = DispatchQueue(label: "dev.mcp")
    Thread.detachNewThread {
      while let line = readLine(strippingNewline: true) {
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
        queue.sync { handle(line) }
      }
      exit(0)
    }
    // Distributed notifications (the app's replies) arrive on the main run loop.
    RunLoop.main.run()
    exit(0)
  }

  // MARK: - JSON-RPC

  private static func handle(_ line: String) {
    guard let data = line.data(using: .utf8),
          let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let method = message["method"] as? String
    else {
      send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
      return
    }
    let id = message["id"]
    let params = message["params"] as? [String: Any] ?? [:]
    guard id != nil else { return }  // a notification: nothing to answer
    switch method {
    case "initialize":
      if let client = (params["clientInfo"] as? [String: Any])?["name"] as? String {
        UserDefaults.standard.set(client, forKey: AgentPermissions.lastClientKey)
      }
      UserDefaults.standard.set(Date(), forKey: AgentPermissions.lastSeenKey)
      reply(id, [
        "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
        "capabilities": ["tools": ["listChanged": false]],
        "serverInfo": ["name": "dev", "title": "Dev", "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"],
        "instructions": "Dev is a macOS developer toolbox. Use list_projects first, then read or change a project's App Store screenshot recipe (.dev/screenshots.json) and its CI workflows (.dev/workflows). Captions in a recipe are keys of the project's Screenshots.xcstrings, translated in Dev's Localization tool. Build numbers are the git commit count.",
      ])
    case "ping":
      reply(id, [:])
    case "tools/list":
      reply(id, ["tools": tools])
    case "tools/call":
      UserDefaults.standard.set(Date(), forKey: AgentPermissions.lastSeenKey)
      let name = params["name"] as? String ?? ""
      let arguments = params["arguments"] as? [String: Any] ?? [:]
      do {
        let result = try call(name, arguments)
        reply(id, ["content": [["type": "text", "text": text(result)]]])
      } catch {
        reply(id, ["content": [["type": "text", "text": error.localizedDescription]], "isError": true])
      }
    default:
      send(["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": -32601, "message": "Unknown method \(method)"]])
    }
  }

  private static func reply(_ id: Any?, _ result: [String: Any]) {
    send(["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result])
  }

  private static func send(_ object: [String: Any]) {
    guard var data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return }
    data.append(0x0A)
    FileHandle.standardOutput.write(data)
  }

  private static func text(_ value: Any) -> String {
    if let string = value as? String { return string }
    guard JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    else { return "\(value)" }
    return String(decoding: data, as: UTF8.self)
  }

  struct ToolError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
  }

  // MARK: - Tools

  private static let projectArg: [String: Any] = ["type": "string", "description": "The project's name or folder path (see list_projects)"]

  private static var tools: [[String: Any]] {
    func tool(_ name: String, _ description: String, _ properties: [String: Any] = [:], required: [String] = []) -> [String: Any] {
      ["name": name, "description": description,
       "inputSchema": ["type": "object", "properties": properties, "required": required]]
    }
    return [
      tool("list_projects", "The projects in Dev's sidebar, with whether each has a screenshot recipe and which workflows."),
      tool("get_screenshot_recipe", "A project's App Store screenshot post-processing recipe (.dev/screenshots.json) and the captured scene names it applies to.",
           ["project": projectArg], required: ["project"]),
      tool("set_screenshot_recipe", "Replaces a project's screenshot recipe. Fields: width, height (an App Store size), background (#RRGGBB), caption {catalog, fontSize, color, bold, maxLines, top}, window {scale 0.5–1, shadow, align bottom|center, cornerRadius}, scenes [{match: captured name, caption: catalog key in the development language, background}]. Captions are added to the catalog for translation.",
           ["project": projectArg, "recipe": ["type": "object"]], required: ["project", "recipe"]),
      tool("render_screenshots", "Applies the recipe to the latest captured screenshots and reports what it rendered and which captions do not fit.",
           ["project": projectArg], required: ["project"]),
      tool("list_screenshots", "The latest captured and rendered screenshots of a project, per locale, with file paths.",
           ["project": projectArg], required: ["project"]),
      tool("list_workflows", "A project's CI workflows: names, triggers and steps.",
           ["project": projectArg], required: ["project"]),
      tool("set_workflow", "Creates or replaces a workflow (.dev/workflows/<id>.json). Fields: id, name, trigger {branch, tag, daily HH:MM}, steps [{id, name, kind release|screenshots|command, releaseStep build|test|screenshots|archive|direct|github|appstore, command, runner mac|vm:<UTM name>, parallel}], continueOnFailure.",
           ["project": projectArg, "workflow": ["type": "object"]], required: ["project", "workflow"]),
      tool("delete_workflow", "Deletes a workflow file.",
           ["project": projectArg, "workflow": ["type": "string", "description": "The workflow id"]], required: ["project", "workflow"]),
      tool("run_workflow", "Asks the open Dev app to run a workflow. Publishing steps still follow the reader's permission.",
           ["project": projectArg, "workflow": ["type": "string", "description": "The workflow id"],
            "version": ["type": "string", "description": "Marketing version; empty reads the project's"]],
           required: ["project", "workflow"]),
      tool("get_runs", "A project's recent workflow runs, newest first, with each step's state and the end of its log.",
           ["project": projectArg], required: ["project"]),
    ]
  }

  private static func call(_ name: String, _ arguments: [String: Any]) throws -> Any {
    guard AgentPermissions.isEnabled else { throw ToolError(message: "Agents are turned off in Dev ▸ Settings ▸ Agents.") }
    switch name {
    case "list_projects":
      try require(.read, "read projects")
      return KnownProjects.read().map { entry -> [String: Any] in
        let root = URL(fileURLWithPath: entry.root)
        return ["name": entry.name, "root": entry.root,
                "hasScreenshotRecipe": ScreenshotRecipe.load(in: root) != nil,
                "workflows": Workflow.load(in: root).map(\.id)]
      }
    case "get_screenshot_recipe":
      try require(.read, "read the screenshot recipe")
      let root = try project(arguments)
      let library = ScreenshotLibrary.scan(root)
      let recipe = ScreenshotRecipe.load(in: root)
      return ["recipe": try recipe.map { try json($0) } ?? NSNull(),
              "capturedScenes": Array(Set(library.shots.map(\.name))).sorted(),
              "locales": library.locales,
              "captionCatalog": ScreenshotRecipe.load(in: root)?.caption.catalog ?? "Screenshots.xcstrings"]
    case "set_screenshot_recipe":
      let root = try project(arguments)
      try require(.edit, "change the screenshot recipe of \(root.lastPathComponent)")
      let recipe: ScreenshotRecipe = try decode(arguments["recipe"])
      try recipe.save(in: root, by: AgentPermissions.authorName)
      let keys = recipe.scenes.compactMap(\.caption).filter { !$0.isEmpty }
      try? CaptionCatalog.addMissingKeys(keys, to: root.appendingPathComponent(recipe.caption.catalog))
      announce(root)
      AgentPermissions.log("Changed the screenshot recipe of \(root.lastPathComponent)")
      return "Saved .dev/screenshots.json. Call render_screenshots to apply it."
    case "render_screenshots":
      let root = try project(arguments)
      try require(.edit, "render the screenshots of \(root.lastPathComponent)")
      let report = ScreenshotProcessor.process(root)
      announce(root)
      AgentPermissions.log("Rendered the screenshots of \(root.lastPathComponent)")
      return ["succeeded": report.succeeded, "rendered": report.rendered,
              "captionsTooLong": report.overflowing, "messages": report.lines]
    case "list_screenshots":
      try require(.read, "read screenshots")
      let root = try project(arguments)
      let library = ScreenshotLibrary.scan(root)
      return ["version": (library.version as Any?) ?? NSNull(), "locales": library.locales,
              "shots": library.shots.map { shot -> [String: Any] in
                ["name": shot.name, "locale": shot.locale, "captured": shot.captured.path,
                 "final": (shot.final?.path as Any?) ?? NSNull(), "width": shot.pixelWidth, "height": shot.pixelHeight,
                 "changedSinceLastVersion": shot.changed]
              }]
    case "list_workflows":
      try require(.read, "read workflows")
      return try json(Workflow.load(in: try project(arguments)))
    case "set_workflow":
      let root = try project(arguments)
      try require(.edit, "change a workflow of \(root.lastPathComponent)")
      var workflow: Workflow = try decode(arguments["workflow"])
      workflow.id = workflow.id.isEmpty ? workflow.name.lowercased().replacingOccurrences(of: " ", with: "-") : workflow.id
      if !FileManager.default.fileExists(atPath: Workflow.folder(in: root).path) {
        for other in Workflow.load(in: root) where other.id != workflow.id { try other.save(in: root) }
      }
      try workflow.save(in: root)
      announce(root)
      AgentPermissions.log("Saved the \(workflow.name) workflow of \(root.lastPathComponent)")
      return "Saved .dev/workflows/\(workflow.id).json"
    case "delete_workflow":
      let root = try project(arguments)
      try require(.edit, "delete a workflow of \(root.lastPathComponent)")
      let id = arguments["workflow"] as? String ?? ""
      guard FileManager.default.fileExists(atPath: Workflow.url(id, in: root).path) else {
        throw ToolError(message: "No workflow \(id).")
      }
      Workflow.delete(id, in: root)
      announce(root)
      AgentPermissions.log("Deleted the \(id) workflow of \(root.lastPathComponent)")
      return "Deleted"
    case "run_workflow":
      let root = try project(arguments)
      let id = arguments["workflow"] as? String ?? ""
      guard let workflow = Workflow.load(in: root).first(where: { $0.id == id }) else {
        throw ToolError(message: "No workflow \(id) in \(root.lastPathComponent).")
      }
      if AgentPermissions.level(.run) == .never { throw ToolError(message: "Starting runs is not allowed for agents (Settings ▸ Agents).") }
      if workflow.steps.contains(where: \.publishes), AgentPermissions.level(.publish) == .never {
        throw ToolError(message: "\(workflow.name) publishes, and publishing is not allowed for agents.")
      }
      let answer = try askApp(["kind": "run", "project": root.path, "workflow": id,
                               "version": arguments["version"] as? String ?? "",
                               "summary": "run \(workflow.name) in \(root.lastPathComponent)"])
      AgentPermissions.log("Asked to run \(workflow.name) in \(root.lastPathComponent): \(answer)")
      return answer
    case "get_runs":
      try require(.read, "read runs")
      let root = try project(arguments)
      return try json(WorkflowHistoryFile.runs(for: root).prefix(10).map { $0 })
    default:
      throw ToolError(message: "Unknown tool \(name)")
    }
  }

  // MARK: - Helpers

  private static func project(_ arguments: [String: Any]) throws -> URL {
    let value = (arguments["project"] as? String ?? "").trimmingCharacters(in: .whitespaces)
    let known = KnownProjects.read()
    if let entry = known.first(where: { $0.name.caseInsensitiveCompare(value) == .orderedSame || $0.root == value }) {
      return URL(fileURLWithPath: entry.root)
    }
    let expanded = (value as NSString).expandingTildeInPath
    if known.contains(where: { $0.root == expanded }) { return URL(fileURLWithPath: expanded) }
    throw ToolError(message: "No project \"\(value)\" in Dev. Known: \(known.map(\.name).joined(separator: ", ")).")
  }

  /// Checks the reader's permission; "Ask First" asks the open app.
  private static func require(_ action: AgentPermissions.Action, _ what: String) throws {
    switch AgentPermissions.level(action) {
    case .allow: return
    case .never: throw ToolError(message: "Not allowed: \(what) (Settings ▸ Agents).")
    case .ask:
      let answer = try askApp(["kind": "ask", "summary": what])
      guard answer == "approved" else { throw ToolError(message: "The reader declined: \(what).") }
    }
  }

  /// Posts a request to the app and waits for its answer, opening Dev first
  /// when it is not running.
  private static func askApp(_ request: [String: String]) throws -> String {
    let id = UUID().uuidString
    let semaphore = DispatchSemaphore(value: 0)
    final class Box: @unchecked Sendable { var answer: String? }
    let box = Box()
    let center = DistributedNotificationCenter.default()
    let observer = center.addObserver(forName: AgentChannel.reply, object: nil, queue: .main) { note in
      guard let info = note.userInfo as? [String: String], info["id"] == id else { return }
      box.answer = info["answer"]
      semaphore.signal()
    }
    defer { center.removeObserver(observer) }
    var payload = request
    payload["id"] = id
    payload["client"] = AgentPermissions.authorName
    let running = !NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "dev.v57.dev").isEmpty
    if !running {
      NSWorkspace.shared.open(Bundle.main.bundleURL)
      Thread.sleep(forTimeInterval: 4)
    }
    DispatchQueue.main.async {
      center.postNotificationName(AgentChannel.request, object: nil, userInfo: payload, deliverImmediately: true)
    }
    guard semaphore.wait(timeout: .now() + 300) == .success, let answer = box.answer else {
      throw ToolError(message: "Dev did not answer. Open Dev and try again.")
    }
    if answer.hasPrefix("error:") { throw ToolError(message: String(answer.dropFirst(6))) }
    return answer
  }

  private static func announce(_ root: URL) {
    DispatchQueue.main.async {
      DistributedNotificationCenter.default().postNotificationName(
        AgentChannel.changed, object: nil, userInfo: ["project": root.path], deliverImmediately: true)
    }
  }

  private static func json<T: Encodable>(_ value: T) throws -> Any {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(value)
    return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
  }

  private static func decode<T: Decodable>(_ value: Any?) throws -> T {
    guard let value, JSONSerialization.isValidJSONObject(value) else { throw ToolError(message: "Expected an object.") }
    let data = try JSONSerialization.data(withJSONObject: value)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    do {
      return try decoder.decode(T.self, from: data)
    } catch {
      throw ToolError(message: "That object does not fit: \(error)")
    }
  }
}

/// The run history file, read by the MCP process.
nonisolated enum WorkflowHistoryFile {
  static var url: URL? {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
      .appendingPathComponent(Bundle.main.bundleIdentifier ?? "dev.v57.dev", isDirectory: true)
      .appendingPathComponent("Workflows/history.json")
  }

  static func runs(for root: URL) -> [WorkflowRun] {
    guard let url, let data = try? Data(contentsOf: url),
          let saved = try? JSONDecoder().decode([String: [WorkflowRun]].self, from: data)
    else { return [] }
    return saved[root.path] ?? saved[root.standardizedFileURL.path] ?? []
  }
}
