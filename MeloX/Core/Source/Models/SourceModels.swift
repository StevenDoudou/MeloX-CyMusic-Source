import Foundation

struct MeloXSource: Codable, Identifiable, Sendable, Equatable {
    let id: String
    var name: String
    var author: String
    var version: String
    var script: String
    var sourceURL: URL?
    var enabled: Bool
    var updatedAt: Date
}

struct MeloXSourceTrack: Codable, Sendable, Equatable {
    var url: URL
    var bitrate: Int?
    var format: String?
    var lyric: String?
    var artwork: URL?
}

enum MeloXSourceError: LocalizedError {
    case emptyScript, runtimeUnavailable, invalidResult, requestFailed, unsupportedLXScript
    var errorDescription: String? {
        switch self {
        case .emptyScript: return "音源脚本为空"
        case .runtimeUnavailable: return "音源运行环境不可用"
        case .invalidResult: return "音源返回结果无效"
        case .requestFailed: return "音源请求失败"
        case .unsupportedLXScript: return "当前版本暂不支持异步 LX 音源协议，请使用 CyMusic 原生 getMusicUrl 格式"
        }
    }
}
