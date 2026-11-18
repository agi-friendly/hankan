import Foundation
import Vision
import CoreGraphics

struct OCRResult {
    let text: String
    let lineCount: Int
}

enum TranslationError: LocalizedError {
    case noText
    case tooMuchText
    case settingsUnavailable
    case invalidPort
    case serverUnavailable
    case unauthorized
    case modelUnavailable(String)
    case serverFailure(Int)
    case incomplete
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .noText:
            return "선택한 영역에서 글자를 찾지 못했어. 글자가 잘 보이도록 영역을 다시 선택해줘."
        case .tooMuchText:
            return "한 번에 번역할 수 있는 범위는 12,000자까지야. 더 작은 영역을 선택해줘."
        case .settingsUnavailable:
            return "oMLX 설정을 읽지 못했어. 이 Mac에 oMLX가 설치되어 있는지 확인해줘."
        case .invalidPort:
            return "oMLX의 연결 포트 설정을 확인해줘."
        case .serverUnavailable:
            return "oMLX에 연결하지 못했어. 서버를 실행한 다음 다시 번역해줘."
        case .unauthorized:
            return "oMLX 인증에 실패했어. 서버와 저장된 인증 설정이 같은지 확인해줘."
        case .modelUnavailable(let model):
            return "번역 모델을 찾지 못했어. oMLX에서 \(model) 모델을 확인해줘."
        case .serverFailure(let status):
            return "oMLX가 요청을 처리하지 못했어 (HTTP \(status)). 서버 상태를 확인하고 다시 시도해줘."
        case .incomplete:
            return "번역이 끝까지 완료되지 않았어. 더 작은 영역으로 다시 시도해줘."
        case .invalidResponse:
            return "oMLX의 응답을 읽지 못했어. 다시 시도해줘."
        }
    }
}

enum TranslationCore {
    private static let chunkLimit = 1800

