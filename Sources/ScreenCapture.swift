import AppKit
import ScreenCaptureKit

struct FrozenDisplay {
    let screen: NSScreen
    let image: CGImage
}

enum CaptureError: LocalizedError {
    case permission, noDisplay, invalidSelection
    var errorDescription: String? {
        switch self {
        case .permission: return "화면 기록 권한이 필요해. 시스템 설정에서 ‘한칸’을 허용한 뒤 앱을 다시 열어줘."
        case .noDisplay: return "캡처할 화면을 찾지 못했어. 디스플레이 연결을 확인해줘."
        case .invalidSelection: return "조금 더 넓은 영역을 선택해줘."
        }
    }
}

@MainActor
enum ScreenCapture {
    static func freeze() async throws -> [FrozenDisplay] {
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            throw CaptureError.permission
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let ownApp = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        var result: [FrozenDisplay] = []
        // Capture before showing any selection windows, so overlays cannot enter the image.
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let display = content.displays.first(where: { $0.displayID == number.uint32Value }) else { continue }
            let filter = SCContentFilter(display: display, excludingApplications: ownApp, exceptingWindows: [])
            let config = SCStreamConfiguration()
            config.width = Int(screen.frame.width * screen.backingScaleFactor)
            config.height = Int(screen.frame.height * screen.backingScaleFactor)
            config.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            result.append(FrozenDisplay(screen: screen, image: image))
        }
        guard !result.isEmpty else { throw CaptureError.noDisplay }
        return result
    }

    static func crop(_ image: CGImage, selection: NSRect, viewSize: NSSize) throws -> CGImage {
        guard viewSize.width > 0, viewSize.height > 0 else { throw CaptureError.invalidSelection }
        let clipped = selection.intersection(NSRect(origin: .zero, size: viewSize))
        guard clipped.width >= 8, clipped.height >= 8 else { throw CaptureError.invalidSelection }
        let sx = CGFloat(image.width) / viewSize.width
        let sy = CGFloat(image.height) / viewSize.height
        // AppKit measures from the bottom; image cropping measures from the top.
        let pixels = CGRect(x: clipped.minX * sx, y: (viewSize.height - clipped.maxY) * sy,
                            width: clipped.width * sx, height: clipped.height * sy).integral
        guard let crop = image.cropping(to: pixels) else { throw CaptureError.invalidSelection }
        return crop
    }
}

final class SelectionWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class SelectionView: NSView {
    let image: CGImage
    var onSelect: ((CGImage, NSRect) -> Void)?
    var onCancel: (() -> Void)?
    private var anchor: NSPoint?
    private var selection: NSRect = .zero
    override var acceptsFirstResponder: Bool { true }
    // Each display has its own window; the first drag must work on an inactive one too.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(image: CGImage, frame: NSRect) {
        self.image = image
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func draw(_ dirtyRect: NSRect) {
        NSImage(cgImage: image, size: bounds.size).draw(in: bounds)
        let shade = NSBezierPath(rect: bounds)
        if !selection.isEmpty { shade.appendRect(selection) }
        shade.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.48).setFill()
        shade.fill()
        if !selection.isEmpty {
            NSColor.systemMint.setStroke()
            let border = NSBezierPath(rect: selection.insetBy(dx: -1, dy: -1))
            border.lineWidth = 2
            border.stroke()
        }
        let text = "번역할 영역을 드래그해줘  ·  Esc 취소"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 17, weight: .semibold), .foregroundColor: NSColor.white
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let box = NSRect(x: (bounds.width - size.width) / 2 - 20, y: bounds.height - 92,
                         width: size.width + 40, height: 48)
        NSColor.black.withAlphaComponent(0.85).setFill()
        NSBezierPath(roundedRect: box, xRadius: 15, yRadius: 15).fill()
        (text as NSString).draw(at: NSPoint(x: box.minX + 20, y: box.minY + 14), withAttributes: attributes)
    }
    override func mouseDown(with event: NSEvent) {
        anchor = convert(event.locationInWindow, from: nil)
        selection = .zero
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start = anchor else { return }
        let raw = convert(event.locationInWindow, from: nil)
        let point = NSPoint(x: min(max(raw.x, 0), bounds.width), y: min(max(raw.y, 0), bounds.height))
        selection = NSRect(x: min(start.x, point.x), y: min(start.y, point.y),
                           width: abs(start.x - point.x), height: abs(start.y - point.y))
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        mouseDragged(with: event)
        anchor = nil
        guard selection.width >= 8, selection.height >= 8 else { selection = .zero; needsDisplay = true; return }
        do { onSelect?(try ScreenCapture.crop(image, selection: selection, viewSize: bounds.size), selection) }
        catch { onCancel?() }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() } else { super.keyDown(with: event) }
    }
    override func rightMouseDown(with event: NSEvent) { onCancel?() }
}
