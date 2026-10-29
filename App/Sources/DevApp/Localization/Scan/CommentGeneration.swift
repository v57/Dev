//
//  CommentGeneration.swift
//  Dev
//
//  Created by Dmitry on 14.09.26.
//

import Foundation
import PlatformLanguageModel

// MARK: - Why a key was skipped

/// Why one key's comment was NOT generated.
///
/// Every case here is a SKIP, never a failure: the pass is best-effort by
/// construction (notes 2.8) and the scan it rides on has already succeeded.
nonisolated enum CommentSkipReason: String, Sendable, CaseIterable {
  /// The on-device model cannot answer on this machine.
  case modelUnavailable
  /// The scan resolved no source file for the key.
  case noSourceFile
  /// A file was known but could not be read.
  case unreadableFile
  /// The regex found no call site in the file.
  case noCallSite
  /// The model answered something unusable — a quote, a restatement, nothing.
  case refused
  /// The model threw (a refusal, a busy session, a failure).
  case failed

  /// Row label for the report.
  var label: String {
    switch self {
    case .modelUnavailable: return "model unavailable"
    case .noSourceFile: return "the scan named no source file"
    case .unreadableFile: return "source file unreadable"
    case .noCallSite: return "no call site found by the regex"
    case .refused: return "answer refused or unusable"
    case .failed: return "the model failed"
    }
  }
}

// MARK: - One unit of work

/// One key the pass will try to comment.
nonisolated struct CommentTarget: Sendable {
  var key: String
  /// The text a manual key prints (the artifact's source value). The call-site
  /// regex looks for the key AND for this: a key like `coin_row` is a symbol,
  /// and the file spells the sentence that stands next to it.
  var value: String?
  /// Source files the scan says emitted this key, in the scan's order. The
  /// first one that yields a call site wins.
  var files: [URL]

  var id: String { key }
}

/// What the pass did — counts, the comments themselves, and the timing the
/// report quotes.
nonisolated struct CommentPassOutcome: Sendable {
  /// Keys the pass was asked about (a key whose artifact already carried a
  /// comment is never one of them).
  var targetCount = 0
  /// Key -> the generated sentence. The caller writes these into the open
  /// catalog (an ordinary app-side edit pending Save, 5.8).
  var generated: [String: String] = [:]
  /// Skip reason -> how many keys it cost.
  var skipped: [CommentSkipReason: Int] = [:]
  /// Set when the pass never started: the model is unavailable, and this is
  /// the reason to show. The scan itself is unaffected.
  var unavailableReason: String?
  /// Keys of the merged catalog with no comment that the scan did NOT locate
  /// (no call site is knowable for them — nothing to blame).
  var unlocatedCount = 0
  var cancelled = false
  var duration: TimeInterval = 0
  /// Wall time spent inside the model, the honest denominator for the
  /// per-comment figure (skips never reach the model).
  var modelSeconds: TimeInterval = 0

  var generatedCount: Int { generated.count }
  var skippedCount: Int { skipped.values.reduce(0, +) }
  var didRun: Bool { unavailableReason == nil }
  /// Measured average the model took for ONE comment — the number that says a
  /// catalogue of hundreds is minutes.
  var secondsPerComment: Double {
    generated.isEmpty ? 0 : modelSeconds / Double(generated.count)
  }
  /// Skip reasons with a non-zero count, in `allCases` order.
  var skipLines: [(reason: CommentSkipReason, count: Int)] {
    CommentSkipReason.allCases.compactMap { reason in
      guard let count = skipped[reason], count > 0 else { return nil }
      return (reason, count)
    }
  }

  mutating func skip(_ reason: CommentSkipReason) {
    skipped[reason, default: 0] += 1
  }
}

// MARK: - The model

/// What the pass asks for a comment. A protocol, not a concrete call, for two
/// reasons: the pass must be exercisable with the model UNAVAILABLE (the
/// graceful path the scan promises), and nothing else in the app may reach
/// for a model of its own — the on-device one here is the single named
/// exception to the run's single model (notes 5.2).
nonisolated protocol CommentModel: Sendable {
  /// `nil` when the model can answer right now, else why it cannot.
  var unavailableReason: String? { get }
  /// One sentence for the translator. Throws when the model refuses or fails.
  func comment(for target: CommentTarget, snippet: String) async throws -> String
}

