import Foundation

enum UnblockService {
    struct Resolved {
        let url: URL
        let source: String
        let quality: ThirdPartyAudioQuality

        var sourceTitle: String { source }

        init(url: URL, source: String, quality: ThirdPartyAudioQuality = .kb320) {
            self.url = url
            self.source = source
            self.quality = quality
        }
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
        qqMediaMid: String? = nil,
        kugouID: String? = nil,
        quality: ThirdPartyAudioQuality = .current,
        strict: Bool = false,
        excludedHosts: Set<String> = []
    ) async -> Resolved? {
        let hasSongIdentity = !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !artists.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasSongIdentity else { return nil }
        // Strict songs require title/artist/duration validation; source APIs return URL only.
        guard !strict else { return nil }
        let sourceStore = UnblockSourceStore.shared
        let presetSources = sourceStore.presetSources
            .filter { $0.enabled && canUse(source: $0, songSource: songSource, neteaseID: neteaseID, qqMid: qqMid, kugouID: kugouID) }
        let customSources = sourceStore.customSources
            .filter { $0.enabled && canUse(source: $0, songSource: songSource, neteaseID: neteaseID, qqMid: qqMid, kugouID: kugouID) }
        let lxScripts = sourceStore.lxScripts.filter { !$0.script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !presetSources.isEmpty || !customSources.isEmpty || !lxScripts.isEmpty else { return nil }

        // 相同配置只保留每个请求指纹的第一个，避免重复请求同一个服务。
        var seen = Set<String>()
        let uniquePresetSources = presetSources.filter { seen.insert(requestFingerprint(for: $0)).inserted }

        // 慢源/失效源不要拖住播放：全部候选一起请求，最快命中的播放地址直接返回。
        return await withTaskGroup(of: Resolved?.self) { group in
            for source in uniquePresetSources {
                group.addTask {
                    if isScriptSource(source) {
                        return await scriptSourceRequest(
                            source: source,
                            name: name,
                            artists: artists,
                            neteaseID: neteaseID,
                            songSource: songSource,
                            qqMid: qqMid,
                            qqMediaMid: qqMediaMid,
                            kugouID: kugouID,
                            preferredQuality: quality,
                            excludedHosts: excludedHosts
                        )
                    }
                    return await presetSourceRequest(
                        source: source,
                        name: name,
                        artists: artists,
                        neteaseID: neteaseID,
                        songSource: songSource,
                        qqMid: qqMid,
                        qqMediaMid: qqMediaMid,
                        kugouID: kugouID,
                        preferredQuality: quality,
                        excludedHosts: excludedHosts
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

    private static func isScriptSource(_ source: ThirdPartySource) -> Bool {
        let kind = source.kind.lowercased()
        return kind.contains("script") || source.script?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private static func presetSourceRequest(
        source: ThirdPartySource,
        name: String,
        artists: String,
        neteaseID: Int,
        songSource: SongSource,
        qqMid: String?,
        qqMediaMid: String?,
        kugouID: String?,
        preferredQuality: ThirdPartyAudioQuality,
        excludedHosts: Set<String>
    ) async -> Resolved? {
        guard !source.template.isEmpty else { return nil }
        let expectedProvider = providerCode(for: songSource)
        if let provider = source.headers["source"], !provider.isEmpty, provider != expectedProvider {
            return nil
        }
        let songIDs: [String]
        switch songSource {
        case .netease where neteaseID > 0:
            songIDs = [String(neteaseID)]
        case .qq:
            guard let qqMid, !qqMid.isEmpty else { return nil }
            songIDs = qqIDCandidates(songID: neteaseID, songMid: qqMid, mediaMid: qqMediaMid)
        case .kugou:
            guard let kugouID, !kugouID.isEmpty else { return nil }
            songIDs = [kugouID]
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
        request.setValue("BeansMusic-UserSource/1.0", forHTTPHeaderField: "User-Agent")
        if let apiKey, !apiKey.isEmpty {
            request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        }
        let keyLabel = idLabel + (keyTotal > 1 ? " 密钥=\(keyIndex)/\(keyTotal)" : "") + " 音质=\(quality)"
        let metadataKeys: Set<String> = [
            "source", "quality", "qualities", "qualityOptions", "qualitys",
            "br", "level", "apiKey", "apiKeys", "apiKeyQuery"
        ]
        for (key, value) in source.headers where !metadataKeys.contains(key) {
            let resolvedValue = value
                .replacingOccurrences(of: "{quality}", with: quality)
                .replacingOccurrences(of: "{source}", with: source.headers["source"] ?? "")
            request.setValue(resolvedValue, forHTTPHeaderField: key)
        }
        request.setValue(quality, forHTTPHeaderField: "quality")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            BeansLogger.shared.log("第三方音源请求失败：\(source.name)\(keyLabel) \(error.localizedDescription)", level: .debug)
            return nil
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            BeansLogger.shared.log("第三方音源 HTTP 失败：\(source.name)\(keyLabel) 状态=\(status)", level: .debug)
            return nil
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            BeansLogger.shared.log("第三方音源响应格式错误：\(source.name)\(keyLabel)", level: .debug)
            return nil
        }
        if let code = responseCode(from: obj), code != 0 && code != 200 {
            let message = obj["message"] as? String ?? obj["msg"] as? String ?? "code=\(code)"
            BeansLogger.shared.log("第三方音源返回失败：\(source.name)\(keyLabel) \(message)", level: .debug)
            return nil
        }
        guard let value = valueAtAnyPath(obj, source.urlPath),
              let resolvedURL = value as? String, !resolvedURL.isEmpty,
              let rawPlayURL = URL(string: resolvedURL),
              let playURL = playablePlaybackURL(from: rawPlayURL, source: source, keyLabel: keyLabel, excludedHosts: excludedHosts) else {
            BeansLogger.shared.log("第三方音源响应中没有播放地址：\(source.name)\(keyLabel)", level: .debug)
            return nil
        }
        if rawPlayURL != playURL {
            BeansLogger.shared.log(
                "第三方音源切换 QQ CDN 节点：\(rawPlayURL.host ?? "?") -> \(playURL.host ?? "?")",
                level: .debug
            )
        }
        if let host = playURL.host?.lowercased(), excludedHosts.contains(host) {
            BeansLogger.shared.log(
                "第三方音源跳过已失败节点：\(source.name)\(keyLabel) 域名=\(host)",
                level: .debug
            )
            return nil
        }
        BeansLogger.shared.log("第三方音源命中：\(source.name)\(keyLabel)", level: .info)
        return Resolved(
            url: playURL,
            source: source.name,
            quality: ThirdPartyAudioQuality(sourceValue: quality) ?? .kb320
        )
    }

    /// 部分第三方接口会固定返回不稳定的 QQ CDN 节点。
    /// 不在这里做 Range 探测：部分 QQ CDN 会拒绝探测请求，但 AVPlayer
    /// 带完整请求头后仍可正常播放。实际失败由 AVPlayer 反馈，再换下一个节点。
    private static func playablePlaybackURL(from rawURL: URL, source: ThirdPartySource, keyLabel: String, excludedHosts: Set<String>) -> URL? {
        let candidates = qqPlaybackURLCandidates(for: rawURL)
        for candidate in candidates {
            guard let host = candidate.host?.lowercased() else { continue }
            if excludedHosts.contains(host) {
                BeansLogger.shared.log(
                    "第三方音源跳过已失败节点：\(source.name)\(keyLabel) 域名=\(host)",
                    level: .debug
                )
                continue
            }
            if rawURL != candidate {
                BeansLogger.shared.log(
                    "第三方音源准备 QQ CDN 备用节点：\(rawURL.host ?? "?") -> \(host)",
                    level: .debug
                )
            }
            BeansLogger.shared.log("第三方音源选择播放地址：\(source.name)\(keyLabel) \(safeURLSummary(candidate))", level: .debug)
            return candidate
        }
        return nil
    }

    private static func qqPlaybackURLCandidates(for url: URL) -> [URL] {
        guard let host = url.host?.lowercased(), isQQPlaybackHost(host) else {
            return [url]
        }
        let hosts = [
            host,
            "isure6.ptqqmusic.gitv.tv",
            "isure.stream.qqmusic.qq.com",
            "dl.stream.qqmusic.qq.com",
            "ws.stream.qqmusic.qq.com",
            "streamoc.music.tc.qq.com"
        ]
        var seen = Set<String>()
        return hosts.compactMap { replacement in
            guard seen.insert(replacement).inserted else { return nil }
            return replacingHost(of: url, with: replacement)
        }
    }

    private static func replacingHost(of url: URL, with replacementHost: String) -> URL? {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.host = replacementHost
        return components?.url ?? url
    }

    private static func isQQPlaybackHost(_ host: String) -> Bool {
        host.contains("qq.com") || host.contains("qqmusic") || host.contains("ptqqmusic") || host.contains("gitv.tv")
    }

    private static func replacingQualityPlaceholders(in template: String, with quality: String) -> String {
        ["{quality}", "{br}", "{level}"].reduce(template) { result, placeholder in
            result.replacingOccurrences(of: placeholder, with: quality)
        }
    }

    private static func qualityCandidates(for source: ThirdPartySource, songSource: SongSource, preferredQuality: ThirdPartyAudioQuality) -> [String] {
        let provider = providerCode(for: songSource)
        let supported = Set(UnblockSourceStore.supportedQualities(for: source, providerCode: provider))
        let platformSupported = Set(ThirdPartyAudioQuality.supported(providerCode: provider))
        let sourceDefault = ThirdPartyAudioQuality(sourceValue: source.quality)
        let platformDefault: ThirdPartyAudioQuality = {
            switch songSource {
            case .netease, .qq, .kugou:
                return .kb320
            }
        }()

        var ordered: [ThirdPartyAudioQuality] = []
        ordered.append(contentsOf: preferredQuality.fallbackChain)
        if let sourceDefault, sourceDefault != preferredQuality {
            ordered.append(contentsOf: sourceDefault.fallbackChain)
        }
        if platformDefault != preferredQuality && platformDefault != sourceDefault {
            ordered.append(contentsOf: platformDefault.fallbackChain)
        }

        let filtered = ordered.filter {
            platformSupported.contains($0) && (supported.isEmpty || supported.contains($0))
        }
        var seen = Set<String>()
        let result = filtered.compactMap { quality -> String? in
            let trimmed = quality.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty || !seen.insert(trimmed).inserted ? nil : trimmed
        }
        if !result.isEmpty { return result }

        // 若源只声明了非标准档位，至少尝试它声明过的档位，不能越过能力表强行请求未知音质。
        if !supported.isEmpty {
            return UnblockSourceStore
                .supportedQualities(for: source, providerCode: provider)
                .map(\.rawValue)
        }

        var fallbackSeen = Set<String>()
        return ordered.compactMap { quality -> String? in
            let trimmed = quality.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty || !fallbackSeen.insert(trimmed).inserted ? nil : trimmed
        }
    }

    private static func qqIDCandidates(songID: Int, songMid: String, mediaMid: String?) -> [String] {
        var seen = Set<String>()
        let numericID = songID > 0 ? String(songID) : nil
        return [numericID, mediaMid, songMid].compactMap { raw in
            guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty,
                  seen.insert(value).inserted else { return nil }
            return value
        }
    }

    private static func safeURLSummary(_ url: URL) -> String {
        let host = url.host ?? "?"
        let path = url.path.isEmpty ? "/" : url.path
        let shortPath = path.count > 72 ? String(path.prefix(72)) + "..." : path
        return "\(host)\(shortPath)"
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
        let scriptFingerprint = source.script?.hashValue.description ?? ""
        return "\(source.template)|\(source.urlPath)|\(headers)|\(source.quality)|\(scriptFingerprint)"
    }

    private static func sourceAPIKeys(for source: ThirdPartySource) -> [String] {
        var keys: [String] = []
        if let raw = source.headers["apiKeys"], !raw.isEmpty {
            keys.append(contentsOf: raw
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty })
        }
        if let raw = source.headers["apiKey"]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            keys.append(raw)
        }
        var seen = Set<String>()
        return keys.filter { seen.insert($0).inserted }
    }

    private static func orderedAPIKeys(for source: ThirdPartySource) -> [(Int, String)] {
        let keys = sourceAPIKeys(for: source)
        var seen = Set<String>()
        let unique = keys.enumerated().compactMap { index, key -> (Int, String)? in
            seen.insert(key).inserted ? (index, key) : nil
        }
        let preferred = UserDefaults.standard.integer(forKey: preferredKeyIndexDefaultsKey(for: source))
        guard let hit = unique.firstIndex(where: { $0.0 == preferred }), hit > 0 else {
            return unique
        }
        var reordered = unique
        let item = reordered.remove(at: hit)
        reordered.insert(item, at: 0)
        return reordered
    }

    private static func rememberWorkingKey(_ index: Int, for source: ThirdPartySource) {
        UserDefaults.standard.set(index, forKey: preferredKeyIndexDefaultsKey(for: source))
    }

    private static func preferredKeyIndexDefaultsKey(for source: ThirdPartySource) -> String {
        "beans.unblock.preferredKeyIndex.\(source.id)"
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
            if let dict = current as? [String: Any], let next = dict[String(key)] {
                current = next
            } else if let dict = current as? NSDictionary, let next = dict[String(key)] {
                current = next
            } else {
                return nil
            }
        }
        return current
    }

    private static func urlEncoded(_ string: String) -> String {
        string.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? string
    }

}
