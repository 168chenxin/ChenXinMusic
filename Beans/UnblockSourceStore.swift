import Foundation

private struct FlexibleString: Decodable {
    let value: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self.value = value
        } else if let value = try? container.decode(Int.self) {
            self.value = String(value)
        } else if let value = try? container.decode(Double.self) {
            self.value = String(value)
        } else if let value = try? container.decode(Bool.self) {
            self.value = String(value)
        } else {
            throw DecodingError.typeMismatch(String.self, .init(codingPath: decoder.codingPath, debugDescription: "Expected a scalar value"))
        }
    }
}

/// 第三方解锁源。支持内置预设与用户导入的 JSON / 落雪 API 源。
struct ThirdPartySource: Identifiable, Codable, Hashable, Sendable {
    var id = UUID().uuidString
    var name: String
    var kind: String = "keyword"
    var template: String
    var urlPath: String = "url"
    var headers: [String: String] = [:]
    var quality: String = "320k"
    var script: String?
    var enabled: Bool = true

    enum CodingKeys: String, CodingKey {
        case id, name, title, kind, type, mode, template, url, api, endpoint, baseURL, baseUrl
        case urlPath, path, responsePath, resultPath, headers, enabled, isPreset
    }

    init(
        id: String = UUID().uuidString,
        name: String,
        kind: String = "keyword",
        template: String,
        urlPath: String = "url",
        headers: [String: String] = [:],
        quality: String = "320k",
        script: String? = nil,
        enabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.template = template
        self.urlPath = urlPath
        self.headers = headers
        self.quality = quality
        self.script = script
        self.enabled = enabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func firstString(_ keys: [CodingKeys]) throws -> String? {
            for key in keys {
                if let value = try container.decodeIfPresent(String.self, forKey: key) {
                    return value
                }
            }
            return nil
        }
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try firstString([.name, .title]) ?? "未命名音源"
        kind = try firstString([.kind, .type, .mode]) ?? "keyword"
        template = try firstString([.template, .url, .api, .endpoint, .baseURL, .baseUrl]) ?? ""
        urlPath = try firstString([.urlPath, .path, .responsePath, .resultPath]) ?? "url"
        if let decoded = try? container.decode([String: String].self, forKey: .headers) {
            headers = decoded
        } else if let decoded = try? container.decode([String: FlexibleString].self, forKey: .headers) {
            headers = decoded.mapValues(\.value)
        } else {
            headers = [:]
        }
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(kind, forKey: .kind)
        try container.encode(template, forKey: .template)
        try container.encode(urlPath, forKey: .urlPath)
        try container.encode(headers, forKey: .headers)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(isPreset, forKey: .isPreset)
    }
}

/// 用户导入的落雪 LX JavaScript 音源。
struct LxScriptSource: Identifiable, Codable, Hashable, Sendable {
    var id = UUID().uuidString
    var name: String
    var script: String

    init(id: String = UUID().uuidString, name: String, script: String) {
        self.id = id
        self.name = name
        self.script = script
    }
}

final class UnblockSourceStore: ObservableObject {
    static let shared = UnblockSourceStore()

    static let guoyuePresetSources: [ThirdPartySource] = [
        ThirdPartySource(
            name: "guoyue2010 · QQ 稳定源",
            kind: "template-api",
            template: "https://cyapi.top/API/qq_music.php?apikey=1ffdf5733f5d538760e63d7e46ba17438d9f7b9dfc18c51be1109386fd74c3a1&type=json&mid={id}",
            urlPath: "url",
            headers: ["source": "tx"]
        ),
        ThirdPartySource(
            name: "guoyue2010 · 网易云统一源",
            kind: "template-api",
            template: "https://music-api.gdstudio.xyz/api.php?types=url&source=netease&id={id}&br=999",
            urlPath: "url",
            headers: ["source": "wy"]
        ),
    ]

    private static let paidAPIURL = "https://source.shiqianjiang.cn/api/music"
    private static let paidAPIKey = "CERU_KEY-51440644-C9AD-4E10-B593-258FF59CF259"
    private static let paidURLTemplate = "\(paidAPIURL)/url?source={source}&songId={id}&quality={quality}"

