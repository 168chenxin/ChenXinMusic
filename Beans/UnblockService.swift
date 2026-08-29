import Foundation

/// 灰色歌曲 / VIP 试听解锁：使用内置第三方音源预设。
/// 由 PlayerManager 在网易云 / QQ 无完整 URL 时自动调用。
enum UnblockService {
    struct Resolved {
        let url: URL
        let source: String

        var sourceTitle: String { source }
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 7
        config.timeoutIntervalForResource = 12
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    private static func get(_ url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 7
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200 else { return nil }
        return data
    }

    /// 入口：并发尝试可用于当前平台的音源，返回第一个可用地址。
    static func resolve(
        name: String,
        artists: String,
        durationMS: Int = 0,
        neteaseID: Int,
        songSource: SongSource = .netease,
        qqMid: String? = nil,
        kugouID: String? = nil,
        strict: Bool = false
    ) async -> Resolved? {
        let hasSongIdentity = !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !artists.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasSongIdentity else { return nil }
        let sourceStore = UnblockSourceStore.shared
        let presetSources = sourceStore.presetSources
            .filter { $0.enabled && canUse(source: $0, songSource: songSource, neteaseID: neteaseID, qqMid: qqMid, kugouID: kugouID) }
        let customSources = sourceStore.customSources
            .filter { $0.enabled && canUse(source: $0, songSource: songSource, neteaseID: neteaseID, qqMid: qqMid, kugouID: kugouID) }
        let lxScripts = sourceStore.lxScripts.filter { !$0.script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !presetSources.isEmpty || !customSources.isEmpty || !lxScripts.isEmpty else { return nil }

        // LX、CR、QT 三个预设最终访问同一个接口，只保留每个请求指纹的第一个，
        // 避免同一首歌重复请求同一个服务，尤其避免酷狗回退时触发请求风暴。
        var seen = Set<String>()
        let uniquePresetSources = presetSources.filter { seen.insert(requestFingerprint(for: $0)).inserted }

        // 慢源/失效源不要拖住播放：全部候选一起请求，最快命中的播放地址直接返回。
        return await withTaskGroup(of: Resolved?.self) { group in
            for source in uniquePresetSources {
                group.addTask {
                    return await presetSourceRequest(
                        source: source,
                        name: name,
                        artists: artists,
                        neteaseID: neteaseID,
                        songSource: songSource,
                        qqMid: qqMid,
                        kugouID: kugouID
                    )
                }
            }
            for source in customSources {
                group.addTask {
                    if source.kind == "lx-script" {
                        return await lxScript(source: source, songSource: songSource, neteaseID: neteaseID, qqMid: qqMid, kugouID: kugouID)
                    }
                    if source.kind == "lx" {
                        let keyword = ([name, artists].filter { !$0.isEmpty }).joined(separator: " ")
                        return await lx(source: source, keyword: keyword)
                    }
                    return await customSourceRequest(
                        source: source,
                        name: name,
                        artists: artists,
                        neteaseID: neteaseID,
                        songSource: songSource,
                        qqMid: qqMid,
                        kugouID: kugouID
                    )
                }
            }
            for source in lxScripts {
                group.addTask {
                    guard let url = await LxScriptRuntime.resolve(
                        source: source,
                        name: name,
                        artists: artists,
                        durationMS: durationMS,
                        neteaseID: neteaseID,
                        qqMid: qqMid,
                        kugouHash: kugouID
                    ) else { return nil }
                    BeansLogger.shared.log("导入 LX 音源命中：\(source.name)", level: .info)
                    return Resolved(url: url, source: source.name)
                }
            }
            for await result in group {
                if let result {
                    group.cancelAll()
                    return result
                }
            }
            return nil
        }
    }

    private static func canUse(source: ThirdPartySource, songSource: SongSource, neteaseID: Int, qqMid: String?, kugouID: String?) -> Bool {
        let expectedProvider = providerCode(for: songSource)
        if let provider = source.headers["source"], !provider.isEmpty, provider != expectedProvider {
            return false
        }
        if songSource == .qq {
            return qqMid?.isEmpty == false
        }
        if songSource == .kugou {
            return kugouID?.isEmpty == false
        }
        return neteaseID > 0
    }

    private static func presetSourceRequest(
        source: ThirdPartySource,
        name: String,
        artists: String,
        neteaseID: Int,
        songSource: SongSource,
        qqMid: String?,
        kugouID: String?
    ) async -> Resolved? {
        guard !source.template.isEmpty else { return nil }
        let expectedProvider = providerCode(for: songSource)
        if let provider = source.headers["source"], !provider.isEmpty, provider != expectedProvider {
            return nil
        }
        let songID: String
        switch songSource {
        case .netease where neteaseID > 0:
            songID = String(neteaseID)
        case .qq:
            guard let qqMid, !qqMid.isEmpty else { return nil }
            songID = qqMid
        case .kugou:
            guard let kugouID, !kugouID.isEmpty else { return nil }
            songID = kugouID
        default:
            return nil
        }
        var urlString = source.template
        urlString = urlString.replacingOccurrences(of: "{id}", with: songID)
        urlString = urlString.replacingOccurrences(of: "{songId}", with: songID)
        urlString = urlString.replacingOccurrences(of: "{songmid}", with: songID)
        urlString = urlString.replacingOccurrences(of: "{mid}", with: songID)
        urlString = urlString.replacingOccurrences(of: "{name}", with: urlEncoded(name))
        let keyword = ([name, artists].filter { !$0.isEmpty }).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        urlString = urlString.replacingOccurrences(of: "{keyword}", with: urlEncoded(keyword))
        urlString = urlString.replacingOccurrences(of: "{artist}", with: urlEncoded(artists))
        let provider = source.headers["source"] ?? expectedProvider
        let quality = source.headers["br"] ?? source.headers["quality"] ?? "999"
        urlString = urlString.replacingOccurrences(of: "{source}", with: provider)
        urlString = urlString.replacingOccurrences(of: "{br}", with: quality)
        urlString = urlString.replacingOccurrences(of: "{quality}", with: quality)
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 7
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("BeansMusic-Preset/1.0", forHTTPHeaderField: "User-Agent")
        if let apiKey = source.headers["apiKey"], !apiKey.isEmpty {
            request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        }
        let metadataKeys: Set<String> = ["source", "quality", "br", "apiKey"]
        for (key, value) in source.headers where !metadataKeys.contains(key) {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            BeansLogger.shared.log("内置音源请求失败：\(source.name) \(error.localizedDescription)", level: .debug)
            return nil
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            BeansLogger.shared.log("内置音源 HTTP 失败：\(source.name) 状态=\(status)", level: .debug)
            return nil
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            BeansLogger.shared.log("内置音源响应格式错误：\(source.name)", level: .debug)
            return nil
        }
        if let code = responseCode(from: obj), code != 200 {
            let message = obj["message"] as? String ?? obj["msg"] as? String ?? "code=\(code)"
            BeansLogger.shared.log("内置音源返回失败：\(source.name) \(message)", level: .debug)
            return nil
        }
        guard let value = valueAtAnyPath(obj, source.urlPath),
              let resolvedURL = value as? String, !resolvedURL.isEmpty,
              let playURL = URL(string: resolvedURL) else {
            BeansLogger.shared.log("内置音源响应中没有播放地址：\(source.name)", level: .debug)
            return nil
        }
        BeansLogger.shared.log("内置音源命中：\(source.name) 平台=\(expectedProvider)", level: .info)
        return Resolved(url: playURL, source: source.name)
    }

    private static func lxScript(source: ThirdPartySource, songSource: SongSource, neteaseID: Int, qqMid: String?, kugouID: String?) async -> Resolved? {
        let provider = source.headers["source"] ?? ""
        let songID: String
        switch (songSource, provider) {
        case (.netease, "wy") where neteaseID > 0:
            songID = String(neteaseID)
        case (.qq, "tx"):
            guard let qqMid, !qqMid.isEmpty else { return nil }
            songID = qqMid
        case (.kugou, "kg"):
            guard let kugouID, !kugouID.isEmpty else { return nil }
            songID = kugouID
        default:
            return nil
        }

        let base = source.template.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let preferred = source.headers["quality"] ?? source.headers["br"] ?? "320k"
        for quality in preferred == "128k" ? ["128k"] : [preferred, "128k"] {
            guard let url = URL(string: "\(base)/url/\(provider)/\(songID)/\(quality)") else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 7
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("lx-music-mobile/1.0", forHTTPHeaderField: "User-Agent")
            if let apiKey = source.headers["apiKey"], !apiKey.isEmpty {
                request.setValue(apiKey, forHTTPHeaderField: "X-Request-Key")
            }
            guard let (data, response) = try? await session.data(for: request),
                  let http = response as? HTTPURLResponse,
                  http.statusCode == 200,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let code = object["code"] as? Int ?? Int(object["code"] as? String ?? "") ?? -1
            guard code == 0,
                  let urlString = object["url"] as? String,
                  !urlString.isEmpty,
                  let playURL = URL(string: urlString) else { continue }
            return Resolved(url: playURL, source: source.name)
        }
        return nil
    }

    private static func customSourceRequest(
        source: ThirdPartySource,
        name: String,
        artists: String,
        neteaseID: Int,
        songSource: SongSource,
        qqMid: String?,
        kugouID: String?
    ) async -> Resolved? {
        guard !source.template.isEmpty else { return nil }
        let expectedProvider = providerCode(for: songSource)
        if let provider = source.headers["source"], !provider.isEmpty, provider != expectedProvider {
            return nil
        }
        let songID: String
        switch songSource {
        case .netease where neteaseID > 0:
            songID = String(neteaseID)
        case .qq:
            guard let qqMid, !qqMid.isEmpty else { return nil }
            songID = qqMid
        case .kugou:
            guard let kugouID, !kugouID.isEmpty else { return nil }
            songID = kugouID
        default:
            return nil
        }
        var urlString = source.template
        urlString = urlString.replacingOccurrences(of: "{id}", with: songID)
        urlString = urlString.replacingOccurrences(of: "{songId}", with: songID)
        urlString = urlString.replacingOccurrences(of: "{songmid}", with: songID)
        urlString = urlString.replacingOccurrences(of: "{mid}", with: songID)
        urlString = urlString.replacingOccurrences(of: "{name}", with: urlEncoded(name))
        let keyword = ([name, artists].filter { !$0.isEmpty }).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        urlString = urlString.replacingOccurrences(of: "{keyword}", with: urlEncoded(keyword))
        urlString = urlString.replacingOccurrences(of: "{artist}", with: urlEncoded(artists))
        let provider = source.headers["source"] ?? expectedProvider
        let quality = source.headers["br"] ?? source.headers["quality"] ?? "999"
        urlString = urlString.replacingOccurrences(of: "{source}", with: provider)
        urlString = urlString.replacingOccurrences(of: "{br}", with: quality)
        urlString = urlString.replacingOccurrences(of: "{quality}", with: quality)
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 7
        let metadataKeys: Set<String> = ["source", "quality", "br", "apiKey"]
        for (key, value) in source.headers where !metadataKeys.contains(key) {
            request.setValue(value, forHTTPHeaderField: key)
        }
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = valueAtAnyPath(object, source.urlPath),
              let urlString = value as? String,
              !urlString.isEmpty,
              let playURL = URL(string: urlString) else { return nil }
        return Resolved(url: playURL, source: source.name)
    }

    private static func requestFingerprint(for source: ThirdPartySource) -> String {
        let headers = source.headers
            .filter { $0.key != "source" }
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "&")
        return "\(source.template)|\(source.urlPath)|\(headers)"
    }

