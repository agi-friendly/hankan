import Foundation
import CoreGraphics
import NaturalLanguage
import Vision

struct OverlayParagraph {
    let id: Int
    let source: String
    let sourceLanguage: TranslationLanguage
    // Original image pixels, with the origin at the top-left corner.
    let bounds: CGRect
    let lineBounds: [CGRect]
}

struct OverlayAnalysis {
    let paragraphs: [OverlayParagraph]
    let recognizedLineCount: Int
}

enum OverlayLayout {
    private struct Line {
        let text: String
        let box: CGRect
        let confidence: Float
        let angle: CGFloat
    }

    static func analyze(_ image: CGImage, targetLanguage: TranslationLanguage = .korean) throws -> OverlayAnalysis {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        request.customWords = ["AI", "LLM", "API", "Mac", "oMLX", "ChatGPT"]
        let supported = try request.supportedRecognitionLanguages()
        request.recognitionLanguages = TranslationLanguage.recognitionLanguages(supported: supported)
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])

        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let lines = (request.results ?? []).compactMap { observation -> Line? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let normalized = observation.boundingBox
            let box = CGRect(x: normalized.minX * width, y: (1 - normalized.maxY) * height,
                             width: normalized.width * width, height: normalized.height * height)
            let dx = (observation.topRight.x - observation.topLeft.x) * width
            let dy = (observation.topRight.y - observation.topLeft.y) * height
            let angle = atan2(dy, dx) * 180 / .pi
            return Line(text: text, box: box, confidence: candidate.confidence, angle: angle)
        }

        // X usually places the author's name and handle in separate OCR boxes.
        // A handle/timestamp marks only its nearby row, not the comment underneath.
        let metadata = lines.filter { isMetadata($0.text) }
        let retained = lines.filter { line in
            guard abs(line.angle) <= 8, line.confidence >= 0.4,
                  hasUsefulLetters(line.text), !isMetadata(line.text) else { return false }
            return !metadata.contains { marker in
                let rowTolerance = min(marker.box.height, line.box.height) * 0.5
                let horizontalGap = max(0, max(marker.box.minX - line.box.maxX, line.box.minX - marker.box.maxX))
                return abs(marker.box.midY - line.box.midY) <= rowTolerance
                    && horizontalGap < max(marker.box.height, line.box.height) * 8
            }
        }
        let rows = mergeAdjacentFragments(retained)
        var groups: [[Line]] = []
        for row in rows {
            let candidate = groups.indices.filter { canAppend(row, to: groups[$0]) }
                .min { row.box.minY - groups[$0].last!.box.maxY < row.box.minY - groups[$1].last!.box.maxY }
            if let candidate = candidate {
                groups[candidate].append(row)
            } else {
                groups.append([row])
            }
        }
        let ordered = groups.sorted { first, second in
            let a = first[0].box, b = second[0].box
            return abs(a.minY - b.minY) > min(a.height, b.height) * 0.4 ? a.minY < b.minY : a.minX < b.minX
        }
        var paragraphs: [OverlayParagraph] = []
        for group in ordered {
            let text = group.map(\.text).joined(separator: " ")
            guard let language = LanguageDetection.detect(text), language != targetLanguage else { continue }
            let bounds = group.dropFirst().reduce(group[0].box) { $0.union($1.box) }
            paragraphs.append(OverlayParagraph(id: paragraphs.count, source: text, sourceLanguage: language,
                                               bounds: bounds, lineBounds: group.map(\.box)))
        }
        return OverlayAnalysis(paragraphs: paragraphs, recognizedLineCount: lines.count)
    }

    private static func mergeAdjacentFragments(_ input: [Line]) -> [Line] {
        let sorted = input.sorted { $0.box.minY < $1.box.minY }
        var rows: [Line] = []
        for line in sorted {
            if let index = rows.indices.last(where: { index in
                let row = rows[index]
                let gap = max(0, max(row.box.minX - line.box.maxX, line.box.minX - row.box.maxX))
                return abs(row.box.midY - line.box.midY) < min(row.box.height, line.box.height) * 0.4
                    && gap <= max(row.box.height, line.box.height) * 1.2
            }) {
                let row = rows[index]
                let text = row.box.minX < line.box.minX ? row.text + " " + line.text : line.text + " " + row.text
                rows[index] = Line(text: text, box: row.box.union(line.box),
                                   confidence: min(row.confidence, line.confidence), angle: row.angle)
            } else {
                rows.append(line)
            }
        }
        return rows.sorted { $0.box.minY < $1.box.minY }
    }

    private static func canAppend(_ line: Line, to group: [Line]) -> Bool {
        guard let previous = group.last, let first = group.first else { return false }
        let minHeight = min(previous.box.height, line.box.height)
        let maxHeight = max(previous.box.height, line.box.height)
        let gap = line.box.minY - previous.box.maxY
        let leftDistance = abs(first.box.minX - line.box.minX)
        // Split confidently different languages; short related-language labels need their
        // neighbouring line for context (e.g. Italian labels mistaken for Portuguese).
        if let previousLanguage = LanguageDetection.detect(previous.text, minimumConfidence: 0.9),
           let nextLanguage = LanguageDetection.detect(line.text, minimumConfidence: 0.9), previousLanguage != nextLanguage {
            return false
        }
        // A conservative left edge and line-height match keeps columns and cards apart.
        return maxHeight / max(minHeight, 1) < 1.6
            && gap >= -minHeight * 0.25 && gap <= maxHeight * 0.85
            && leftDistance <= max(8, minHeight * 0.75)
    }

    private static func isMetadata(_ text: String) -> Bool {
        if text.contains("@") || text.range(of: #"(?i)(https?://|www\.|\b[a-z0-9-]+\.(com|org|net|io|me)\b)"#,
                                             options: .regularExpression) != nil { return true }
        // OCR often misreads the unit after a timestamp; the separator plus digits
        // still distinguishes an author row from normal prose in the first version.
        if text.range(of: #"[•·⋅]\s*\d+[^A-Za-z]*$"#, options: .regularExpression) != nil { return true }
        if text.range(of: #"[•·⋅]\s*\d+\s*(s|m|h|d|w|mo|yr)\b"#,
                      options: [.regularExpression, .caseInsensitive]) != nil { return true }
        return false
    }

    private static func hasUsefulLetters(_ text: String) -> Bool {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        let digits = text.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }.count
        return letters >= 2 && Double(letters) / Double(max(letters + digits, 1)) >= 0.5
    }
}
