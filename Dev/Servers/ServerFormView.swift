//
//  ServerFormView.swift
//  Dev
//

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

  @Environment(\.dismiss) private var dismiss

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
    VStack(alignment: .leading, spacing: 14) {
      Text(editing == nil ? "Add Connection" : "Edit Connection")
        .font(.headline)

      Form {
        TextField("Name", text: $name, prompt: Text("Local"))
          .help("What this server is called in the sidebar")

        TextField("Endpoint", text: $endpoint, prompt: Text("http://127.0.0.1:8080/"))
          .help("The server's API root: the app POSTs localize/* under it")

        HStack(spacing: 6) {
          if showsKey {
            TextField("Key", text: $key, prompt: Text(sharedKeyHint))
          } else {
            SecureField("Key", text: $key, prompt: Text(sharedKeyHint))
          }
          Button {
            showsKey.toggle()
          } label: {
            Image(systemName: showsKey ? "eye.slash" : "eye")
          }
          .buttonStyle(.borderless)
          .help(showsKey ? "Hide the key" : "Show the key")
        }
        .onChange(of: key) { _, _ in keyEdited = true }
        .help(keyHelp)
        if key.isEmpty, let found = importable {
          Button("Use \(ServerKeychain.sharedKeyName) from \(found.source)") {
            key = found.key
          }
          .buttonStyle(.link)
          .help("Copies the key into this server's own keychain item when you save")
        }
      }
      .formStyle(.grouped)

      HStack {
        if let problem {
          Label(problem, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.orange)
        }
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button(editing == nil ? "Add" : "Save") { save() }
          .keyboardShortcut(.defaultAction)
          .disabled(problem != nil)
      }
    }
    .padding(20)
    .frame(width: 420)
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
