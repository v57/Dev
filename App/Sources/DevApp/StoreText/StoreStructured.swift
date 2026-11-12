//
//  StoreStructured.swift
//  Dev
//

import Foundation

/// The fields that are answers rather than text: the age rating questionnaire, App Privacy and the App Review contact.
/// Each is one JSON object in `.dev/store/` (`<locale>/age-rating.json`), written with sorted keys so a diff names the
/// answer that changed. A key the file leaves out is a question not answered yet; `notes` is Dev's own and never sent.
nonisolated enum StoreStructured {
  // MARK: Files

  /// The answers as they're saved: checked, then written with sorted keys. Throws for anything that isn't an answer to
  /// one of the field's questions, so a typo or a password can't slip in.
  static func canonical(_ text: String, field: StoreField) throws -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }
    guard let object = (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) as? [String: Any] else {
      throw StoreTextError("\(field.title) is a JSON object. \(format(field))")
    }
    let clean = try validated(object, field: field)
    return clean.isEmpty ? "" : serialize(clean)
  }

  /// The answers a destination would receive: what's answered, without Dev's notes. Text that isn't valid stays as
  /// it is, so a plan compares it and a publish refuses it.
  static func sentForm(_ text: String, field: StoreField) -> String {
    guard var object = try? object(text, field: field) else { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
    object["notes"] = nil
    return object.isEmpty ? "" : serialize(object)
  }

  /// Every answer the local file gives is the live one.
  static func covers(live: String, local: String, field: StoreField) -> Bool {
    guard let local = try? object(sentForm(local, field: field), field: field) else { return false }
    let live = (try? object(live, field: field)) ?? [:]
    return local.allSatisfy { key, value in live[key].map { same($0, value) } ?? false }
  }

  /// The answers as a checked object; empty text is none.
  static func object(_ text: String, field: StoreField) throws -> [String: Any] {
    let clean = try canonical(text, field: field)
    guard !clean.isEmpty else { return [:] }
    return (try JSONSerialization.jsonObject(with: Data(clean.utf8))) as? [String: Any] ?? [:]
  }

  static func serialize(_ object: [String: Any]) -> String {
    let data = (try? JSONSerialization.data(
      withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
    return String(decoding: data, as: UTF8.self)
  }

  private static func same(_ first: Any, _ second: Any) -> Bool {
    serialize(["v": first]) == serialize(["v": second])
  }

  private static func validated(_ object: [String: Any], field: StoreField) throws -> [String: Any] {
    var clean: [String: Any] = [:]
    for (key, value) in object where !(value is NSNull) {
      if key == "notes" {
        guard let notes = value as? String else { throw StoreTextError("notes is a text.") }
        if !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { clean[key] = notes }
        continue
      }
      switch field {
      case .ageRating: clean[key] = try StoreAgeRating.check(key, value)
      case .appPrivacy: clean[key] = try StoreAppPrivacy.check(key, value)
      case .reviewContact:
        if let checked = try StoreReviewContact.check(key, value) { clean[key] = checked }
      default: throw StoreTextError("\(field.title) isn't a set of answers.")
      }
    }
    return clean
  }

  /// A JSON true or false, never a 1 or 0: on Apple platforms JSONSerialization reads both as an NSNumber.
  static func bool(_ key: String, _ value: Any) throws -> Bool {
    #if canImport(Darwin)
      if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue }
    #else
      if let flag = value as? Bool { return flag }
    #endif
    throw StoreTextError("\(key) is true or false.")
  }

  // MARK: What the tool and agents show

  /// The keys each file takes, for MCP and error messages.
  static func format(_ field: StoreField) -> String {
    switch field {
    case .ageRating:
      "age-rating keys are App Store Connect's ageRatingDeclaration attributes. "
        + "\(StoreAgeRating.frequencies.map(\.key).joined(separator: ", ")): NONE, INFREQUENT or FREQUENT. "
        + "\(StoreAgeRating.flags.map(\.key).joined(separator: ", ")): true or false. "
        + "kidsAgeBand: \(StoreAgeRating.kidsAgeBands.joined(separator: ", ")). "
        + "ageRatingOverrideV2: \(StoreAgeRating.overrides.joined(separator: ", ")). developerAgeRatingInfoUrl: a URL. "
        + "notes: Dev's own, never sent. A key left out is a question not answered yet."
    case .appPrivacy:
      "app-privacy: {collectsData: true|false (\"Do you or your third-party partners collect data from this app?\"), "
        + "dataTypes: [{type, purposes: [...], linkedToUser: bool, tracking: bool}], notes}. "
        + "types: \(StoreAppPrivacy.DataType.allCases.map(\.rawValue).joined(separator: ", ")). "
        + "purposes: \(StoreAppPrivacy.Purpose.allCases.map(\.rawValue).joined(separator: ", ")). "
        + "No API sets it: the reader enters it in App Store Connect."
    case .reviewContact:
      "review-contact: {firstName, lastName, email, phone, signInRequired: true|false, notes}. Never a demo account's "
        + "user name or password: those go only into App Store Connect's sign-in fields."
    default: ""
    }
  }

  /// One line about how far the answers are.
  static func summary(_ text: String, field: StoreField) -> String {
    guard let object = try? object(text, field: field) else { return String(localized: "not valid JSON") }
    switch field {
    case .ageRating:
      let answered = StoreAgeRating.questionKeys.filter { object[$0] != nil }.count
      return String(localized: "\(answered) of \(StoreAgeRating.questionKeys.count) answered")
    case .appPrivacy:
      let privacy = StoreAppPrivacy(object)
      switch privacy.collectsData {
      case nil: return String(localized: "not answered")
      case false?: return String(localized: "Data Not Collected")
      case true?: return String(localized: "\(privacy.dataTypes.count) data types")
      }
    case .reviewContact:
      let contact = StoreReviewContact(object)
      switch contact.signInRequired {
      case nil: return String(localized: "sign-in not answered")
      case true?: return String(localized: "sign-in required")
      case false?: return String(localized: "no sign-in")
      }
    default: return ""
    }
  }

  /// What a Copy button gives for a field the service can't take: App Privacy as the checklist to go through.
  static func copyText(_ text: String, field: StoreField) -> String {
    guard field == .appPrivacy, let object = try? object(text, field: field) else { return text }
    return StoreAppPrivacy(object).checklist
  }
}

// MARK: - Age rating

/// App Store Connect's age rating questionnaire. The keys are `ageRatingDeclarations` attributes (App Store Connect API
/// reference, AgeRatingDeclarationUpdateRequest, checked 2026-11-12), so a publish sends the answers as they are.
nonisolated enum StoreAgeRating {
  struct Question: Identifiable, Sendable {
    let key: String
    let title: String
    var id: String { key }
  }

  /// How often the content appears.
  static let frequencies: [Question] = [
    Question(key: "alcoholTobaccoOrDrugUseOrReferences", title: "Alcohol, tobacco or drug use or references"),
    Question(key: "contests", title: "Contests"),
    Question(key: "gamblingSimulated", title: "Simulated gambling"),
    Question(key: "gunsOrOtherWeapons", title: "Guns or other weapons"),
    Question(key: "horrorOrFearThemes", title: "Horror or fear themes"),
    Question(key: "matureOrSuggestiveThemes", title: "Mature or suggestive themes"),
    Question(key: "medicalOrTreatmentInformation", title: "Medical or treatment information"),
    Question(key: "profanityOrCrudeHumor", title: "Profanity or crude humor"),
    Question(key: "sexualContentOrNudity", title: "Sexual content or nudity"),
    Question(key: "sexualContentGraphicAndNudity", title: "Graphic sexual content and nudity"),
    Question(key: "violenceCartoonOrFantasy", title: "Cartoon or fantasy violence"),
    Question(key: "violenceRealistic", title: "Realistic violence"),
    Question(key: "violenceRealisticProlongedGraphicOrSadistic", title: "Prolonged, graphic or sadistic realistic violence"),
  ]

  /// Yes or no.
  static let flags: [Question] = [
    Question(key: "unrestrictedWebAccess", title: "Unrestricted web access"),
    Question(key: "userGeneratedContent", title: "User-generated content"),
    Question(key: "messagingAndChat", title: "Messaging and chat"),
    Question(key: "socialMedia", title: "Social media"),
    Question(key: "advertising", title: "Advertising"),
    Question(key: "parentalControls", title: "Parental controls"),
    Question(key: "ageAssurance", title: "Age assurance"),
    Question(key: "healthOrWellnessTopics", title: "Health or wellness topics"),
    Question(key: "gambling", title: "Gambling with real money"),
    Question(key: "lootBox", title: "Loot boxes"),
  ]

  /// The answers App Store Connect takes for a frequency; the first three are the questionnaire's, the others older.
  static let frequencyValues = ["NONE", "INFREQUENT", "FREQUENT", "INFREQUENT_OR_MILD", "FREQUENT_OR_INTENSE"]
  static let kidsAgeBands = ["FIVE_AND_UNDER", "SIX_TO_EIGHT", "NINE_TO_ELEVEN"]
  static let overrides = ["NONE", "NINE_PLUS", "THIRTEEN_PLUS", "SIXTEEN_PLUS", "EIGHTEEN_PLUS", "UNRATED"]

  /// The questions every app answers, for "n of m answered".
  static var questionKeys: [String] { (frequencies + flags).map(\.key) }

  /// Every key App Store Connect reads and writes here.
  static var attributeKeys: [String] {
    questionKeys + ["kidsAgeBand", "ageRatingOverrideV2", "developerAgeRatingInfoUrl"]
  }

  static func check(_ key: String, _ value: Any) throws -> Any {
    if frequencies.contains(where: { $0.key == key }) {
      guard let text = value as? String, frequencyValues.contains(text) else {
        throw StoreTextError("\(key) is NONE, INFREQUENT or FREQUENT.")
      }
      return text
    }
    if flags.contains(where: { $0.key == key }) {
      return try StoreStructured.bool(key, value)
    }
    switch key {
    case "kidsAgeBand":
      guard let text = value as? String, kidsAgeBands.contains(text) else {
        throw StoreTextError("kidsAgeBand is \(kidsAgeBands.joined(separator: ", ")).")
      }
      return text
    case "ageRatingOverrideV2":
      guard let text = value as? String, overrides.contains(text) else {
        throw StoreTextError("ageRatingOverrideV2 is \(overrides.joined(separator: ", ")).")
      }
      return text
    case "developerAgeRatingInfoUrl":
      guard let text = value as? String, text.hasPrefix("https://") || text.hasPrefix("http://") else {
        throw StoreTextError("developerAgeRatingInfoUrl is a URL.")
      }
      return text
    default:
      throw StoreTextError("Age rating has no question \"\(key)\". \(StoreStructured.format(.ageRating))")
    }
  }

  /// App Store Connect's declaration as the file's JSON: only the keys this file knows, and only answered ones.
  static func json(fromAttributes attributes: [String: Any]) -> String? {
    var object: [String: Any] = [:]
    for key in attributeKeys {
      guard let value = attributes[key], !(value is NSNull), let checked = try? check(key, value) else { continue }
      object[key] = checked
    }
    return object.isEmpty ? nil : StoreStructured.serialize(object)
  }
}

// MARK: - App Privacy

/// App Store Connect's App Privacy answers ("privacy nutrition label"). Apple's API has no endpoint for them, so these
/// are the answers to enter by hand, kept with the app so they're reviewed like the rest of its store text.
nonisolated struct StoreAppPrivacy: Equatable, Sendable {
  /// The first question: "Do you or your third-party partners collect data from this app?" nil is not answered.
  var collectsData: Bool?
  var dataTypes: [Item] = []
  var notes: String?

  struct Item: Equatable, Sendable {
    var type: DataType
    var purposes: [Purpose] = []
    var linkedToUser = false
    var tracking = false
  }

  /// App Store Connect's data types, by category (App Store Connect Help ▸ App privacy details).
  enum DataType: String, CaseIterable, Identifiable, Sendable {
    case name, emailAddress = "email-address", phoneNumber = "phone-number", physicalAddress = "physical-address"
    case otherContactInfo = "other-contact-info"
    case health, fitness
    case paymentInfo = "payment-info", creditInfo = "credit-info", otherFinancialInfo = "other-financial-info"
    case preciseLocation = "precise-location", coarseLocation = "coarse-location"
    case sensitiveInfo = "sensitive-info"
    case contacts
    case emailsOrTextMessages = "emails-or-text-messages", photosOrVideos = "photos-or-videos"
    case audioData = "audio-data", gameplayContent = "gameplay-content", customerSupport = "customer-support"
    case otherUserContent = "other-user-content"
    case browsingHistory = "browsing-history"
    case searchHistory = "search-history"
    case userID = "user-id", deviceID = "device-id"
    case purchaseHistory = "purchase-history"
    case productInteraction = "product-interaction", advertisingData = "advertising-data"
    case otherUsageData = "other-usage-data"
    case crashData = "crash-data", performanceData = "performance-data", otherDiagnosticData = "other-diagnostic-data"
    case environmentScanning = "environment-scanning"
    case hands, head
    case otherData = "other-data"

    var id: String { rawValue }

    var title: String {
      switch self {
      case .name: "Name"
      case .emailAddress: "Email Address"
      case .phoneNumber: "Phone Number"
      case .physicalAddress: "Physical Address"
      case .otherContactInfo: "Other User Contact Info"
      case .health: "Health"
      case .fitness: "Fitness"
      case .paymentInfo: "Payment Info"
      case .creditInfo: "Credit Info"
      case .otherFinancialInfo: "Other Financial Info"
      case .preciseLocation: "Precise Location"
      case .coarseLocation: "Coarse Location"
      case .sensitiveInfo: "Sensitive Info"
      case .contacts: "Contacts"
      case .emailsOrTextMessages: "Emails or Text Messages"
      case .photosOrVideos: "Photos or Videos"
      case .audioData: "Audio Data"
      case .gameplayContent: "Gameplay Content"
      case .customerSupport: "Customer Support"
      case .otherUserContent: "Other User Content"
      case .browsingHistory: "Browsing History"
      case .searchHistory: "Search History"
      case .userID: "User ID"
      case .deviceID: "Device ID"
      case .purchaseHistory: "Purchase History"
      case .productInteraction: "Product Interaction"
      case .advertisingData: "Advertising Data"
      case .otherUsageData: "Other Usage Data"
      case .crashData: "Crash Data"
      case .performanceData: "Performance Data"
      case .otherDiagnosticData: "Other Diagnostic Data"
      case .environmentScanning: "Environment Scanning"
      case .hands: "Hands"
      case .head: "Head"
      case .otherData: "Other Data Types"
      }
    }

    var category: String {
      switch self {
      case .name, .emailAddress, .phoneNumber, .physicalAddress, .otherContactInfo: "Contact Info"
      case .health, .fitness: "Health & Fitness"
      case .paymentInfo, .creditInfo, .otherFinancialInfo: "Financial Info"
      case .preciseLocation, .coarseLocation: "Location"
      case .sensitiveInfo: "Sensitive Info"
      case .contacts: "Contacts"
      case .emailsOrTextMessages, .photosOrVideos, .audioData, .gameplayContent, .customerSupport, .otherUserContent:
        "User Content"
      case .browsingHistory: "Browsing History"
      case .searchHistory: "Search History"
      case .userID, .deviceID: "Identifiers"
      case .purchaseHistory: "Purchases"
      case .productInteraction, .advertisingData, .otherUsageData: "Usage Data"
      case .crashData, .performanceData, .otherDiagnosticData: "Diagnostics"
      case .environmentScanning: "Surroundings"
      case .hands, .head: "Body"
      case .otherData: "Other Data"
      }
    }

    /// The categories in App Store Connect's order, each with its types.
    static var byCategory: [(String, [DataType])] {
      var order: [String] = []
      var types: [String: [DataType]] = [:]
      for type in allCases {
        if types[type.category] == nil { order.append(type.category) }
        types[type.category, default: []].append(type)
      }
      return order.map { ($0, types[$0] ?? []) }
    }
  }

  enum Purpose: String, CaseIterable, Identifiable, Sendable {
    case thirdPartyAdvertising = "third-party-advertising"
    case developerAdvertising = "developer-advertising"
    case analytics
    case productPersonalization = "product-personalization"
    case appFunctionality = "app-functionality"
    case otherPurposes = "other-purposes"

    var id: String { rawValue }

    var title: String {
      switch self {
      case .thirdPartyAdvertising: "Third-Party Advertising"
      case .developerAdvertising: "Developer's Advertising or Marketing"
      case .analytics: "Analytics"
      case .productPersonalization: "Product Personalization"
      case .appFunctionality: "App Functionality"
      case .otherPurposes: "Other Purposes"
      }
    }
  }

  init() {}

  /// From a checked object (`StoreStructured.object`).
  init(_ object: [String: Any]) {
    collectsData = object["collectsData"] as? Bool
    notes = object["notes"] as? String
    dataTypes = (object["dataTypes"] as? [[String: Any]] ?? []).compactMap { item in
      guard let type = (item["type"] as? String).flatMap(DataType.init) else { return nil }
      return Item(
        type: type, purposes: (item["purposes"] as? [String] ?? []).compactMap(Purpose.init),
        linkedToUser: item["linkedToUser"] as? Bool ?? false, tracking: item["tracking"] as? Bool ?? false)
    }
  }

  /// The file's JSON.
  var json: String {
    var object: [String: Any] = [:]
    if let collectsData { object["collectsData"] = collectsData }
    if !dataTypes.isEmpty {
      object["dataTypes"] = dataTypes.sorted { $0.type.rawValue < $1.type.rawValue }.map { item in
        [
          "type": item.type.rawValue, "purposes": item.purposes.map(\.rawValue).sorted(),
          "linkedToUser": item.linkedToUser, "tracking": item.tracking,
        ] as [String: Any]
      }
    }
    if let notes, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { object["notes"] = notes }
    return object.isEmpty ? "" : StoreStructured.serialize(object)
  }

  /// The answers in App Store Connect's order, to go through by hand.
  var checklist: String {
    var lines = ["App Privacy (App Store Connect ▸ App ▸ App Privacy)"]
    switch collectsData {
    case nil: lines.append("- Do you or your third-party partners collect data from this app? Not answered yet.")
    case false?: lines.append("- Do you or your third-party partners collect data from this app? No → Data Not Collected.")
    case true?:
      lines.append("- Do you or your third-party partners collect data from this app? Yes.")
      for item in dataTypes {
        lines.append("- \(item.type.category) ▸ \(item.type.title)")
        lines.append("  Purposes: \(item.purposes.map(\.title).joined(separator: ", "))")
        lines.append("  Linked to the user's identity: \(item.linkedToUser ? "Yes" : "No")")
        lines.append("  Used for tracking: \(item.tracking ? "Yes" : "No")")
      }
    }
    if let notes, !notes.isEmpty { lines += ["", notes] }
    return lines.joined(separator: "\n")
  }

  static func check(_ key: String, _ value: Any) throws -> Any {
    switch key {
    case "collectsData":
      return try StoreStructured.bool(key, value)
    case "dataTypes":
      guard let items = value as? [[String: Any]] else { throw StoreTextError("dataTypes is a list of objects.") }
      var seen = Set<String>()
      return try items.map { item -> [String: Any] in
        for key in item.keys where !["type", "purposes", "linkedToUser", "tracking"].contains(key) {
          throw StoreTextError("A data type has no \"\(key)\": type, purposes, linkedToUser, tracking.")
        }
        guard let type = item["type"] as? String, DataType(rawValue: type) != nil else {
          throw StoreTextError("A data type's type is one of \(DataType.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        guard seen.insert(type).inserted else { throw StoreTextError("\(type) is listed twice.") }
        let purposes = item["purposes"] as? [String] ?? []
        for purpose in purposes where Purpose(rawValue: purpose) == nil {
          throw StoreTextError("No purpose \"\(purpose)\": \(Purpose.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        let flag = { (name: String) throws -> Bool in try item[name].map { try StoreStructured.bool(name, $0) } ?? false }
        return [
          "type": type, "purposes": purposes.sorted(), "linkedToUser": try flag("linkedToUser"),
          "tracking": try flag("tracking"),
        ]
      }
    default:
      throw StoreTextError("App Privacy has no \"\(key)\". \(StoreStructured.format(.appPrivacy))")
    }
  }
}

// MARK: - App Review contact

/// Who App Review gets in touch with, and whether the app needs a sign-in (App Store Connect's App Review Information:
/// the `appStoreReviewDetails` contact attributes and `demoAccountRequired`). A demo account's user name and password
/// never come here: they go only into App Store Connect's sign-in fields, by hand.
nonisolated struct StoreReviewContact: Equatable, Sendable {
  var firstName = ""
  var lastName = ""
  var email = ""
  var phone = ""
  /// nil is not answered.
  var signInRequired: Bool?
  var notes: String?

  /// The file's keys and the attributes they go to.
  static let attributes: [(key: String, attribute: String)] = [
    ("firstName", "contactFirstName"), ("lastName", "contactLastName"), ("email", "contactEmail"),
    ("phone", "contactPhone"), ("signInRequired", "demoAccountRequired"),
  ]

  init() {}

  init(_ object: [String: Any]) {
    firstName = object["firstName"] as? String ?? ""
    lastName = object["lastName"] as? String ?? ""
    email = object["email"] as? String ?? ""
    phone = object["phone"] as? String ?? ""
    signInRequired = object["signInRequired"] as? Bool
    notes = object["notes"] as? String
  }

  var json: String {
    var object: [String: Any] = [:]
    // As typed: the save trims, so a space typed between two words isn't lost on the way.
    for (key, value) in [("firstName", firstName), ("lastName", lastName), ("email", email), ("phone", phone)]
    where !value.isEmpty {
      object[key] = value
    }
    if let signInRequired { object["signInRequired"] = signInRequired }
    if let notes, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { object["notes"] = notes }
    return object.isEmpty ? "" : StoreStructured.serialize(object)
  }

  /// nil drops an empty text.
  static func check(_ key: String, _ value: Any) throws -> Any? {
    let lower = key.lowercased()
    if lower.contains("password") || lower.contains("demoaccount") || lower.contains("username")
      || lower.contains("token") || lower.contains("secret") {
      throw StoreTextError(
        "A demo account's user name and password never go in .dev/store: enter them in App Store Connect's sign-in fields. Here, signInRequired says one is needed.")
    }
    switch key {
    case "firstName", "lastName", "email", "phone":
      guard let text = value as? String else { throw StoreTextError("\(key) is a text.") }
      let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
      return clean.isEmpty ? nil : clean
    case "signInRequired":
      return try StoreStructured.bool(key, value)
    default:
      throw StoreTextError("Review contact has no \"\(key)\". \(StoreStructured.format(.reviewContact))")
    }
  }

  /// App Store Connect's review detail as the file's JSON.
  static func json(fromAttributes attributes: [String: Any]) -> String? {
    var object: [String: Any] = [:]
    for (key, attribute) in Self.attributes {
      guard let value = attributes[attribute], !(value is NSNull), let checked = try? check(key, value) else { continue }
      object[key] = checked
    }
    return object.isEmpty ? nil : StoreStructured.serialize(object)
  }

  /// The attributes a publish sets: never the demo account's name or password.
  static func attributes(fromSent text: String) throws -> [String: Any] {
    let object = try StoreStructured.object(text, field: .reviewContact)
    var attributes: [String: Any] = [:]
    for (key, attribute) in Self.attributes {
      if let value = object[key] { attributes[attribute] = value }
    }
    return attributes
  }
}
