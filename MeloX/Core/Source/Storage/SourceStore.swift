import Combine
import Foundation

@MainActor
@Observable
final class MeloXSourceStore {
    static let shared = MeloXSourceStore()

    private(set) var sources: [MeloXSource] = []
    private let fileURL: URL

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("melox-sources.json")
        load()
    }

    var activeSource: MeloXSource? { sources.first(where: \\.enabled) }

    func upsert(_ source: MeloXSource) {
        sources.removeAll { $0.id == source.id }
        sources.append(source)
        save()
    }

    func remove(_ source: MeloXSource) {
        sources.removeAll { $0.id == source.id }
        save()
    }

    func select(_ source: MeloXSource?) {
        for index in sources.indices { sources[index].enabled = sources[index].id == source?.id }
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let value = try? JSONDecoder().decode([MeloXSource].self, from: data) else { return }
        sources = value
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(sources) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