    static func recognize(_ image: CGImage) throws -> OCRResult {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.customWords = ["AI", "LLM", "API", "Mac", "oMLX", "ChatGPT"]
        request.automaticallyDetectsLanguage = true
        let supported = try request.supportedRecognitionLanguages()
        request.recognitionLanguages = TranslationLanguage.recognitionLanguages(supported: supported)
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])

        let lines = (request.results ?? []).compactMap { observation -> TextLine? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : TextLine(text: text, box: observation.boundingBox)
        }
        guard !lines.isEmpty else { throw TranslationError.noText }

        // Screen text often wraps mid-sentence; retain larger visual gaps as paragraphs.
        let sorted = lines.sorted { $0.box.midY > $1.box.midY }
        var rows: [[TextLine]] = []
        for line in sorted {
            if let last = rows.last, let anchor = last.first,
               abs(anchor.box.midY - line.box.midY) < min(anchor.box.height, line.box.height) * 0.4 {
                rows[rows.count - 1].append(line)
            } else {
                rows.append([line])
            }
        }
        let orderedRows = rows.map { row -> TextLine in
            let ordered = row.sorted { $0.box.minX < $1.box.minX }
            return TextLine(
                text: ordered.map(\.text).joined(separator: " "),
                box: ordered.dropFirst().reduce(ordered[0].box) { $0.union($1.box) }
            )
        }
        var text = ""
        var previous: TextLine?
        for line in orderedRows {
            if let previous = previous {
                let gap = previous.box.minY - line.box.maxY
                let referenceHeight = min(previous.box.height, line.box.height)
                let overlap = max(0, min(previous.box.maxX, line.box.maxX) - max(previous.box.minX, line.box.minX))
                let separatedColumns = overlap < min(previous.box.width, line.box.width) * 0.2
                text += (gap > referenceHeight * 0.65 || separatedColumns) ? "\n\n" : " "
            }
            text += line.text
            previous = line
        }
        return OCRResult(text: text, lineCount: lines.count)
    }

    static func translate(_ text: String, sourceLanguage: TranslationLanguage? = nil,
                          settings: TranslationSettings = .load()) async throws -> String {
        let source = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { throw TranslationError.noText }
        guard source.count <= 12_000 else { throw TranslationError.tooMuchText }
        try Task.checkCancellation()
        let paragraphs = source.components(separatedBy: try NSRegularExpression(pattern: "\\n\\s*\\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let planned = paragraphs.map { paragraph in
            (text: paragraph, language: sourceLanguage ?? LanguageDetection.detect(paragraph))
        }
        // Already-translated and uncertain paragraphs remain readable even if the server is offline.
        guard planned.contains(where: { $0.language != nil && $0.language?.code != settings.targetLanguage.code }) else {
            return paragraphs.joined(separator: "\n\n")
        }
        try settings.validate()
        let connection = try Connection.load(portOverride: settings.localPortOverride)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 180
        configuration.timeoutIntervalForResource = 180
        // Keep OCR text and the existing oMLX credential on the local machine.
        configuration.connectionProxyDictionary = [
            "HTTPEnable": 0,
            "HTTPSEnable": 0,
            "SOCKSEnable": 0,
            "ProxyAutoConfigEnable": 0,
            "ProxyAutoDiscoveryEnable": 0
        ]
        let redirectGuard = LocalOnlySessionDelegate()
        let session = URLSession(configuration: configuration, delegate: redirectGuard, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        var translatedParagraphs: [String] = []
        for paragraph in planned {
            try Task.checkCancellation()
            guard let language = paragraph.language, language.code != settings.targetLanguage.code else {
                translatedParagraphs.append(paragraph.text)
                continue
            }
            var translatedChunks: [String] = []
            for chunk in chunks(paragraph.text) {
                try Task.checkCancellation()
                translatedChunks.append(try await translateChunk(chunk, sourceLanguage: language,
                    settings: settings, connection: connection, session: session))
            }
            translatedParagraphs.append(translatedChunks.joined(separator: " "))
        }
        return translatedParagraphs.joined(separator: "\n\n")
    }

    private struct TextLine {
        let text: String
        let box: CGRect
    }

    private struct Connection {
        let url: URL
        let key: String?

        static func load(portOverride: Int?) throws -> Connection {
            let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".omlx/settings.json")
            guard let data = try? Data(contentsOf: file),
                  let settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw TranslationError.settingsUnavailable
            }
            let server = settings["server"] as? [String: Any]
            let port = portOverride ?? (server?["port"] as? Int) ?? 8000
            guard (1...65535).contains(port),
                  let url = URL(string: "http://127.0.0.1:\(port)/v1/completions") else {
                throw TranslationError.invalidPort
            }
            let auth = settings["auth"] as? [String: Any]
            return Connection(url: url, key: auth?["api_key"] as? String)
        }
    }

    private struct Completion: Decodable {
        struct Choice: Decodable {
            let text: String
            let finish_reason: String?
        }
        let choices: [Choice]
    }

    private static func translateChunk(_ source: String, sourceLanguage: TranslationLanguage,
                                       settings: TranslationSettings, connection: Connection,
                                       session: URLSession) async throws -> String {
        let prompt = TranslateGemmaPrompt.make(source, from: sourceLanguage, to: settings.targetLanguage)
        let payload: [String: Any] = [
            "model": settings.modelID.trimmingCharacters(in: .whitespacesAndNewlines),
            "prompt": prompt,
            "temperature": 0,
            "max_tokens": 2048,
            "stream": false,
            "stop": ["<end_of_turn>", "<eos>"]
        ]
        var request = URLRequest(url: connection.url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = connection.key, !key.isEmpty {
            request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            if error.code == .cancelled || Task.isCancelled { throw CancellationError() }
            throw TranslationError.serverUnavailable
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw TranslationError.invalidResponse }
        switch http.statusCode {
        case 200: break
        case 401, 403: throw TranslationError.unauthorized
        case 404: throw TranslationError.modelUnavailable(settings.modelID)
        default: throw TranslationError.serverFailure(http.statusCode)
        }
        guard let completion = try? JSONDecoder().decode(Completion.self, from: data),
              let choice = completion.choices.first else { throw TranslationError.invalidResponse }
        let translated = choice.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard choice.finish_reason == "stop", !translated.isEmpty else { throw TranslationError.incomplete }
        return translated
    }

    private static func chunks(_ paragraph: String) -> [String] {
        var sentences: [String] = []
        paragraph.enumerateSubstrings(in: paragraph.startIndex..<paragraph.endIndex, options: .bySentences) { _, range, _, _ in
            sentences.append(String(paragraph[range]))
        }
        if sentences.isEmpty { sentences = [paragraph] }
        var result: [String] = []
        var current = ""
        for sentence in sentences {
            let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count <= chunkLimit {
                if !current.isEmpty && current.count + trimmed.count + 1 > chunkLimit {
                    result.append(current)
                    current = ""
                }
                current += (current.isEmpty ? "" : " ") + trimmed
            } else {
                if !current.isEmpty { result.append(current); current = "" }
                var remainder = trimmed
                while remainder.count > chunkLimit {
                    let boundary = remainder.index(remainder.startIndex, offsetBy: chunkLimit)
                    let prefix = remainder[..<boundary]
                    let split = prefix.lastIndex(where: { $0.isWhitespace }) ?? boundary
                    let safeSplit = split == remainder.startIndex ? boundary : split
                    result.append(String(remainder[..<safeSplit]))
                    remainder = String(remainder[safeSplit...]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                current = remainder
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}

actor OCRWorker {
    static let shared = OCRWorker()

    // Vision may compile models on its first run. Serialize it so quick retries
    // cannot pile up expensive OCR work after the user cancels a previous run.
    func recognize(_ image: CGImage) throws -> OCRResult {
        try Task.checkCancellation()
        let result = try TranslationCore.recognize(image)
        try Task.checkCancellation()
        return result
    }

    func analyzeOverlay(_ image: CGImage, targetLanguage: TranslationLanguage = .korean) throws -> OverlayAnalysis {
        try Task.checkCancellation()
        let result = try OverlayLayout.analyze(image, targetLanguage: targetLanguage)
        try Task.checkCancellation()
        return result
    }
}

// Keep the model-family-specific input format separate from OCR and user settings.
private enum TranslateGemmaPrompt {
    static func make(_ text: String, from source: TranslationLanguage, to target: TranslationLanguage) -> String {
        "<start_of_turn>user\n"
            + "You are a professional \(source.englishName) (\(source.code)) to \(target.englishName) (\(target.code)) translator. "
            + "Your goal is to accurately convey the meaning and nuances of the original "
            + "\(source.englishName) text while adhering to \(target.englishName) grammar, vocabulary, and cultural sensitivities.\n"
            + "Produce only the \(target.englishName) translation, without any additional explanations or "
            + "commentary. Please translate the following \(source.englishName) text into \(target.englishName):\n\n\n"
            + text.trimmingCharacters(in: .whitespacesAndNewlines)
            + "<end_of_turn>\n<start_of_turn>model\n"
    }
}

private final class LocalOnlySessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // This endpoint should never redirect; fail closed instead of forwarding source text.
        completionHandler(nil)
    }
}

private extension String {
    func components(separatedBy expression: NSRegularExpression) -> [String] {
        let nsString = self as NSString
        let matches = expression.matches(in: self, range: NSRange(location: 0, length: nsString.length))
        var pieces: [String] = []
        var start = 0
        for match in matches {
            pieces.append(nsString.substring(with: NSRange(location: start, length: match.range.location - start)))
            start = NSMaxRange(match.range)
        }
        pieces.append(nsString.substring(from: start))
        return pieces
    }
}
