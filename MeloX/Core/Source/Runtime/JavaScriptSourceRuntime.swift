import Foundation
#if canImport(JavaScriptCore)
import JavaScriptCore
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
    private let runtimeKey = UUID().uuidString
    private var requestTasks: [String: URLSessionDataTask] = [:]
    private var musicContinuations: [String: CheckedContinuation<String, Error>] = [:]
    private var lxInitialized = false
#if canImport(JavaScriptCore)
    private let context = JSContext()!
#endif

    func invalidate() {
        requestTasks.values.forEach { $0.cancel() }
        requestTasks.removeAll()
        musicContinuations.removeAll()
    }

    func resolve(script: String, songName: String, artist: String, songID: String, quality: String) async throws -> MeloXSourceTrack {
        let clean = script.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw MeloXSourceError.emptyScript }
#if canImport(JavaScriptCore)
        if Self.isLXScript(clean) {
            return try await resolveLX(script: clean, songName: songName, artist: artist, songID: songID, quality: quality)
        }
        return try resolveSync(script: clean, songName: songName, artist: artist, songID: songID, quality: quality)
#else
        throw MeloXSourceError.runtimeUnavailable
#endif
    }

#if canImport(JavaScriptCore)
    private func resolveSync(script: String, songName: String, artist: String, songID: String, quality: String) throws -> MeloXSourceTrack {
        metadata = Self.parseMetadata(script)
        context.exception = nil
        let wrapper = "(function(){var module={exports:{}};var exports=module.exports;\(script);return module.exports;})()"
        guard let module = context.evaluateScript(wrapper), context.exception == nil else { throw MeloXSourceError.invalidResult }
        guard let getURL = module.objectForKeyedSubscript("getMusicUrl"), !getURL.isUndefined else { throw MeloXSourceError.invalidResult }
        let result = getURL.call(withArguments: [songName, artist, songID, quality])
        guard let raw = result?.toString(), let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { throw MeloXSourceError.invalidResult }
        return MeloXSourceTrack(url: url, bitrate: nil, format: nil, lyric: nil, artwork: nil)
    }

    private func resolveLX(script: String, songName: String, artist: String, songID: String, quality: String) async throws -> MeloXSourceTrack {
        installNativeBridge()
        lxInitialized = false
        context.exception = nil
        guard let preloadURL = Bundle.main.url(forResource: "user-api-preload", withExtension: "js"), let preload = try? String(contentsOf: preloadURL) else { throw MeloXSourceError.runtimeUnavailable }
        guard context.evaluateScript(preload) != nil, context.exception == nil else { throw MeloXSourceError.invalidResult }
        guard let setup = context.objectForKeyedSubscript("lx_setup"), !setup.isUndefined else { throw MeloXSourceError.invalidResult }
        let info = Self.parseMetadata(script)
        metadata = info
        setup.call(withArguments: [runtimeKey, "", info.name ?? "Imported source", info.description ?? "", info.version ?? "", info.author ?? "", info.homepage?.absoluteString ?? "", script])
        guard context.exception == nil else { throw MeloXSourceError.invalidResult }
        context.exception = nil
        _ = context.evaluateScript(script)
        guard context.exception == nil, lxInitialized else { throw MeloXSourceError.invalidResult }
        let requestID = UUID().uuidString
        let url = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            musicContinuations[requestID] = continuation
            let lxQuality = Self.lxQuality(for: quality)
            let body: [String: Any] = ["requestKey": requestID, "data": ["source": "wy", "action": "musicUrl", "info": ["type": lxQuality, "musicInfo": ["id": songID, "songmid": songID, "title": songName, "name": songName, "singer": artist, "artist": artist, "source": "wy", "hash": songID]]]]
            sendJS(action: "request", data: body)
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard let self, let pending = self.musicContinuations.removeValue(forKey: requestID) else { return }
                pending.resume(throwing: MeloXSourceError.requestFailed)
                self.sendJS(action: "response", data: ["requestKey": requestID, "error": "timeout"])
            }
        }
        guard let parsed = URL(string: url), ["http", "https"].contains(parsed.scheme?.lowercased() ?? "") else { throw MeloXSourceError.invalidResult }
        return MeloXSourceTrack(url: parsed, bitrate: nil, format: nil, lyric: nil, artwork: nil)
    }

    private func installNativeBridge() {
        let block: @convention(block) (String, String, String) -> Void = { [weak self] key, action, data in
            guard let self, key == self.runtimeKey else { return }
            self.handleNativeCall(action: action, data: data)
        }
        context.setObject(block, forKeyedSubscript: "__lx_native_call__" as NSString)
        let timer: @convention(block) (Int, Int) -> Void = { [weak self] identifier, milliseconds in
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(milliseconds, 0)) * 1_000_000)
                self?.sendJS(action: "__set_timeout__", rawData: identifier)
            }
        }
        context.setObject(timer, forKeyedSubscript: "__lx_native_call__set_timeout" as NSString)
        let passthrough: @convention(block) (String) -> String = { _ in "" }
        for name in ["utils_str2b64", "utils_b642buf", "utils_str2md5", "utils_aes_encrypt", "utils_rsa_encrypt"] {
            context.setObject(passthrough, forKeyedSubscript: "__lx_native_call__\(name)" as NSString)
        }
    }

    private func sendJS(action: String, data: [String: Any]) {
        guard let json = try? JSONSerialization.data(withJSONObject: data), let value = String(data: json, encoding: .utf8) else { return }
        sendJS(action: action, rawJSON: value)
    }

    private func sendJS(action: String, rawData: Int) {
        sendJS(action: action, rawJSON: String(rawData))
    }

    private func sendJS(action: String, rawJSON: String) {
        guard let native = context.objectForKeyedSubscript("__lx_native__") else { return }
        _ = native.call(withArguments: [runtimeKey, action, rawJSON])
    }

    private func handleNativeCall(action: String, data: String) {
        let value = try? JSONSerialization.jsonObject(with: Data(data.utf8))
        if action == "cancelRequest", let key = value as? String {
            requestTasks.removeValue(forKey: key)?.cancel()
            return
        }
        guard let object = value as? [String: Any] else { return }
        switch action {
        case "init":
            guard object["status"] as? Bool == true else { return }
            lxInitialized = true
        case "request":
            handleHTTP(object)
        case "response":
            guard let key = object["requestKey"] as? String, let pending = musicContinuations.removeValue(forKey: key) else { return }
            if let error = object["errorMessage"] as? String { pending.resume(throwing: NSError(domain: "LX", code: 1, userInfo: [NSLocalizedDescriptionKey: error])) }
            else if let result = object["result"] as? [String: Any], let payload = result["data"] as? [String: Any], let url = payload["url"] as? String { pending.resume(returning: url) }
            else { pending.resume(throwing: MeloXSourceError.invalidResult) }
        default: break
        }
    }

    private func handleHTTP(_ object: [String: Any]) {
        guard let key = object["requestKey"] as? String, let urlString = object["url"] as? String, let url = URL(string: urlString) else { return }
        var request = URLRequest(url: url)
        if let options = object["options"] as? [String: Any] {
            if let method = options["method"] as? String { request.httpMethod = method.uppercased() }
            if let headers = options["headers"] as? [String: String] { request.allHTTPHeaderFields = headers }
            if let body = options["body"] as? String { request.httpBody = Data(body.utf8) }
            if let timeout = options["timeout"] as? Double { request.timeoutInterval = min(max(timeout / 1000, 1), 60) }
        }
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            Task { @MainActor in
                guard let self else { return }
                self.requestTasks.removeValue(forKey: key)
                let result: [String: Any]
                if let error { result = ["requestKey": key, "error": error.localizedDescription] }
                else { result = ["requestKey": key, "response": ["statusCode": (response as? HTTPURLResponse)?.statusCode ?? 0, "statusMessage": HTTPURLResponse.localizedString(forStatusCode: (response as? HTTPURLResponse)?.statusCode ?? 0), "headers": (response as? HTTPURLResponse)?.allHeaderFields ?? [:], "body": String(data: data ?? Data(), encoding: .utf8) ?? ""]] }
                self.sendJS(action: "response", data: result)
            }
        }
        requestTasks[key] = task
        task.resume()
    }