    private static func responseCode(from object: [String: Any]) -> Int? {
        if let code = object["code"] as? Int {
            return code
        }
        if let code = object["code"] as? NSNumber {
            return code.intValue
        }
        if let code = object["code"] as? String {
            return Int(code)
        }
        return nil
    }

    private static func providerCode(for source: SongSource) -> String {
        switch source {
        case .netease: return "wy"
        case .qq: return "tx"
        case .kugou: return "kg"
        case .soda: return "soda"
        }
    }

    // MARK: - 落雪音乐源（lx-music-api-server 风格 HTTP API）
    /// 兼容落雪 API 服务器（如 lx-music-api-server）：先按关键词搜索拿到歌曲 id，
    /// 再请求播放地址。headers 里可配置 source（wy/tx）与 br（默认 320）。
    private static func lx(source: ThirdPartySource, keyword: String) async -> Resolved? {
        guard source.kind == "lx", !source.template.isEmpty else { return nil }
        let base = source.template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let baseURL = URL(string: base) else { return nil }
        let lxSource = normalizedLXSource(source.headers["source"] ?? source.headers["platform"] ?? "wy")
        let br = source.headers["br"] ?? "320"
        // 1) 搜索：落雪 API 使用 keyword，旧服务仍接受 query，因此同时带上。
        var searchComps = URLComponents(url: baseURL.appendingPathComponent("music/search"), resolvingAgainstBaseURL: false)
        searchComps?.queryItems = [
            URLQueryItem(name: "source", value: lxSource),
            URLQueryItem(name: "keyword", value: keyword),
            URLQueryItem(name: "query", value: keyword),
            URLQueryItem(name: "page", value: "1"),
            URLQueryItem(name: "limit", value: "20")
        ]
        guard let searchURL = searchComps?.url, let data = await get(searchURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = lxSearchList(from: obj),
              let first = list.first,
              let id = first["id"] as? String
                  ?? (first["id"] as? Int).map(String.init)
                  ?? first["songmid"] as? String
                  ?? first["mid"] as? String
        else { return nil }
        // 2) 取播放地址：GET /music/url?source=&id=&br=
        var urlComps = URLComponents(url: baseURL.appendingPathComponent("music/url"), resolvingAgainstBaseURL: false)
        urlComps?.queryItems = [
            URLQueryItem(name: "source", value: lxSource),
            URLQueryItem(name: "id", value: id),
            URLQueryItem(name: "br", value: br)
        ]
        guard let urlURL = urlComps?.url, let data2 = await get(urlURL),
              let obj2 = try? JSONSerialization.jsonObject(with: data2) as? [String: Any],
              let urlStr = lxURL(from: obj2), !urlStr.isEmpty,
              let playURL = URL(string: urlStr)
        else { return nil }
        return Resolved(url: playURL, source: "落雪 (\(lxSource))")
    }

    private static func normalizedLXSource(_ value: String) -> String {
        switch value.lowercased() {
        case "netease", "163", "wy": return "wy"
        case "qq", "tencent", "tx": return "tx"
        case "kugou", "kg": return "kg"
        case "kuwo", "kw": return "kw"
        case "migu", "mg": return "mg"
        default: return value
        }
    }

    private static func lxSearchList(from object: [String: Any]) -> [[String: Any]]? {
        if let list = object["data"] as? [[String: Any]] { return list }
        if let data = object["data"] as? [String: Any],
           let list = data["list"] as? [[String: Any]] { return list }
        if let list = object["list"] as? [[String: Any]] { return list }
        if let list = object["results"] as? [[String: Any]] { return list }
        return nil
    }

    private static func lxURL(from object: [String: Any]) -> String? {
        if let url = object["url"] as? String { return url }
        if let data = object["data"] as? [String: Any] {
            return (data["url"] as? String)
                ?? (data["playUrl"] as? String)
                ?? (data["play_url"] as? String)
        }
        return object["data"] as? String
    }

    /// 多个点分路径取值：data.music|data.url|url。
    private static func valueAtAnyPath(_ obj: Any, _ paths: String) -> Any? {
        for path in paths.split(separator: "|") {
            if let value = valueAtPath(obj, String(path)) {
                return value
            }
        }
        return nil
    }

    /// 点分路径取值：url / data.url / data.audioUrl ...
    private static func valueAtPath(_ obj: Any, _ path: String) -> Any? {
        var current: Any = obj
        for key in path.split(separator: ".") {
            guard let dict = current as? [String: Any], let next = dict[String(key)] else { return nil }
            current = next
        }
        return current
    }

    private static func urlEncoded(_ string: String) -> String {
        string.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? string
    }

}
