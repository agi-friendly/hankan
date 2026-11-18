import AppKit
import ImageIO

func argument(_ name: String) -> String? {
    guard let i = CommandLine.arguments.firstIndex(of: name), CommandLine.arguments.count > i + 1 else { return nil }
    return CommandLine.arguments[i + 1]
}

if let path = argument("--test-overlay") {
    Task.detached {
        do {
            let start = Date()
            guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
                  var image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw CaptureError.noDisplay }
            if let coordinates = argument("--crop")?.split(separator: ",").compactMap({ Double($0) }), coordinates.count == 4 {
                guard let cropped = image.cropping(to: CGRect(x: coordinates[0], y: coordinates[1], width: coordinates[2], height: coordinates[3])) else { throw CaptureError.invalidSelection }
                image = cropped
            }
            let settings = TranslationSettings.load()
            let analysis = try OverlayLayout.analyze(image, targetLanguage: settings.targetLanguage)
            let ocrSeconds = Date().timeIntervalSince(start)
            var translations: [OverlayTranslation] = []
            for paragraph in analysis.paragraphs {
                let text = try await TranslationCore.translate(paragraph.source, sourceLanguage: paragraph.sourceLanguage, settings: settings)
                translations.append(OverlayTranslation(paragraph: paragraph, text: text))
            }
            let scale = Double(argument("--scale") ?? "2") ?? 2
            let finished = translations
            let translatedAt = Date()
            let frozen = image
            let overflow = try await MainActor.run { () throws -> [Int] in
                let painted = OverlayRenderer.render(image: frozen, translations: finished, displayScale: scale)
                if let path = argument("--render"), let tiff = painted.image.tiffRepresentation,
                   let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) {
                    try png.write(to: URL(fileURLWithPath: path))
                }
                return painted.overflowIDs.sorted()
            }
            let records: [[String: Any]] = translations.map { value in
                ["id": value.paragraph.id, "source": value.paragraph.source, "translation": value.text,
                 "source_language": value.paragraph.sourceLanguage.code,
                 "bounds": [value.paragraph.bounds.minX, value.paragraph.bounds.minY, value.paragraph.bounds.width, value.paragraph.bounds.height]]
            }
            let report: [String: Any] = ["paragraphs": records, "recognized_lines": analysis.recognizedLineCount,
                                       "target_language": settings.targetLanguage.code, "model": settings.modelID,
                                       "overflow_ids": overflow, "seconds": Date().timeIntervalSince(start),
                                       "ocr_seconds": ocrSeconds,
                                       "translation_seconds": translatedAt.timeIntervalSince(start) - ocrSeconds,
                                       "render_seconds": Date().timeIntervalSince(translatedAt)]
            if let path = argument("--report") {
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]).write(to: URL(fileURLWithPath: path))
            }
            print("Overlay test: \(analysis.recognizedLineCount) OCR regions, \(translations.count) translated paragraphs, \(overflow.count) overflow, \(String(format: "%.2f", Date().timeIntervalSince(start)))s")
            exit(0)
        } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
    }
    dispatchMain()
} else if let path = argument("--test-image") {
    Task.detached {
        do {
            let start = Date()
            guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
                  var image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw CaptureError.noDisplay }
            if let coordinates = argument("--crop")?.split(separator: ",").compactMap({ Double($0) }), coordinates.count == 4 {
                let rect = CGRect(x: coordinates[0], y: coordinates[1], width: coordinates[2], height: coordinates[3])
                guard let cropped = image.cropping(to: rect) else { throw CaptureError.invalidSelection }
                image = cropped
            }
            if let path = argument("--save-crop"),
               let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(destination, image, nil)
                guard CGImageDestinationFinalize(destination) else { throw CaptureError.invalidSelection }
            }
            let recognized = try TranslationCore.recognize(image)
            let ocrTime = Date().timeIntervalSince(start)
            let translated = try await TranslationCore.translate(recognized.text)
            let report: [String: Any] = ["ocr_text": recognized.text, "translation": translated,
                "line_count": recognized.lineCount, "ocr_seconds": ocrTime,
                "total_seconds": Date().timeIntervalSince(start), "image_width": image.width, "image_height": image.height]
            let json = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            if let path = argument("--report") { try json.write(to: URL(fileURLWithPath: path)) }
            print(String(decoding: json, as: UTF8.self))
            exit(0)
        } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
    }
    dispatchMain()
} else {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
