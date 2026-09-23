import SwiftUI

struct MusicSourcesSettingsView: View {
    @State private var store = MeloXSourceStore.shared
    @State private var scriptText = ""
    @State private var scriptURL = ""
    @State private var errorMessage: String?
    @State private var isImporting = false

    var body: some View {
        Form {
            Section {
                TextField("Script URL", text: $scriptURL)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                Button("Import from URL") { Task { await importURL() } }
                    .disabled(scriptURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isImporting)
                TextEditor(text: $scriptText)
                    .frame(minHeight: 180)
                    .font(.system(.footnote, design: .monospaced))
                    .overlay(alignment: .topLeading) {
                        if scriptText.isEmpty {
                            Text("Paste a CyMusic script exporting module.exports.getMusicUrl")
                                .font(.footnote).foregroundStyle(.tertiary).padding(.top, 8).padding(.leading, 5).allowsHitTesting(false)
                        }
                    }
                Button("Add pasted script", action: addPastedScript)
                    .disabled(scriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: {
                Text("Import")
            } footer: {
                Text("Supports synchronous CyMusic getMusicUrl scripts in this build. Async LX scripts are not yet supported.")
            }
            Section("Installed sources") {
                if store.sources.isEmpty {
                    ContentUnavailableView("No sources", systemImage: "waveform.path")
                } else {
                    ForEach(store.sources) { source in
                        HStack(spacing: 12) {
                            Button { store.select(source.enabled ? nil : source) } label: {
                                Image(systemName: source.enabled ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(source.enabled ? Color.accentColor : Color.secondary)
                            }.buttonStyle(.plain)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(source.name).font(.body.weight(.medium))
                                Text([source.author, source.version].filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if source.enabled { Text("Active").font(.caption).foregroundStyle(.secondary) }
                        }
                        .swipeActions { Button("Delete", role: .destructive) { store.remove(source) } }
                    }
                }
            }
            if let errorMessage { Section { Text(errorMessage).foregroundStyle(.red) } }
        }
        .navigationTitle("Music sources")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func addPastedScript() { add(script: scriptText, sourceURL: nil) }

    private func importURL() async {
        guard let url = URL(string: scriptURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            errorMessage = "Enter a valid HTTP or HTTPS URL."
            return
        }
        isImporting = true
        defer { isImporting = false }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let script = String(data: data, encoding: .utf8) else { throw MeloXSourceError.requestFailed }
            add(script: script, sourceURL: url)
            scriptURL = ""
        } catch { errorMessage = error.localizedDescription }
    }

    private func add(script: String, sourceURL: URL?) {
        let clean = script.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let metadata = JavaScriptSourceRuntime.metadata(for: clean)
        let source = MeloXSource(id: metadata.id, name: metadata.name, author: metadata.author,
                                 version: metadata.version, script: clean, sourceURL: sourceURL,
                                 enabled: store.sources.isEmpty, updatedAt: Date())
        store.upsert(source)
        if source.enabled { store.select(source) }
        scriptText = ""
        errorMessage = nil
    }
}
