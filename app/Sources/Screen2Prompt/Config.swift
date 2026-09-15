import Foundation
import Security

/// ~/.screen2prompt/config.json — edit it by hand, it is three fields.
struct Config: Codable {
    var provider: String = "apple"         // apple | groq | whisper
    var locale: String = "en-US"
    var groqModel: String = "whisper-large-v3-turbo"
    var whisperBinary: String = "/opt/homebrew/bin/whisper-cli"
    var whisperModel: String = ""          // e.g. ~/models/ggml-base.en.bin
    var tailSeconds: Double = 5

    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".screen2prompt/config.json")
    }

    static func load() -> Config {
        guard let d = try? Data(contentsOf: url),
              let c = try? JSONDecoder().decode(Config.self, from: d) else { return Config() }
        return c
    }

    func save() {
        try? FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(self).write(to: Self.url)
    }
}

/// The Groq key lives in the login keychain, never in config.json and never in a log.
/// GROQ_API_KEY in the environment wins, so CI and one-off runs need no keychain entry.
enum Keychain {
    private static let service = "co.ema.screen2prompt"
    private static let account = "groq-api-key"

    static func groqKey() -> String? {
        if let env = ProcessInfo.processInfo.environment["GROQ_API_KEY"], !env.isEmpty { return env }
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    @discardableResult
    static func setGroqKey(_ key: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = key.data(using: .utf8)
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}
