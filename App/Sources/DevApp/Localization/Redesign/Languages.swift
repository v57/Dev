//
//  Languages.swift
//  Dev
//
//  What the pipeline needs to know about a target language and that no catalog says: its
//  English name for the prompt, the script it is written in (the answer check reads it, and
//  batch sizing reads how many tokens a translation into it takes), and the style rules a
//  language document starts from.
//

import Foundation

extension Translation {
  nonisolated enum Languages {
    /// The language's English name ("German", "Portuguese (Portugal)"), or the code.
    static func name(of code: String) -> String {
      Locale(identifier: "en_US").localizedString(forIdentifier: code) ?? code
    }

    /// The code's language part: "pt-PT" and "pt_BR" are "pt", "zh-Hans" is "zh".
    static func base(of code: String) -> String {
      String(code.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? Substring(code)).lowercased()
    }

    /// The script a language is written in, as Apple's platforms write it.
    static func script(of code: String) -> Script {
      // A script the code names wins over the language's usual one (`sr-Latn`, `uz-Cyrl`).
      if code.contains("Latn") { return .latin }
      if code.contains("Cyrl") { return .cyrillic }
      if code.contains("Arab") { return .arabic }
      return switch base(of: code) {
      case "ru", "uk", "be", "bg", "mk", "sr", "kk", "ky", "tg", "mn": .cyrillic
      case "el": .greek
      case "hy": .armenian
      case "ka": .georgian
      case "he", "yi": .hebrew
      case "ar", "ars", "fa", "ur", "ps", "sd", "ug", "ckb", "ks": .arabic
      case "dv": .thaana
      case "hi", "mr", "ne", "sa", "mai", "kok", "doi", "brx": .devanagari
      case "bn", "as": .bengali
      case "mni": .meeteiOrBengali
      case "pa": .gurmukhi
      case "gu": .gujarati
      case "or": .oriya
      case "ta": .tamil
      case "te": .telugu
      case "kn": .kannada
      case "ml": .malayalam
      case "si": .sinhala
      case "th": .thai
      case "lo": .lao
      case "bo": .tibetan
      case "my": .myanmar
      case "km": .khmer
      case "ko": .hangul
      case "zh", "yue": .han
      case "ja": .japanese
      case "sat": .olChiki
      case "chr": .cherokee
      default: .latin
      }
    }

    enum Script {
      case latin, cyrillic, greek, armenian, georgian, hebrew, arabic, thaana
      case devanagari, bengali, meeteiOrBengali, gurmukhi, gujarati, oriya, tamil, telugu, kannada
      case malayalam, sinhala, thai, lao, tibetan, myanmar, khmer, hangul, han, japanese, olChiki
      case cherokee

      /// The Unicode blocks of the script's letters; empty for Latin, which is what an
      /// untranslated answer is written in and so tells nothing apart.
      var ranges: [ClosedRange<UInt32>] {
        switch self {
        case .latin: []
        case .cyrillic: [0x0400...0x052F]
        case .greek: [0x0370...0x03FF, 0x1F00...0x1FFF]
        case .armenian: [0x0530...0x058F]
        case .georgian: [0x10A0...0x10FF, 0x1C90...0x1CBF]
        case .hebrew: [0x0590...0x05FF]
        case .arabic: [0x0600...0x06FF, 0x0750...0x077F, 0x08A0...0x08FF, 0xFB50...0xFDFF, 0xFE70...0xFEFF]
        case .thaana: [0x0780...0x07BF]
        case .devanagari: [0x0900...0x097F]
        case .bengali: [0x0980...0x09FF]
        case .meeteiOrBengali: [0x0980...0x09FF, 0xABC0...0xABFF]
        case .gurmukhi: [0x0A00...0x0A7F]
        case .gujarati: [0x0A80...0x0AFF]
        case .oriya: [0x0B00...0x0B7F]
        case .tamil: [0x0B80...0x0BFF]
        case .telugu: [0x0C00...0x0C7F]
        case .kannada: [0x0C80...0x0CFF]
        case .malayalam: [0x0D00...0x0D7F]
        case .sinhala: [0x0D80...0x0DFF]
        case .thai: [0x0E00...0x0E7F]
        case .lao: [0x0E80...0x0EFF]
        case .tibetan: [0x0F00...0x0FFF]
        case .myanmar: [0x1000...0x109F]
        case .khmer: [0x1780...0x17FF]
        case .hangul: [0xAC00...0xD7AF, 0x1100...0x11FF, 0x3130...0x318F]
        case .han: [0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF]
        case .japanese: [0x4E00...0x9FFF, 0x3400...0x4DBF, 0x3040...0x30FF]
        case .olChiki: [0x1C50...0x1C7F]
        case .cherokee: [0x13A0...0x13FF, 0xAB70...0xABBF]
        }
      }

      /// About how many answer tokens one character of English costs when translated into
      /// this script: Latin text runs ~4 characters a token and a little longer than the
      /// English, CJK about a token per character on a third of the length, and the scripts
      /// tokenizers see least split into several tokens a character. Rough on purpose: it
      /// only sizes batches.
      var tokensPerEnglishCharacter: Double {
        switch self {
        case .latin: 0.35
        case .cyrillic, .greek, .armenian, .georgian, .hebrew, .arabic, .thaana: 0.6
        case .han, .japanese, .hangul: 0.5
        case .devanagari, .bengali, .meeteiOrBengali, .gurmukhi, .gujarati, .oriya, .tamil, .telugu,
          .kannada, .malayalam, .sinhala:
          0.9
        case .thai, .lao, .tibetan, .myanmar, .khmer, .olChiki, .cherokee: 1.1
        }
      }

      func contains(_ scalar: Unicode.Scalar) -> Bool {
        ranges.contains { $0.contains(scalar.value) }
      }

      /// Letters any language's text may carry: Latin (names, acronyms, code), combining
      /// marks, and the CJK and full-width punctuation blocks.
      static func isShared(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0...0x02AF, 0x0300...0x036F, 0x1E00...0x1EFF, 0x2000...0x2BFF, 0x3000...0x303F, 0xFF00...0xFFEF: true
        default: false
        }
      }
    }
  }

  /// The style rules a language starts from while its project has written none: what the
  /// STYLE block says. A project's own language document replaces them.
  enum StyleRules {
    static func rules(for code: String) -> String {
      var lines = [
        "Follow the terminology and style Apple uses for this language in macOS and iOS.",
        "Buttons and menu items are short commands; titles and labels are short phrases.",
      ]
      switch code {
      case "zh-Hant", "zh-HK", "zh-TW": lines.append("Write in Traditional Chinese characters.")
      case "yue": lines.append("Write Cantonese in Traditional Chinese characters, as used in Hong Kong.")
      default: break
      }
      switch Languages.base(of: code) {
      case "de":
        lines += [
          "Address the user as Sie.",
          "Buttons and menu items use the infinitive (Datei öffnen).",
          "Quotation marks are „…“.",
        ]
      case "fr":
        lines += [
          "Address the user as vous.",
          "Buttons and menu items use the infinitive (Ouvrir le fichier).",
          "Put a non-breaking space before : ; ? ! and inside « ».",
        ]
      case "es":
        lines.append("Buttons and menu items use the infinitive (Abrir archivo).")
      case "ru":
        lines += [
          "Address the user as вы, lowercase.",
          "Buttons and menu items use the infinitive (Открыть файл).",
          "Quotation marks are «…».",
        ]
      case "uk":
        lines += [
          "Address the user as ви, lowercase.",
          "Buttons and menu items use the infinitive (Відкрити файл).",
          "Quotation marks are «…».",
        ]
      case "ja":
        lines += [
          "Sentences use the polite です/ます form; buttons and menu items are short phrases (ファイルを開く).",
          "Use Japanese punctuation (。、「」) in Japanese text.",
        ]
      case "zh":
        lines.append(
          "Use full-width punctuation (，。：？！) in Chinese text, and put a space between Chinese and Latin letters or digits.")
      case "ko":
        lines.append("Sentences use the polite 합니다/하세요 style; buttons and menu items are short noun phrases (파일 열기).")
      default:
        break
      }
      return lines.joined(separator: "\n")
    }
  }
}
