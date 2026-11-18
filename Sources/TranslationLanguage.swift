import Foundation
import NaturalLanguage

enum TranslationLanguage: String, CaseIterable, Codable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case japanese = "ja"
    case korean = "ko"
    case italian = "it"
    case french = "fr"
    case german = "de"
    case spanish = "es"
    case portuguese = "pt"

    var code: String { rawValue }
    static var supported: [TranslationLanguage] { allCases }

    var englishName: String {
        switch self {
        case .english: return "English"
        case .simplifiedChinese: return "Chinese (Simplified)"
        case .traditionalChinese: return "Chinese (Traditional)"
        case .japanese: return "Japanese"
        case .korean: return "Korean"
        case .italian: return "Italian"
        case .french: return "French"
        case .german: return "German"
        case .spanish: return "Spanish"
        case .portuguese: return "Portuguese"
        }
    }

    var displayName: String {
        switch self {
        case .english: return "영어"
        case .simplifiedChinese: return "중국어(간체)"
        case .traditionalChinese: return "중국어(번체)"
        case .japanese: return "일본어"
        case .korean: return "한국어"
        case .italian: return "이탈리아어"
        case .french: return "프랑스어"
        case .german: return "독일어"
        case .spanish: return "스페인어"
        case .portuguese: return "포르투갈어"
        }
    }

    private var ocrIdentifiers: [String] {
        switch self {
        case .english: return ["en-US", "en-GB"]
        case .simplifiedChinese: return ["zh-Hans"]
        case .traditionalChinese: return ["zh-Hant"]
        case .japanese: return ["ja-JP"]
        case .korean: return ["ko-KR"]
        case .italian: return ["it-IT"]
        case .french: return ["fr-FR"]
        case .german: return ["de-DE"]
        case .spanish: return ["es-ES"]
        case .portuguese: return ["pt-BR", "pt-PT"]
        }
    }

    static func from(code: String) -> TranslationLanguage? {
        let normalized = code.replacingOccurrences(of: "_", with: "-").lowercased()
        if normalized == "zh" || normalized.hasPrefix("zh-hans") || normalized == "zh-cn" || normalized == "zh-sg" {
            return .simplifiedChinese
        }
        if normalized.hasPrefix("zh-hant") || normalized == "zh-tw" || normalized == "zh-hk" || normalized == "zh-mo" {
            return .traditionalChinese
        }
        return supported.first { $0.code.lowercased() == normalized || $0.code == normalized.components(separatedBy: "-")[0] }
    }

    static func recognitionLanguages(supported: [String]) -> [String] {
        // Availability varies by macOS and Vision revision; never request an unsupported OCR language.
        return allCases.compactMap { language in language.ocrIdentifiers.first(where: supported.contains) }
    }
}

enum LanguageDetection {
    static func detect(_ text: String, minimumConfidence: Double = 0.55) -> TranslationLanguage? {
        let source = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let scalars = source.unicodeScalars
        let letters = scalars.filter { CharacterSet.letters.contains($0) }
        guard letters.count >= 2 else { return nil }
        let hasHangul = scalars.contains { (0xAC00...0xD7AF).contains($0.value) || (0x1100...0x11FF).contains($0.value) || (0x3130...0x318F).contains($0.value) }
        let hasHanOrKana = scalars.contains { (0x4E00...0x9FFF).contains($0.value) || (0x3040...0x30FF).contains($0.value) }
        let hasLatin = scalars.contains { (65...90).contains($0.value) || (97...122).contains($0.value) }
        // Korean paragraphs often contain product names. Preserve them when Korean is the target;
        // mixed CJK/Latin sentences otherwise need finer segmentation than this first version offers.
        if hasHangul { return .korean }
        if hasHanOrKana && hasLatin { return nil }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(source)
        let ranked = recognizer.languageHypotheses(withMaximum: 3).sorted { $0.value > $1.value }
        guard let best = ranked.first, best.value >= minimumConfidence,
              best.value - (ranked.dropFirst().first?.value ?? 0) >= 0.15,
              let language = TranslationLanguage.from(code: best.key.rawValue) else { return nil }
        return language
    }
}
