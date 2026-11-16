//
//  LocalizationsCompare.swift
//  Dev
//
//  Debug builds only: the same language requests sent once per reasoning effort, to measure what
//  reasoning buys a translation (`compare <source> <count> <languages> <efforts>`). Nothing is written:
//  not the catalog, not Dev's records, not translation memory. Each answer, its tokens, time and the
//  validator's findings go to /tmp/dev-compare-<source>.json.
//

#if DEBUG
  import Foundation

  extension LocalizationsTranslator {
    struct Comparison: Encodable {
      struct Answer: Encodable {
        var language: String
        /// What was asked (`default` sends no effort) and what went out after any refusal.
        var effort: String
        var sent: String
        var seconds: Double
        var promptTokens: Int?
        var completionTokens: Int?
        var cachedTokens: Int?
        var error: String?
        /// Key → the answer as the catalog would hold it (a plural as its forms' JSON).
        var values: [String: String] = [:]
        var missing: [String] = []
        var defects: [String: [String]] = [:]
        var softDefects: [String: [String]] = [:]
      }
      var source: String
      var keys: [String]
      var answers: [Answer] = []
    }

    /// `count` of the source's live strings, spread over the catalog, asked in each language with each effort.
    func compare(
      catalog url: URL, source: String, count: Int, languages: [String], efforts: [String], code: [URL]
    ) async throws -> Comparison {
      guard let (workspace, _) = try await open(catalog: url, source: source, languages: languages, code: code)
      else { return Comparison(source: source, keys: []) }
      let project = workspace.project
      try project.loadData()
      let rows = project.data
        .filter { row in
          row.isCatalogRow && row.translatable && !row.targets.contains { $0.status == .stale || $0.status == .ignore }
        }
        .sorted { $0.key < $1.key }
      let step = max(1, rows.count / max(1, count))
      let sample = Array(stride(from: 0, to: rows.count, by: step).map { rows[$0] }.prefix(count))
      guard let model = RoutedModel.current else { throw Failure.open("No translation model is configured.") }

      var jobs: [(language: String, effort: String, request: Translation.Prompt.Request, items: [Translation.Run.Item])] = []
      for language in languages {
        let items = sample.map { row in
          Translation.Run.Item(
            key: row.key, language: language, source: row.content, target: .empty, comment: row.comment,
            maxWidth: row.maxWidth, file: project.sourceLocations[row.key]?.file ?? "")
        }
        let request = Translation.Prompt.languageBatch(language: language, items: items, project: project)
        for effort in efforts { jobs.append((language, effort, request, items)) }
      }

      var answers: [Comparison.Answer] = []
      var next = 0
      await withTaskGroup(of: Comparison.Answer.self) { group in
        func add() {
          guard next < jobs.count else { return }
          let job = jobs[next]
          next += 1
          group.addTask { @MainActor in
            await Self.ask(job.request, items: job.items, language: job.language, effort: job.effort, model: model)
          }
        }
        for _ in 0..<6 { add() }
        for await answer in group {
          answers.append(answer)
          add()
        }
      }
      return Comparison(
        source: source, keys: sample.map(\.key),
        answers: answers.sorted { ($0.language, $0.effort) < ($1.language, $1.effort) })
    }

    private static func ask(
      _ request: Translation.Prompt.Request, items: [Translation.Run.Item], language: String, effort: String,
      model: RoutedModel
    ) async -> Comparison.Answer {
      let asked = effort == "default" ? nil : effort
      let client = Translation.ChatStream(
        endpoint: model.endpoint, apiKey: model.bearer, model: model.model, wire: model.wire,
        headers: model.allHeaders, timeout: 300, reasoningEffort: asked, cachedPrefix: request.prefix)
      var answer = Comparison.Answer(language: language, effort: effort, sent: "", seconds: 0)
      let started = Date.now
      var raw = ""
      do {
        let usage = try await client.send(system: request.system, user: request.user) { raw += $0 }
        answer.promptTokens = usage?.promptTokens
        answer.completionTokens = usage?.completionTokens
        answer.cachedTokens = usage?.cachedTokens
      } catch {
        answer.error = error.localizedDescription
      }
      answer.seconds = Date.now.timeIntervalSince(started)
      let key = "\(model.endpoint.absoluteString)|\(model.model)"
      answer.sent = Translation.ChatStream.EffortMemory.shared.effort(asked, for: key) ?? "default"
      let replies = Translation.Validator.answers(in: raw)
      for (position, item) in items.enumerated() {
        guard let reply = replies[String(position)] else {
          answer.missing.append(item.key)
          continue
        }
        let body = Translation.Validator.decode(reply, for: item, language: language)
        answer.values[item.key] = body.catalogValue
        let hard = Translation.Validator.defects(body, of: item, language: language)
        if !hard.isEmpty { answer.defects[item.key] = hard.map { "\($0)" } }
        let soft = Translation.Validator.softDefects(body, of: item, language: language)
        if !soft.isEmpty { answer.softDefects[item.key] = soft.map { "\($0)" } }
      }
      return answer
    }
  }
#endif
