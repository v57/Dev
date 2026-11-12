//
//  StoreAnswersView.swift
//  Dev
//

import ComponentKit
import SwiftUI

/// The form for a field that holds answers (`StoreStructured`): it reads and writes the field's JSON text, so the
/// Store Text tab saves it like any other text.
struct StoreAnswersEditor: View {
  let field: StoreField
  @Binding var text: String

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        switch field {
        case .ageRating: StoreAgeRatingForm(text: $text)
        case .appPrivacy: StoreAppPrivacyForm(text: $text)
        case .reviewContact: StoreReviewContactForm(text: $text)
        default: EmptyView()
        }
      }
      .padding(.bottom, 8)
    }
    .controlSize(.small)
  }
}

/// A text the form can show while the file doesn't parse (a hand edit in progress): it says so instead of dropping it.
private struct InvalidAnswers: View {
  let field: StoreField
  let text: String

  var body: some View {
    if !text.isEmpty, (try? StoreStructured.object(text, field: field)) == nil {
      FormCard {
        FormRow(
          "The file isn't valid",
          help: "\(field.title) is JSON: fix .dev/store's file by hand, or change an answer here to start over.",
          systemImage: "exclamationmark.triangle", hue: .red)
      }
    }
  }
}

/// Notes kept with the answers: why each was given. Never sent.
private struct AnswerNotes: View {
  @Binding var notes: String

  var body: some View {
    FormCard("Notes", footer: "Why the answers are what they are. Kept with them, never sent.") {
      TextEditor(text: $notes)
        .kitFont(.body)
        .scrollContentBackground(.hidden)
        .padding(8)
        .frame(height: 110)
    }
  }
}

// MARK: - Age rating

private struct StoreAgeRatingForm: View {
  @Binding var text: String

  private var answers: [String: Any] { (try? StoreStructured.object(text, field: .ageRating)) ?? [:] }

  private func set(_ key: String, _ value: Any?) {
    var object = answers
    object[key] = value
    text = object.isEmpty ? "" : StoreStructured.serialize(object)
  }

  private func string(_ key: String) -> Binding<String> {
    Binding(get: { answers[key] as? String ?? "" }, set: { set(key, $0.isEmpty ? nil : $0) })
  }

  private func flag(_ key: String) -> Binding<String> {
    Binding(
      get: { (answers[key] as? Bool).map { $0 ? "yes" : "no" } ?? "" },
      set: { set(key, $0.isEmpty ? nil : $0 == "yes") })
  }

  /// The picker's choices, plus an older answer the file holds (an import's INFREQUENT_OR_MILD).
  private func options(_ base: [(String, String)], current: String) -> [(String, String)] {
    base.contains { $0.1 == current } ? base : base + [(current, current)]
  }

  var body: some View {
    InvalidAnswers(field: .ageRating, text: text)
    FormCard(
      "Age Rating",
      footer: "App Store Connect's questionnaire. Publish sends the answers given here and leaves the others as they are."
    ) {
      GroupRow("Answered", help: StoreStructured.summary(text, field: .ageRating))
    }
    FormCard("How often does the app show…") {
      ForEach(StoreAgeRating.frequencies) { question in
        let binding = string(question.key)
        GroupRow(question.title) {
          KitPicker(
            question.title, selection: binding,
            options: options(
              [("Not answered", ""), ("None", "NONE"), ("Infrequent", "INFREQUENT"), ("Frequent", "FREQUENT")],
              current: binding.wrappedValue))
            .kitPickerMaxWidth(150)
        }
      }
    }
    FormCard("Does the app have…") {
      ForEach(StoreAgeRating.flags) { question in
        GroupRow(question.title) {
          KitPicker(
            question.title, selection: flag(question.key), options: [("Not answered", ""), ("No", "no"), ("Yes", "yes")])
            .kitPickerMaxWidth(150)
        }
      }
    }
    FormCard("Optional") {
      GroupRow("Made for Kids", help: "The age band, only for an app in the Kids category") {
        KitPicker(
          "Made for Kids", selection: string("kidsAgeBand"),
          options: [("Not for kids", "")] + StoreAgeRating.kidsAgeBands.map { ($0, $0) })
          .kitPickerMaxWidth(150)
      }
      GroupRow("Higher rating", help: "Rate the app higher than its answers make it") {
        KitPicker(
          "Higher rating", selection: string("ageRatingOverrideV2"),
          options: [("Not answered", "")] + StoreAgeRating.overrides.map { ($0, $0) })
          .kitPickerMaxWidth(150)
      }
      GroupRow("Age rating information", help: "A page of yours about the rating") {
        TextField("Age rating information", text: string("developerAgeRatingInfoUrl"), prompt: Text("https://"))
          .labelsHidden().kitField().frame(width: 220)
      }
    }
    AnswerNotes(notes: string("notes"))
  }
}

// MARK: - App Privacy

private struct StoreAppPrivacyForm: View {
  @Binding var text: String

  private var privacy: StoreAppPrivacy {
    (try? StoreStructured.object(text, field: .appPrivacy)).map(StoreAppPrivacy.init) ?? StoreAppPrivacy()
  }

  private func change(_ edit: (inout StoreAppPrivacy) -> Void) {
    var copy = privacy
    edit(&copy)
    text = copy.json
  }

  private var collects: Binding<String> {
    Binding(
      get: { privacy.collectsData.map { $0 ? "yes" : "no" } ?? "" },
      set: { value in change { $0.collectsData = value.isEmpty ? nil : value == "yes" } })
  }

  private func collected(_ type: StoreAppPrivacy.DataType) -> Binding<Bool> {
    Binding(
      get: { privacy.dataTypes.contains { $0.type == type } },
      set: { on in
        change { privacy in
          privacy.dataTypes.removeAll { $0.type == type }
          if on { privacy.dataTypes.append(.init(type: type, purposes: [.appFunctionality])) }
        }
      })
  }