    static let paidPresetSources: [ThirdPartySource] = [
        ThirdPartySource(
            id: "beans.preset.shiqianjiang.lx.v7",
            name: "聆澜音源 · LX",
            kind: "paid-lx",
            template: paidURLTemplate,
            headers: ["apiKey": paidAPIKey, "quality": "320k"],
            isPreset: true
        ),
        ThirdPartySource(
            id: "beans.preset.shiqianjiang.cr.v7",
            name: "聆澜音源 · CR",
            kind: "paid-cr",
            template: paidURLTemplate,
            headers: ["apiKey": paidAPIKey, "quality": "320k"],
            isPreset: true
        ),
        ThirdPartySource(
            id: "beans.preset.shiqianjiang.qt.v7",
            name: "聆澜音源 · QT",
            kind: "paid-qt",
            template: paidURLTemplate,
            headers: ["apiKey": paidAPIKey, "quality": "320k"],
            isPreset: true
        ),
    ]

    @Published var presetSources: [ThirdPartySource] {
        didSet { savePresets() }
    }

    @Published var customSources: [ThirdPartySource] {
        didSet { saveCustomSources() }
    }

    @Published var lxScripts: [LxScriptSource] {
        didSet { saveLxScripts() }
    }

    var managementVisibleSources: [ThirdPartySource] {
        sources
    }

    private let defaults = UserDefaults.standard
    private let presetsKey = "beans.unblock.presets"
    private let customKey = "beans.unblock.custom"
    private let lxScriptsKey = "beans.unblock.lxScripts"

    private init() {
        let storedPresets = Self.loadSources(defaults.data(forKey: presetsKey))
        let storedCustom = Self.loadSources(defaults.data(forKey: customKey))
        presetSources = Self.seedPaidPresets(into: storedPresets.filter(\.isPreset))
        customSources = (storedCustom.isEmpty ? storedPresets : storedCustom).filter { !$0.isPreset }
        if let data = defaults.data(forKey: lxScriptsKey),
           let saved = try? JSONDecoder().decode([LxScriptSource].self, from: data) {
            lxScripts = saved
        } else {
            lxScripts = []
        }
        savePresets()
        saveCustomSources()
    }

    func add(_ source: ThirdPartySource) {
        if let index = customSources.firstIndex(where: {
            $0.kind == source.kind && $0.template == source.template && $0.headers["source"] == source.headers["source"]
        }) {
            var updated = source
            updated.id = customSources[index].id
            customSources[index] = updated
        } else {
            customSources.insert(source, at: 0)
        }
    }

    func remove(_ source: ThirdPartySource) {
        customSources.removeAll { $0.id == source.id }
    }

    func addLxScript(_ source: LxScriptSource) {
        lxScripts.removeAll { $0.name == source.name }
        lxScripts.append(source)
    }

    func removeLxScript(_ source: LxScriptSource) {
        lxScripts.removeAll { $0.id == source.id }
    }

    private static func loadSources(_ data: Data?) -> [ThirdPartySource] {
        guard let data else { return [] }
        return (try? JSONDecoder().decode([ThirdPartySource].self, from: data)) ?? []
    }

    private func savePresets() {
        if let data = try? JSONEncoder().encode(presetSources) {
            defaults.set(data, forKey: presetsKey)
        }
    }

    private func saveCustomSources() {
        if let data = try? JSONEncoder().encode(customSources) {
            defaults.set(data, forKey: customKey)
        }
    }

    private func saveLxScripts() {
        if let data = try? JSONEncoder().encode(lxScripts) {
            defaults.set(data, forKey: lxScriptsKey)
        }
    }

    private static func seedPaidPresets(into savedSources: [ThirdPartySource]) -> [ThirdPartySource] {
        var seeded = savedSources
        for preset in paidPresetSources {
            if let index = seeded.firstIndex(where: { $0.id == preset.id }) {
                var updated = preset
                updated.enabled = seeded[index].enabled
                seeded[index] = updated
            } else {
                merged.append(source)
            }
        }
        sources = merged
        save()
    }