/// The on-device model of the Foundation Models framework — the same
/// capability Xcode's own "Generate Comment" is built on (notes 2.8): no key,
/// no network, no rate budget, measured at well under a second per comment.
nonisolated struct OnDeviceCommentModel: CommentModel {
  var unavailableReason: String? {
    // The framework ships with macOS 26; on 15 (and off the Mac) the pass reports why and skips.
    OnDeviceLanguageModel.unavailableReason
  }

  func comment(for target: CommentTarget, snippet: String) async throws -> String {
    try await OnDeviceLanguageModel.respond(to: Self.prompt(target, snippet: snippet), instructions: Self.instructions)
  }

  /// One sentence that describes USE. The rules are the whole point of the
  /// pass: a comment that restates the string, quotes it, or invents a screen
  /// the snippet does not show is worse than no comment — and each of those is
  /// also checked again in `CommentGeneration.sanitize`.
  private static let instructions = """
  You explain ONE string of a .xcstrings string catalog to the translator who \
  has to translate it. You are given the string's key and a snippet of the \
  app's code that uses the string.
  Write ONE sentence saying where the string appears and what it labels — the \
  way you would explain it to a translator who cannot read the code.
  Rules:
  - One sentence only, at most 25 words.
  - Never repeat the string's own text, never quote it, and never mention its \
  key: describe what the string is FOR, not what it says.
  - Never say "translate" and never address the reader.
  - Say nothing the snippet does not show: no invented screens, no guesses \
  about the app, and no code detail — no view, stack, list or type names.
  """

  /// Key, the source text when there is one, and the code around the call
  /// site. The key is the string's identity, the snippet is its use.
  private static func prompt(_ target: CommentTarget, snippet: String) -> String {
    var lines = ["key: \(target.key)"]
    if let value = target.value, !value.isEmpty, value != target.key {
      lines.append("source text: \(value)")
    }
    lines.append("")
    lines.append("code:")
    lines.append(snippet)
    return lines.joined(separator: "\n")
  }
}

// MARK: - The pass

