import Foundation
#if canImport(JavaScriptCore)
import JavaScriptCore
#endif

final class JavaScriptSourceRuntime {
    #if canImport(JavaScriptCore)
    private let context = JSContext()!
    #endif
    func resolve(script: String, songName: String, artist: String, quality: String) throws -> MeloXSourceTrack {
        guard !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MeloXSourceError.emptyScript }
        #if canImport(JavaScriptCore)
        let payload: [String: Any] = ["songname": songName, "artist": artist, "songmid": "", "quality": quality]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let encoded = String(data: data, encoding: .utf8) ?? "{}"
        let source = """(function(){var module={exports:{}};var exports=module.exports;\(script);var fn=module.exports.getMusicUrl||module.exports.getUrl;if(typeof fn!=='function')throw new Error('missing getMusicUrl');return fn(\(encoded));})()"""
        guard let value = context.evaluateScript(source)?.toObject() as? [String: Any] else { throw MeloXSourceError.invalidResult }
        guard let rawURL = (value["url"] as? String) ?? (value["src"] as? String), let url = URL(string: rawURL) else { throw MeloXSourceError.invalidResult }
        return MeloXSourceTrack(url: url, bitrate: value["bitrate"] as? Int, format: value["format"] as? String, lyric: value["lyric"] as? String, artwork: (value["pic"] as? String).flatMap(URL.init(string:)))
        #else
        throw MeloXSourceError.runtimeUnavailable
        #endif
    }
}
