import Foundation
import Combine

@MainActor
final class MeloXSourceStore: ObservableObject {
    @Published private(set) var sources: [MeloXSource] = []
    private let fileURL: URL
    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("melox-sources.json")
        load()
    }
    func upsert(_ source: MeloXSource) { sources.removeAll { $0.id == source.id }; sources.append(source); save() }
    func remove(_ source: MeloXSource) { sources.removeAll { $0.id == source.id }; save() }
    func setEnabled(_ enabled: Bool, for source: MeloXSource) { guard let i = sources.firstIndex(where: { $0.id == source.id }) else { return }; sources[i].enabled = enabled; save() }
    private func load() { guard let data = try? Data(contentsOf: fileURL), let value = try? JSONDecoder().decode([MeloXSource].self, from: data) else { return }; sources = value }
    private func save() { guard let data = try? JSONEncoder().encode(sources) else { return }; try? data.write(to: fileURL, options: .atomic) }
}