/// The on-device comment pass (notes 2.8): after the app's own Scan Strings
/// operation, every key of the merged catalog that has NO comment gets one,
/// written from the call site the scan located in the key's own source file.
///
/// Three properties are the design, not an afterthought:
///   - it consumes the SCAN's in-memory result, so no file path is stored
///     anywhere (the catalog has no column for one and gains none);
///   - it only touches keys without a comment — a human's comment is never
///     rewritten, and a key that already has one costs nothing;
///   - it is best-effort: an unavailable model, a key with no source file, a
///     file that cannot be read, a regex that finds nothing, an answer that
///     restates the string or a failing model call SKIPS that key and is
///     reported. The scan has already succeeded by then.
///
/// SERIAL on purpose. Measured on this machine: one comment takes ~0.7 s, and
/// three concurrent sessions answer ten in 6.2 s against 7.6 s serially — the
/// framework serialises the on-device model, so extra sessions buy ~18% while
/// costing the transcript and the error surface. One session per comment, one
/// comment at a time.
nonisolated enum CommentGeneration {
  /// Source lines carried on each side of a hit — the model's context, and
  /// what makes a comment describe use instead of restating the string.
  static let contextLines = 4

  // MARK: work list

  /// The keys to comment: every key the SCAN found whose artifact carries no
  /// comment, with the file(s) that emitted it.
  ///
  /// `noFile` counts the located-but-fileless keys (the format named no file
  /// or one this module does not carry) and `unlocated` the catalog keys with
  /// no comment that the scan never found — neither can have a call site, and
  /// both are reported rather than silently dropped.
  static func targets(
    extracted: [String: Set<String>],
    keyFiles: [String: [String]],
    catalog: StringCatalog
  ) -> (targets: [CommentTarget], noFile: Int, unlocated: Int) {
    var targets: [CommentTarget] = []
    var noFile = 0
    for key in extracted.keys.sorted() {
      guard needsComment(key: key, catalog: catalog) else { continue }
      let files = (keyFiles[key] ?? []).map { URL(fileURLWithPath: $0) }
      guard !files.isEmpty else {
        noFile += 1
        continue
      }
      targets.append(
        CommentTarget(
          key: key,
          value: catalog.rawValue(for: key, language: catalog.sourceLanguage),
          files: files))
    }
    var unlocated = 0
    for (key, entry) in catalog.strings
    where (entry.comment ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      if extracted[key] == nil { unlocated += 1 }
    }
    return (targets, noFile, unlocated)
  }

  /// True when this key's entry carries no comment yet. A key the catalog
  /// does not have is a key the merge is about to add — it has no comment
  /// either, and the sentence generated for it travels with the merge.
  private static func needsComment(key: String, catalog: StringCatalog) -> Bool {
    guard let entry = catalog.strings[key] else { return true }
    return (entry.comment ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  // MARK: the pass

  /// Generates one comment per target, in order, through ONE model.
  ///
  /// `onComment` is called as each sentence is ready — the caller writes it
  /// into the catalog there and then, which is what makes a cancel keep
  /// everything generated so far. The cancel flag is read between comments
  /// (a comment takes well under a second, so a cancel lands immediately);
  /// a model call that throws is a skip, never an error that fails the scan.
  static func run(
    targets: [CommentTarget],
    model: any CommentModel,
    cancellation: ScanCancellation,
    onComment: @escaping @Sendable (String, String) -> Void,
    onProgress: @escaping @Sendable (Int, Int, String) -> Void
  ) async -> CommentPassOutcome {
    var outcome = CommentPassOutcome(targetCount: targets.count)
    if let reason = model.unavailableReason {
      outcome.unavailableReason = reason
      return outcome
    }
    let started = Date()
    for (index, target) in targets.enumerated() {
      if cancellation.isCancelled {
        outcome.cancelled = true
        break
      }
      onProgress(index, targets.count, target.key)
      switch snippet(for: target) {
      case .skip(let reason):
        outcome.skip(reason)
      case .snippet(let context):
        let callStarted = Date()
        do {
          let answer = try await model.comment(for: target, snippet: context)
          outcome.modelSeconds += Date().timeIntervalSince(callStarted)
          guard let comment = sanitize(answer, target: target) else {
            outcome.skip(.refused)
            continue
          }
          outcome.generated[target.key] = comment
          onComment(target.key, comment)
        } catch {
          outcome.modelSeconds += Date().timeIntervalSince(callStarted)
          outcome.skip(.failed)
        }
      }
    }
    outcome.duration = Date().timeIntervalSince(started)
    return outcome
  }

  // MARK: the call site

  /// The call-site lookup's answer: the code around the hit, or the reason
  /// there is none.
  enum CallSite: Sendable {
    case snippet(String)
    case skip(CommentSkipReason)
  }

  /// The code around `target`'s call site, or why there is none.
  ///
  /// `.stringsdata` records the FILE a key came from and nothing else — no
  /// line, no column. The file is read here, the literal is found with the
  /// regex above, and a few lines of context go to the model. The first file
  /// that yields a hit wins; a key the scan attributed to several files is
  /// therefore commented from the first one that really spells it.
  static func snippet(for target: CommentTarget) -> CallSite {
    var patterns = [target.key]
    if let value = target.value, !value.isEmpty, value != target.key {
      patterns.append(value)
    }
    var readable = false
    for file in target.files {
      guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
      readable = true
      for pattern in patterns.map(literalPattern) {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { continue }
        return .snippet(context(in: text, around: match.range, lines: contextLines))
      }
    }
    return .skip(readable ? .noCallSite : .unreadableFile)
  }

  /// A regex for one localizable literal as the extractor spells it.
  ///
  /// `-emit-localized-strings` does NOT keep the source text: an interpolated
  /// string is emitted as its format specifiers, so `"\(n) colors"` arrives
  /// as `"%lld colors"` and searching for the key verbatim finds NOTHING.
  /// Every specifier therefore ALSO matches the interpolation it stands for —
  /// and the specifier itself, for a literal that really contains one. A
  /// literal `%` is matched in both spellings the format allows (`%` and the
  /// escaped `%%`).
  static func literalPattern(_ text: String) -> String {
    var pattern = ""
    var index = text.startIndex
    while index < text.endIndex {
      let character = text[index]
      if character == "%", let specifier = formatSpecifier(in: text, at: index) {
        if specifier == "%%" {
          pattern += #"(?:%%|%)"#
        } else {
          pattern += "(?:" + interpolation + "|"
            + NSRegularExpression.escapedPattern(for: specifier) + ")"
        }
        index = text.index(index, offsetBy: specifier.count)
        continue
      }
      if character == "%" {
        // A percent the extractor does not treat as a specifier: the format
        // may spell it as-is or escaped, so accept either.
        pattern += #"(?:%|%%)"#
        index = text.index(after: index)
        continue
      }
      if whitespaceOrQuote.contains(character) {
        pattern += bothSpellings(of: character)
        index = text.index(after: index)
        continue
      }
      pattern += NSRegularExpression.escapedPattern(for: String(character))
      index = text.index(after: index)
    }
    return pattern
  }

  /// Characters a Swift SOURCE may write literally or as an escape. The
  /// regex is matched against the source, not against the string the source
  /// holds: a key carrying a tab is spelled `\t` in every file, a key
  /// carrying a quotation mark is spelled `\"`, and typographic punctuation
  /// reaches the catalog as the straight character (verified on the Dev
  /// catalogue: two of its regex misses were exactly these spellings).
  private static let whitespaceOrQuote: Set<Character> = ["\t", "\n", "\r", "\"", "'", "\\"]

  /// The literal character OR the other spellings of it a source may use —
  /// its Swift escape (`<TAB>` for a tab, `\"` for a quote) and the
  /// typographic punctuation the same key arrives with (`’` for `'`).
  private static func bothSpellings(of character: Character) -> String {
    var spellings = [NSRegularExpression.escapedPattern(for: String(character))]
    let escape: String
    switch character {
    case "\t": escape = "t"
    case "\n": escape = "n"
    case "\r": escape = "r"
    case "\"": escape = "\""
    case "'": escape = "'"
    default: escape = "\\"
    }
    spellings.append(NSRegularExpression.escapedPattern(for: "\\" + escape))
    switch character {
    case "'": spellings.append("’")
    case "\"": spellings.append(contentsOf: ["“", "”"])
    default: break
    }
    return "(?:" + spellings.joined(separator: "|") + ")"
  }

  /// A Swift string interpolation — `\(` … `)` — as a regex, one nesting
  /// level deep (`\(Int(scale * 100))`).
  ///
  /// A RAW string on purpose, and the opener needs three backslashes: the
  /// regex wants a literal BACKSLASH (`\\`) followed by a literal paren
  /// (`\(`), while the interpolation's CLOSER is a bare `)` written as `\)`.
  /// Written as `\\(` the regex would instead read "a backslash and then a
  /// group", which matches nothing. Getting this wrong is not cosmetic: the
  /// whole pass reads its context out of this match.
  private static let interpolation = #"\\\((?:[^()\n]|\([^()\n]*\))*\)"#

  /// The printf specifier starting at `index` (`%@`, `%lld`, `%1$@`, `%%`), or
  /// nil when this `%` is not one the extractor emits.
  static func formatSpecifier(in text: String, at index: String.Index) -> String? {
    var cursor = text.index(after: index)
    guard cursor < text.endIndex else { return nil }
    if text[cursor] == "%" { return "%%" }
    var specifier = "%"
    var digits = 0
    while cursor < text.endIndex, text[cursor].isNumber {
      specifier.append(text[cursor])
      cursor = text.index(after: cursor)
      digits += 1
    }
    if cursor < text.endIndex, text[cursor] == "$" {
      specifier.append("$")
      cursor = text.index(after: cursor)
    } else if digits > 0 {
      return nil                                  // "%5" is not a specifier
    }
    var lengthModifiers = 0
    while cursor < text.endIndex, "lhqztLj".contains(text[cursor]), lengthModifiers < 2 {
      specifier.append(text[cursor])
      cursor = text.index(after: cursor)
      lengthModifiers += 1
    }
    guard cursor < text.endIndex, "@dioxXufeEgGscpaA".contains(text[cursor]) else { return nil }
    specifier.append(text[cursor])
    return specifier
  }

  /// `lines` lines of source on each side of a match — the context that makes
  /// the comment describe use.
  static func context(in text: String, around range: NSRange, lines: Int) -> String {
    let all = text.components(separatedBy: "\n")
    guard !all.isEmpty else { return "" }
    let first = lineIndex(in: text, atUTF16Offset: range.location)
    let last = lineIndex(in: text, atUTF16Offset: range.location + max(range.length - 1, 0))
    let from = max(0, first - lines)
    let to = min(all.count - 1, last + lines)
    guard from <= to else { return "" }
    return all[from...to].joined(separator: "\n")
  }

  /// The line a UTF-16 offset falls on. Counted over the UTF-16 view on
  /// purpose: that is the unit NSRegularExpression reports in, and a newline
  /// is one code unit there.
  static func lineIndex(in text: String, atUTF16Offset offset: Int) -> Int {
    var line = 0
    var cursor = 0
    for unit in text.utf16 {
      if cursor >= offset { break }
      if unit == 0x0A { line += 1 }
      cursor += 1
    }
    return line
  }

  // MARK: the answer

  /// The model's answer as a comment, or nil when it is unusable.
  ///
  /// The instructions forbid quoting or restating the string, but an answer
  /// is not a contract: the key's own text (or the value's) appearing in the
  /// sentence means the rule broke and the comment would tell a translator
  /// nothing, so it is REFUSED rather than written. Wrapping quotes are
  /// trimmed, and a runaway second sentence is cut off at the first break.
  static func sanitize(_ answer: String, target: CommentTarget) -> String? {
    var text = answer
      .replacingOccurrences(of: "\n", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’ "))
    guard !text.isEmpty else { return nil }
    if restates(text, target.key) { return nil }
    if let value = target.value, restates(text, value) { return nil }
    if let stop = text.range(of: ". "), text.distance(from: text.startIndex, to: stop.lowerBound) > 40 {
      text = String(text[text.startIndex..<stop.lowerBound])
    }
    return text.isEmpty ? nil : text
  }

  /// True when `text` repeats a literal instead of describing its use.
  ///
  /// Two shapes count, and only these two — the first cut compared the
  /// literal anywhere in the sentence, which refused 32 good comments
  /// ("Clear" appears in "clears the selection"):
  ///   - the literal QUOTED (`"Discard"`): the comment repeats what the
  ///     translator already sees. The instructions forbid quotation marks
  ///     outright; this is the one kind the check can catch reliably;
  ///   - a MULTI-WORD literal repeated verbatim as a phrase. A one-word
  ///     string is just a word, and banning the word bans the comment that
  ///     says "labels the clear action", which is exactly the comment wanted.
  private static func restates(_ text: String, _ literal: String) -> Bool {
    let needle = stripped(literal)
    guard needle.count >= 4 else { return false }
    for (open, close) in [("\"", "\""), ("'", "'"), ("“", "”")] {
      if text.range(of: open + needle + close, options: .caseInsensitive) != nil {
        return true
      }
    }
    guard needle.contains(" "), needle.count >= 10 else { return false }
    return text.range(of: needle, options: .caseInsensitive) != nil
  }

  /// The literal without its format specifiers — the way a sentence can talk
  /// about it ("%lld colors" is discussed as "colors").
  private static func stripped(_ literal: String) -> String {
    var stripped = ""
    var index = literal.startIndex
    while index < literal.endIndex {
      if literal[index] == "%", let specifier = formatSpecifier(in: literal, at: index) {
        index = literal.index(index, offsetBy: specifier.count)
        continue
      }
      stripped.append(literal[index])
      index = literal.index(after: index)
    }
    return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