    func upsert(_ source: ThirdPartySource) {
        var merged = sources
        if let index = merged.firstIndex(where: { $0.id == source.id }) {
            merged[index] = source
        } else {
            merged.append(source)
        }
        sources = merged
        save()
    }

    func moveSource(id: String, by offset: Int) {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        let target = min(max(0, index + offset), max(0, sources.count - 1))
        guard target != index else { return }
        var reordered = sources
        let item = reordered.remove(at: index)
        reordered.insert(item, at: target)
        sources = reordered
        save()
    }

    func moveManagementSource(id: String, by offset: Int) {
        let visibleIDs = managementVisibleSources.map(\.id)
        guard let visibleIndex = visibleIDs.firstIndex(of: id) else { return }
        let targetVisibleIndex = visibleIndex + offset
        guard visibleIDs.indices.contains(targetVisibleIndex) else { return }
        let targetID = visibleIDs[targetVisibleIndex]
        guard let sourceIndex = sources.firstIndex(where: { $0.id == id }) else { return }

        var reordered = sources
        let item = reordered.remove(at: sourceIndex)
        guard let adjustedTargetIndex = reordered.firstIndex(where: { $0.id == targetID }) else { return }
        let insertionIndex = targetVisibleIndex > visibleIndex
            ? adjustedTargetIndex + 1
            : adjustedTargetIndex
        reordered.insert(item, at: min(insertionIndex, reordered.count))
        sources = reordered
        save()
    }

    func updateEnabled(id: String, enabled: Bool) {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        var updated = sources
        updated[index].enabled = enabled
        sources = updated
        save()
    }

    @discardableResult
    func removeSource(id: String) -> Bool {
        let originalCount = sources.count
        sources.removeAll { $0.id == id }
        save()
        return sources.count != originalCount
    }

}

extension UnblockSourceStore {
    func availableThirdPartyQualities() -> [ThirdPartyAudioQuality] {
        let options = sources
            .filter(\.enabled)
            .flatMap { Self.supportedQualities(for: $0) }
            .uniquePreservingOrder()
        return options.isEmpty ? ThirdPartyAudioQuality.allCases : options
    }

    static func supportedQualities(
        for source: ThirdPartySource,
        providerCode: String? = nil
    ) -> [ThirdPartyAudioQuality] {
        let explicit = explicitQualities(
            from: source.headers["qualities"] ?? source.headers["qualityOptions"] ?? source.headers["qualitys"]
        )
        if !explicit.isEmpty {
            if let providerCode {
                let platform = Set(ThirdPartyAudioQuality.supported(providerCode: providerCode))
                return explicit.filter { platform.contains($0) }
            }
            return explicit
        }

        if let script = source.script,
           let explicit = scriptQualities(from: script),
           !explicit.isEmpty {
            if let providerCode {
                let platform = Set(ThirdPartyAudioQuality.supported(providerCode: providerCode))
                return explicit.filter { platform.contains($0) }
            }
            return explicit
        }

        if let providerCode {
            return ThirdPartyAudioQuality.supported(providerCode: providerCode)
        }

        if let sourceProvider = source.headers["source"] ?? source.headers["platform"] {
            return ThirdPartyAudioQuality.supported(providerCode: sourceProvider)
        }

        return ThirdPartyAudioQuality.allCases
    }

    private static func explicitQualities(from raw: String?) -> [ThirdPartyAudioQuality] {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return [] }
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;|/[]\"'"))
        return raw
            .components(separatedBy: separators)
            .compactMap { ThirdPartyAudioQuality(sourceValue: $0) }
            .uniquePreservingOrder()
    }

    private static func scriptQualities(from script: String) -> [ThirdPartyAudioQuality]? {
        let pattern = #"(?i)(?:qualitys?|qualityOptions)\s*[:=]\s*\[([^\]]*)\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: script,
                options: [],
                range: NSRange(script.startIndex..<script.endIndex, in: script)
              ),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: script) else {
            return nil
        }
        return explicitQualities(from: String(script[range]))
    }
}

private extension Array where Element: Hashable {
    func uniquePreservingOrder() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
