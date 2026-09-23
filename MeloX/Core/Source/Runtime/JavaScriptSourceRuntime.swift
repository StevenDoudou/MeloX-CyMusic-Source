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

final class JavaScriptSourceRuntime {
    typealias EventHandler = (_ event: String, _ payload: Any?) -> Void
    typealias HTTPHandler = (_ request: URLRequest, _ completion: @escaping (Result<LXHTTPResponse, Error>) -> Void) -> URLSessionDataTask?

    struct Configuration {
        var timeout: TimeInterval = 15
        var session: URLSession = .shared
        var eventHandler: EventHandler?
        var httpHandler: HTTPHandler?
    }

    struct LXHTTPResponse: Sendable {
        let statusCode: Int
        let headers: [String: String]
        let body: String
        let data: Data
    }

    private(set) var metadata = LXSourceMetadata(name: nil, version: nil, author: nil, description: nil, homepage: nil)
    private let configuration: Configuration
    #if canImport(JavaScriptCore)
    private let context: JSContext
    private var handlers: [String: [JSValue]] = [:]
    private var tasks: [String: URLSessionDataTask] = [:]
    private var generation = 0
    private let queue = DispatchQueue(label: "me.melox.lx-runtime")
    #endif

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        #if canImport(JavaScriptCore)
        context = JSContext()!
        installBridge()
        #endif
    }

    func invalidate() {
        #if canImport(JavaScriptCore)
        queue.sync {
            generation += 1
            tasks.values.forEach { $0.cancel() }
            tasks.removeAll()
            handlers.removeAll()
        }
        #endif
    }

    func load(script: String) throws {
        guard !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MeloXSourceError.emptyScript }
        metadata = Self.parseMetadata(script)
        #if canImport(JavaScriptCore)
        try evaluate("(function(){var module={exports:{}};var exports=module.exports;\(script);return module.exports;})()")
        #else
        throw MeloXSourceError.runtimeUnavailable
        #endif
    }

    /// Resolves an LX source by dispatching the protocol's request event.
    func resolve(script: String, songName: String, artist: String, quality: String) throws -> MeloXSourceTrack {
        #if canImport(JavaScriptCore)
        try load(script: script)
        let payload: [String: Any] = ["action": "musicUrl", "info": ["songname": songName, "artist": artist, "songmid": "", "quality": quality]]
        let result = try requestEventSync(name: "request", payload: payload)
        guard let value = result as? [String: Any] else { throw MeloXSourceError.invalidResult }
        let raw = (value["url"] as? String) ?? (value["src"] as? String)
        guard let raw, let url = URL(string: raw) else { throw MeloXSourceError.invalidResult }
        return MeloXSourceTrack(url: url, bitrate: value["bitrate"] as? Int, format: value["format"] as? String, lyric: value["lyric"] as? String, artwork: (value["pic"] as? String).flatMap(URL.init(string:)))
        #else
        throw MeloXSourceError.runtimeUnavailable
        #endif
    }

    #if canImport(JavaScriptCore)
    private func installBridge() {
        let lx = JSValue(newObjectIn: context)!
        let names = JSValue(newObjectIn: context)!
        names.setValue("request", forProperty: "request")
        names.setValue("inited", forProperty: "inited")
        lx.setValue(names, forProperty: "EVENT_NAMES")
        let on: @convention(block) (String, JSValue) -> Void = { [weak self] name, callback in self?.queue.async { self?.handlers[name, default: []].append(callback) } }
        let send: @convention(block) (String, JSValue) -> Void = { [weak self] name, payload in self?.configuration.eventHandler?(name, payload.isUndefined ? nil : payload.toObject()) }
        let abort: @convention(block) (String) -> Void = { [weak self] id in self?.queue.async { self?.tasks.removeValue(forKey: id)?.cancel() } }
        let request: @convention(block) (JSValue, JSValue, JSValue) -> JSValue = { [weak self] target, options, callback in
            guard let self else { return JSValue(undefinedIn: options.context) }
            return self.startRequest(target: target, options: options, callback: callback)
        }
        lx.setValue(on, forProperty: "on"); lx.setValue(send, forProperty: "send"); lx.setValue(request, forProperty: "request"); lx.setValue(abort, forProperty: "abort")
        context.setObject(lx, forKeyedSubscript: "lx" as NSString)
        let crypto = JSValue(newObjectIn: context)!
        let md5: @convention(block) (String) -> String = { Self.digest($0, kind: .md5) }
        let sha1: @convention(block) (String) -> String = { Self.digest($0, kind: .sha1) }
        let b64e: @convention(block) (String) -> String = { Data($0.utf8).base64EncodedString() }
        let b64d: @convention(block) (String) -> String = { String(data: Data(base64Encoded: $0) ?? Data(), encoding: .utf8) ?? "" }
        crypto.setValue(md5, forProperty: "md5"); crypto.setValue(sha1, forProperty: "sha1"); crypto.setValue(b64e, forProperty: "base64Encode"); crypto.setValue(b64d, forProperty: "base64Decode")
        lx.setValue(crypto, forProperty: "crypto")
        context.exceptionHandler = { _, exception in _ = exception }
    }

    private func evaluate(_ source: String) throws -> JSValue {
        guard let value = context.evaluateScript(source), !value.isUndefined else { throw MeloXSourceError.invalidResult }
        if context.exception != nil { throw MeloXSourceError.invalidResult }
        return value
    }

    private func requestEventSync(name: String, payload: [String: Any]) throws -> Any? {
        guard let callbacks = handlers[name], !callbacks.isEmpty else { throw MeloXSourceError.invalidResult }
        let object = try JSValue(object: payload, in: context)
        let callback = callbacks.last!
        let result = callback.call(withArguments: [object as Any])
        if result?.isObject == true { return result?.toObject() }
        return result?.toObject()
    }

    private func startRequest(target: JSValue, options: JSValue, callback: JSValue) -> JSValue {
        let promise = JSValue(newPromiseIn: context) { [weak self] resolve, reject in
            guard let self else { return }
            self.performRequest(target: target, options: options, callback: callback, resolve: resolve, reject: reject)
        }
        return promise
    }

    private func performRequest(target: JSValue, options: JSValue, callback: JSValue, resolve: JSValue, reject: JSValue) {
        let urlString = target.isString ? target.toString()! : (target.objectForKeyedSubscript("url")?.toString() ?? "")
        guard let url = URL(string: urlString) else { reject.call(withArguments: ["Invalid URL"]); return }
        var request = URLRequest(url: url)
        let object = target.isString ? options : target
        if let method = object.objectForKeyedSubscript("method")?.toString(), !method.isEmpty { request.httpMethod = method }
        if let headers = object.objectForKeyedSubscript("headers")?.toObject() as? [String: Any] { headers.forEach { request.setValue(String(describing: $0.value), forHTTPHeaderField: $0.key) } }
        if let body = object.objectForKeyedSubscript("body")?.toString() { request.httpBody = body.data(using: .utf8) }
        let id = UUID().uuidString; let startGeneration = generation
        let timeout = object.objectForKeyedSubscript("timeout")?.toDouble() ?? configuration.timeout
        request.timeoutInterval = timeout
        let handler = configuration.httpHandler ?? defaultHTTP
        let task = handler(request) { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard startGeneration == self.generation else { return }
                self.tasks.removeValue(forKey: id)
                switch result {
                case .success(let response):
                    let value: [String: Any] = ["status": response.statusCode, "headers": response.headers, "body": response.body, "data": response.body]
                    resolve.call(withArguments: [value]); if !callback.isUndefined { callback.call(withArguments: [NSNull(), value]) }
                case .failure(let error):
                    reject.call(withArguments: [error.localizedDescription]); if !callback.isUndefined { callback.call(withArguments: [error.localizedDescription, NSNull()]) }
                }
            }
        }
        if let task { queue.async { self.tasks[id] = task } }
    }

    private var defaultHTTP: HTTPHandler { { request, completion in
        let task = configuration.session.dataTask(with: request) { data, response, error in
            if let error { completion(.failure(error)); return }
            guard let http = response as? HTTPURLResponse, let data else { completion(.failure(MeloXSourceError.requestFailed)); return }
            let headers = http.allHeaderFields.reduce(into: [String: String]()) { $0[String(describing: $1.key)] = String(describing: $1.value) }
            completion(.success(LXHTTPResponse(statusCode: http.statusCode, headers: headers, body: String(data: data, encoding: .utf8) ?? "", data: data)))
        }; task.resume(); return task
    } }

    private enum DigestKind { case md5, sha1 }
    private static func digest(_ string: String, kind: DigestKind) -> String {
        let data = Data(string.utf8)
        var bytes = [UInt8](repeating: 0, count: kind == .md5 ? Int(CC_MD5_DIGEST_LENGTH) : Int(CC_SHA1_DIGEST_LENGTH))
        data.withUnsafeBytes { ptr in
            if kind == .md5 { _ = CC_MD5(ptr.baseAddress, CC_LONG(data.count), &bytes) }
            else { _ = CC_SHA1(ptr.baseAddress, CC_LONG(data.count), &bytes) }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
    #endif

    private static func parseMetadata(_ script: String) -> LXSourceMetadata {
        var values = [String: String]()
        for line in script.components(separatedBy: .newlines) {
            let clean = line.trimmingCharacters(in: .whitespaces)
            guard clean.hasPrefix("//") else { continue }
            let text = clean.dropFirst(2).trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("@"), let split = text.firstIndex(of: " ") else { continue }
            values[String(text[text.index(after: text.startIndex)..<split]).lowercased()] = String(text[text.index(after: split)...]).trimmingCharacters(in: .whitespaces)
        }
        return LXSourceMetadata(name: values["name"], version: values["version"], author: values["author"], description: values["description"], homepage: values["homepage"].flatMap(URL.init(string:)))
    }
}