  private func item(_ type: StoreAppPrivacy.DataType, _ edit: @escaping (inout StoreAppPrivacy.Item) -> Void) {
    change { privacy in
      if let index = privacy.dataTypes.firstIndex(where: { $0.type == type }) { edit(&privacy.dataTypes[index]) }
    }
  }

  private func purpose(_ type: StoreAppPrivacy.DataType, _ purpose: StoreAppPrivacy.Purpose) -> Binding<Bool> {
    Binding(
      get: { privacy.dataTypes.first { $0.type == type }?.purposes.contains(purpose) == true },
      set: { on in
        item(type) { item in
          item.purposes.removeAll { $0 == purpose }
          if on { item.purposes.append(purpose) }
        }
      })
  }

  private func linked(_ type: StoreAppPrivacy.DataType) -> Binding<Bool> {
    Binding(
      get: { privacy.dataTypes.first { $0.type == type }?.linkedToUser == true },
      set: { on in item(type) { $0.linkedToUser = on } })
  }

  private func tracking(_ type: StoreAppPrivacy.DataType) -> Binding<Bool> {
    Binding(
      get: { privacy.dataTypes.first { $0.type == type }?.tracking == true },
      set: { on in item(type) { $0.tracking = on } })
  }

  var body: some View {
    let privacy = privacy
    InvalidAnswers(field: .appPrivacy, text: text)
    FormCard(
      "Enter by Hand",
      footer: "App Store Connect's API has no App Privacy endpoints, so Publish never sends these answers. Enter them in App Store Connect ▸ App Privacy, with this as the checklist."
    ) {
      GroupRow("Checklist", help: StoreStructured.summary(text, field: .appPrivacy)) {
        KitCopyButton(value: privacy.checklist)
      }
    }
    FormCard("Data Collection") {
      GroupRow(
        "Do you or your third-party partners collect data from this app?",
        help: "Data sent off the device and kept longer than a request needs. Data that stays on the device, or goes only to the user's own iCloud or servers, isn't collected."
      ) {
        KitPicker("Collects data", selection: collects, options: [("Not answered", ""), ("No", "no"), ("Yes", "yes")])
          .kitPickerMaxWidth(150)
      }
    }
    if privacy.collectsData == true {
      ForEach(StoreAppPrivacy.DataType.byCategory, id: \.0) { category, types in
        FormCard(category) {
          ForEach(types) { type in
            GroupRow(type.title) {
              Toggle(type.title, isOn: collected(type)).labelsHidden().toggleStyle(.kitSwitch)
            }
            if privacy.dataTypes.contains(where: { $0.type == type }) {
              VStack(alignment: .leading, spacing: 4) {
                ForEach(StoreAppPrivacy.Purpose.allCases) { item in
                  Toggle(item.title, isOn: purpose(type, item)).toggleStyle(.kitCheckbox)
                }
                Toggle("Linked to the user's identity", isOn: linked(type)).toggleStyle(.kitCheckbox)
                Toggle("Used for tracking", isOn: tracking(type)).toggleStyle(.kitCheckbox)
              }
              .padding(.horizontal, 24)
              .padding(.vertical, 6)
              .frame(maxWidth: .infinity, alignment: .leading)
            }
          }
        }
      }
    }
    AnswerNotes(
      notes: Binding(get: { privacy.notes ?? "" }, set: { notes in change { $0.notes = notes.isEmpty ? nil : notes } }))
  }
}

// MARK: - App Review contact

private struct StoreReviewContactForm: View {
  @Binding var text: String

  private var contact: StoreReviewContact {
    (try? StoreStructured.object(text, field: .reviewContact)).map(StoreReviewContact.init) ?? StoreReviewContact()
  }

  private func binding(_ path: WritableKeyPath<StoreReviewContact, String>) -> Binding<String> {
    Binding(
      get: { contact[keyPath: path] },
      set: { value in
        var copy = contact
        copy[keyPath: path] = value
        text = copy.json
      })
  }

  private var signIn: Binding<String> {
    Binding(
      get: { contact.signInRequired.map { $0 ? "yes" : "no" } ?? "" },
      set: { value in
        var copy = contact
        copy.signInRequired = value.isEmpty ? nil : value == "yes"
        text = copy.json
      })
  }

  private func field(_ title: String, _ path: WritableKeyPath<StoreReviewContact, String>, prompt: String) -> some View {
    GroupRow(title) {
      TextField(title, text: binding(path), prompt: Text(prompt)).labelsHidden().kitField().frame(width: 240)
    }
  }

  var body: some View {
    InvalidAnswers(field: .reviewContact, text: text)
    FormCard("Contact", footer: "Who App Review gets in touch with. Private: it stays out of git.") {
      field("First name", \.firstName, prompt: "First name")
      field("Last name", \.lastName, prompt: "Last name")
      field("Email", \.email, prompt: "name@example.com")
      field("Phone", \.phone, prompt: "+1 555 0100")
    }
    FormCard(
      "Sign-In",
      footer: "A demo account's user name and password never go here: enter them in App Store Connect's sign-in fields. Review Notes say what the account is for."
    ) {
      GroupRow("Sign-in required", help: "App Review needs an account to try the app") {
        KitPicker("Sign-in required", selection: signIn, options: [("Not answered", ""), ("No", "no"), ("Yes", "yes")])
          .kitPickerMaxWidth(150)
      }
    }
    AnswerNotes(
      notes: Binding(
        get: { contact.notes ?? "" },
        set: { notes in
          var copy = contact
          copy.notes = notes.isEmpty ? nil : notes
          text = copy.json
        }))
  }
}
