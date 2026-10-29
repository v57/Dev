//
//  ServerFormView.swift
//  Dev
//

import ComponentKit
import SwiftUI

/// The add/edit sheet for one server — ONE form for both, so the fields,
/// their validation and their help text cannot drift apart (the house pattern,
/// as in the Database app's `ConnectionFormView`).
///
/// The key field is the interesting one. It is EMPTY for a server that uses the
/// shared `LOCALIZE_KEY`, which is what a local server needs; typing one stores it
/// in the login keychain under this server's own account. On edit the field
/// stays empty and untouched until it is typed into, because the existing key is
/// never read back into the UI — a sheet is not a place to print a secret.
struct ServerFormView: View {
  /// The server being edited, or nil when this is an add.
  let editing: ServerConnection?
  /// Called with the finished values. `key == nil` means "leave the key alone".
  let onSave: (_ name: String, _ endpoint: String, _ key: String?) -> Void

  @Environment(\.kitDismiss) private var dismiss

  @State private var name: String
  @State private var endpoint: String
  @State private var key: String
  /// True once the key field was typed into, which is what turns an edit's key
  /// into a write. Without it, an untouched empty field would silently CLEAR a
  /// stored key.
  @State private var keyEdited = false
  @State private var showsKey = false
  /// A `LOCALIZE_KEY` found in the environment or a tool's `.env`, offered as
  /// this server's key. Looked up once, when the sheet opens.
  @State private var importable = ServerKeychain.importableSharedKey()

  init(
    editing: ServerConnection? = nil,
    onSave: @escaping (_ name: String, _ endpoint: String, _ key: String?) -> Void
  ) {
    self.editing = editing
    self.onSave = onSave
    _name = State(initialValue: editing?.name ?? "")
    _endpoint = State(
      initialValue: editing?.endpoint ?? LocalizeServer.base.absoluteString)
    _key = State(initialValue: "")
  }

  var body: some View {
    KitSheet(
      title: editing == nil ? "Add Connection" : "Edit Connection",
      meta: "A server that serves its strings through the Localization Server API", systemImage: "server.rack",
      hue: .gray
    ) {
      FormCard {
        FormRow(
          "Name", help: "What this server is called in the sidebar", systemImage: "character.cursor.ibeam", hue: .gray,
          field: TextField("Name", text: $name, prompt: Text("Local")))
        FormRow(
          "Endpoint", help: "The server's API root: the app POSTs localize/* under it", systemImage: "link",
          field: TextField("Endpoint", text: $endpoint, prompt: Text("http://127.0.0.1:8080/")))
        FormRow("Key", help: keyHelp, systemImage: "key", hue: .orange) {
          Button(showsKey ? "Hide" : "Show") { showsKey.toggle() }
            .buttonStyle(.kitPlain)
            .foregroundStyle(.kitLink)
        }
        Group {
          if showsKey {
            TextField("Key", text: $key, prompt: Text(sharedKeyHint))
          } else {
            SecureField("Key", text: $key, prompt: Text(sharedKeyHint))
          }
        }
        .labelsHidden()
        .kitField()
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
        .onChange(of: key) { _, _ in keyEdited = true }
        if key.isEmpty, let found = importable {
          GroupRow(
            "Use \(ServerKeychain.sharedKeyName) from \(found.source)",
            help: "Copies the key into this server's own keychain item when you save",
            action: { key = found.key })
        }
      }
    } footer: {
      if let problem {
        SheetStatus(problem, systemImage: "exclamationmark.triangle", hue: .orange)
      }
      Button("Cancel", role: .cancel) { dismiss() }
        .keyboardShortcut(.cancelAction)
      Button(editing == nil ? "Add" : "Save") { save() }
        .buttonStyle(.kitPrimary)
        .keyboardShortcut(.defaultAction)
        .disabled(problem != nil)
    }
  }

  // MARK: - validation

  /// The first thing that is wrong, or nil when the form can be saved. A name
  /// and a parseable http(s) endpoint are the whole requirement: the key is
  /// optional because the shared one is the default.
  private var problem: String? {
    if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return "the server needs a name"
    }
    guard parsedEndpoint != nil else {
      return "the endpoint must be an http(s) URL, e.g. http://127.0.0.1:8080/"
    }
    return nil
  }

  private var parsedEndpoint: URL? {
    guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
          let scheme = url.scheme?.lowercased(),
          scheme == "http" || scheme == "https",
          url.host?.isEmpty == false else { return nil }
    return url.path.hasSuffix("/") ? url : url.appendingPathComponent("")
  }

  private var sharedKeyHint: String {
    "empty: use \(ServerKeychain.sharedKeyName)"
  }

  private var keyHelp: String {
    editing == nil
      ? "Leave empty to use the shared \(ServerKeychain.sharedKeyName); a typed key is stored in the login keychain."
      : "Leave untouched to keep this server's stored key; type a new one to replace it, or clear it to fall back to \(ServerKeychain.sharedKeyName)."
  }

  // MARK: - save

  private func save() {
    guard let endpointURL = parsedEndpoint else { return }
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let typed = key.trimmingCharacters(in: .whitespacesAndNewlines)
    // nil = "leave the stored key alone"; "" = "clear it" (falls back to the
    // shared key); anything else is the new value.
    let keyValue: String? = editing == nil ? typed : (keyEdited ? typed : nil)
    onSave(trimmedName, endpointURL.absoluteString, keyValue)
    dismiss()
  }
}
