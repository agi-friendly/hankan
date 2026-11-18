import Foundation

struct TranslationSettings {
    static let defaultModelID = "mlx-community--translategemma-4b-it-4bit"
    private static let storageKey = "translationSettings"

    var modelID: String = defaultModelID
    var targetLanguage: TranslationLanguage = .korean
    var localPortOverride: Int? = nil

    static func load(from defaults: UserDefaults = .standard) -> TranslationSettings {
        let stored = defaults.dictionary(forKey: storageKey) ?? [:]
        return TranslationSettings(
            modelID: stored["modelID"] as? String ?? defaultModelID,
            targetLanguage: TranslationLanguage.from(code: stored["targetLanguageCode"] as? String ?? "ko") ?? .korean,
            localPortOverride: stored["localPortOverride"] as? Int
        )
    }

    func save(to defaults: UserDefaults = .standard) throws {
        try validate()
        // Keep user choices together, but leave the server credential in oMLX's own storage.
        var stored: [String: Any] = [
            "modelID": modelID.trimmingCharacters(in: .whitespacesAndNewlines),
            "targetLanguageCode": targetLanguage.code
        ]
        if let port = localPortOverride { stored["localPortOverride"] = port }
        defaults.set(stored, forKey: Self.storageKey)
    }

    func validate() throws {
        let model = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty, model.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw TranslationSettingsError.invalidModel
        }
        if let port = localPortOverride, !(1...65535).contains(port) {
            throw TranslationSettingsError.invalidPort
        }
    }
}

enum TranslationSettingsError: LocalizedError {
    case invalidModel, invalidPort

    var errorDescription: String? {
        switch self {
        case .invalidModel: return "번역에 사용할 모델 이름을 확인해줘."
        case .invalidPort: return "로컬 번역 서버의 포트는 1부터 65535 사이여야 해."
        }
    }
}
