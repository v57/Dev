//
//  StoreTranslator.swift
//  Dev
//

import Foundation

/// Fills a locale's texts through Dev's translation: the model picked in Settings, the same route the Localization
/// tool's server runs take. Only on the reader's Translate; a text written by hand is never touched.
enum StoreTranslator {
  struct Work: Identifiable, Hashable, Sendable {
    var address: StoreAddress
    var source: String
    var sourceIsPrivate: Bool
    var limit: StoreLimit?
    var id: String { "\(address.field.rawValue)/\(address.destination?.rawValue ?? "")/\(address.locale ?? "")" }
  }

  /// What a locale still needs: missing or outdated, from each base text and destination override.
  nonisolated static func work(in texts: StoreTexts, locale: String, version: String?) -> [Work] {
    guard locale != texts.baseLocale else { return [] }
    var work: [Work] = []
    for field in StoreField.allCases where field.isTranslated {
      if field.isPerVersion, version == nil { continue }
      let scoped = field.isPerVersion ? version : nil
      let destinations = texts.settings().used.filter { $0.slot(field) != nil && $0.isLocalized }
      for destination in [nil] + destinations.map(Optional.some) {
        var address = StoreAddress(field: field, destination: destination, version: scoped)
        guard let source = texts.entry(address) else { continue }
        address.locale = locale
        let state = texts.translationState(of: address)
        guard state == .missing || state == .outdated else { continue }
        let limits = destination.map { [$0] } ?? destinations
        work.append(Work(
          address: address, source: source.text, sourceIsPrivate: source.isPrivate,
          limit: limits.compactMap { $0.slot(field)?.limit }.first))
      }
    }
    return work
  }

  /// What a translator needs to know beyond the words.
  nonisolated static func context(for work: Work) -> TranslationContext {
    var notes = ["\(work.address.field.title) on a store or release page."]
    if work.address.field.isList { notes.append("One item per line: keep it that way.") }
    if case .characters(let limit)? = work.limit { notes.append("At most \(limit) characters.") }
    if case .bytes(let limit)? = work.limit { notes.append("At most \(limit) bytes.") }
    return TranslationContext(comment: notes.joined(separator: " "))
  }

  /// Translates each text in turn, saving as it goes so a failure keeps what's done. Answers how many and any failure.
  static func run(
    _ work: [Work], from: String, in texts: StoreTexts, progress: @MainActor (Int) -> Void
  ) async -> (done: Int, failure: String?) {
    var done = 0
    for item in work {
      guard !Task.isCancelled else { break }
      do {
        let text = try await TranslationRouter.shared.translate(
          item.source, from: from, to: item.address.locale ?? "", context: context(for: item))
        try texts.writeTranslation(text, at: item.address, sourceText: item.source, sourceIsPrivate: item.sourceIsPrivate)
        done += 1
        progress(done)
      } catch {
        return (done, error.localizedDescription)
      }
    }
    return (done, nil)
  }
}