#endif

    private static func lxQuality(for quality: String) -> String {
        switch quality.lowercased() {
        case "standard", "128k", "128000": return "128k"
        case "high", "exhigh", "320k", "320000": return "320k"
        case "hires", "flac24bit": return "flac24bit"
        default: return "flac"
        }
    }

    static func metadata(for script: String) -> (id: String, name: String, author: String, version: String) {
        let values = parseMetadata(script)
        return (String(script.hashValue, radix: 16), values.name ?? "Imported source", values.author ?? "", values.version ?? "")
    }

    private static func isLXScript(_ script: String) -> Bool {
        let header = script.range(of: #"^/\*[\s\S]+?\*/"#, options: .regularExpression) != nil
        let api = script.range(of: #"\b(lx_setup|EVENT_NAMES)\b|\blx\s*\.\s*(on|send)|globalThis\s*\.\s*lx"#, options: .regularExpression) != nil
        let native = script.range(of: #"module\s*\.\s*exports\s*\.\s*getMusicUrl"#, options: .regularExpression) != nil
        return header && api && !native
    }

    private static func parseMetadata(_ script: String) -> LXSourceMetadata {
        var values = [String: String]()
        for line in script.components(separatedBy: .newlines).prefix(40) {
            let clean = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = clean.hasPrefix("*") ? String(clean.dropFirst()).trimmingCharacters(in: .whitespaces) : clean
            guard text.hasPrefix("@"), let split = text.firstIndex(of: " ") else { continue }
            values[String(text[text.index(after: text.startIndex)..<split]).lowercased()] = String(text[text.index(after: split)...]).trimmingCharacters(in: .whitespaces)
        }
        return LXSourceMetadata(name: values["name"], version: values["version"], author: values["author"], description: values["description"], homepage: values["homepage"].flatMap(URL.init(string:)))
    }
}
