import Foundation
#if canImport(JavaScriptCore)
import JavaScriptCore
#endif
#if canImport(CommonCrypto)
import CommonCrypto
#endif

struct LXSourceMetadata: Equatable, Sendable {
    var name: String?
    var version: String?
    var author: String?
    var description: String?
    var homepage: URL?
}

@MainActor
final class JavaScriptSourceRuntime {
    private(set) var metadata = LXSourceMetadata(name: nil, version: nil, author: nil, description: nil, homepage: nil)
#if canImport(JavaScriptCore)
    private let context = JSContext()!
#endif

    func invalidate() {}

    func resolve(script: String, songName: String, artist: String, songID: String, quality: String) throws -> MeloXSourceTrack {
        let clean = script.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw MeloXSourceError.emptyScript }
        guard !clean.hasPrefix("/*") else { throw MeloXSourceError.unsupportedLXScript }
#if canImport(JavaScriptCore)
        metadata = Self.parseMetadata(clean)
        context.exception = nil
        let wrapper = "(function(){var module={exports:{}};var exports=module.exports;\(clean);return module.exports;})()"
        guard let module = context.evaluateScript(wrapper), context.exception == nil else { throw MeloXSourceError.invalidResult }
        guard let getURL = module.objectForKeyedSubscript("getMusicUrl"), !getURL.isUndefined else { throw MeloXSourceError.invalidResult }
        let result = getURL.call(withArguments: [songName, artist, songID, quality])
        guard let raw = result?.toString(), let url = URL(string: raw),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { throw MeloXSourceError.invalidResult }
        return MeloXSourceTrack(url: url, bitrate: nil, format: nil, lyric: nil, artwork: nil)
#else
        throw MeloXSourceError.runtimeUnavailable
#endif
    }

    static func metadata(for script: String) -> (id: String, name: String, author: String, version: String) {
        let values = parseMetadata(script)
        let fallback = String(script.hashValue, radix: 16)
        return (fallback, values.name ?? "Imported source", values.author ?? "", values.version ?? "")
    }

    private static func parseMetadata(_ script: String) -> LXSourceMetadata {
        var values = [String: String]()
        for line in script.components(separatedBy: .newlines).prefix(40) {
            let clean = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = clean.hasPrefix("*") ? String(clean.dropFirst()).trimmingCharacters(in: .whitespaces) : clean
            guard text.hasPrefix("@"), let split = text.firstIndex(of: " ") else { continue }
            let key = String(text[text.index(after: text.startIndex)..<split]).lowercased()
            values[key] = String(text[text.index(after: split)...]).trimmingCharacters(in: .whitespaces)
        }
        return LXSourceMetadata(name: values["name"], version: values["version"], author: values["author"], description: values["description"], homepage: values["homepage"].flatMap(URL.init(string:)))
    }
}
