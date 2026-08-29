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
    var enabled: Bool = true
    var isPreset: Bool = false

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
        enabled: Bool = true,
        isPreset: Bool = false
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.template = template
        self.urlPath = urlPath
        self.headers = headers
        self.enabled = enabled
        self.isPreset = isPreset
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
        isPreset = try container.decodeIfPresent(Bool.self, forKey: .isPreset) ?? false
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
                seeded.append(preset)
            }
        }
        return seeded
    }
}
