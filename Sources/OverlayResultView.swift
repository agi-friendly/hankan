import AppKit

@MainActor
final class OverlayResultView: NSView {
    private let frozenImage: CGImage
    private let selectedImage: CGImage
    private let selectedRect: NSRect
    private let displayScale: CGFloat
    private let targetLanguage: TranslationLanguage
    private var translations: [OverlayTranslation] = []
    private var painted: OverlayPaintResult?
    private var showingOriginal = false
    private let statusLabel = NSTextField(labelWithString: "문단과 언어를 찾고 있어…")
    private let toggleButton = NSButton(title: "원문 보기 · Space", target: nil, action: nil)
    private let closeButton = NSButton(title: "닫기 · Esc", target: nil, action: nil)
    private let toolbar = NSView()
    private var popover: NSPopover?
    private var keyMonitor: Any?
    var onClose: (() -> Void)?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(frozenImage: CGImage, selectedImage: CGImage, selection: NSRect, frame: NSRect, targetLanguage: TranslationLanguage) {
        self.frozenImage = frozenImage
        self.selectedImage = selectedImage
        self.selectedRect = NSRect(x: selection.minX, y: frame.height - selection.maxY,
                                   width: selection.width, height: selection.height)
        self.displayScale = CGFloat(selectedImage.width) / selection.width
        self.targetLanguage = targetLanguage
        super.init(frame: frame)
        toolbar.wantsLayer = true
        toolbar.layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 0.97).cgColor
        toolbar.layer?.cornerRadius = 13
        statusLabel.textColor = .white
        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.lineBreakMode = .byTruncatingTail
        toggleButton.target = self
        toggleButton.action = #selector(toggleOriginal)
        closeButton.target = self
        closeButton.action = #selector(closeOverlay)
        for button in [toggleButton, closeButton] {
            button.bezelStyle = .rounded
            button.controlSize = .regular
        }
        for control in [statusLabel, toggleButton, closeButton] { toolbar.addSubview(control) }
        addSubview(toolbar)
        toolTip = "번역된 문단을 누르면 원문과 전체 번역을 볼 수 있어. Space 원문 전환 · Esc 닫기"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor = keyMonitor { NSEvent.removeMonitor(monitor); keyMonitor = nil }
        guard window != nil else { return }
        // Buttons and the read-only detail popover may own focus; Esc must still leave the frozen screen.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.window?.isVisible == true else { return event }
            if event.keyCode == 53 { self.onClose?(); return nil }
            if event.keyCode == 49 && !event.isARepeat && !event.modifierFlags.contains(.command) {
                self.toggleOriginal(); return nil
            }
            return event
        }
    }
    func dispose() {
        if let monitor = keyMonitor { NSEvent.removeMonitor(monitor); keyMonitor = nil }
        popover?.close()
        popover = nil
    }
    deinit { if let monitor = keyMonitor { NSEvent.removeMonitor(monitor) } }

    override func layout() {
        super.layout()
        let width = min(640, bounds.width - 24)
        let height: CGFloat = 52
        // Prefer free space outside the selected text so the controls do not cover its first paragraph.
        let topGap = selectedRect.minY
        let bottomGap = bounds.height - selectedRect.maxY
        let y: CGFloat = topGap >= height + 20 ? max(12, selectedRect.minY - height - 12)
            : bottomGap >= height + 20 ? min(bounds.height - height - 12, selectedRect.maxY + 12)
            : bounds.height - height - 12
        toolbar.frame = NSRect(x: (bounds.width - width) / 2, y: y, width: width, height: height)
        let toggleWidth: CGFloat = 138
        let closeWidth: CGFloat = 94
        closeButton.frame = NSRect(x: width - closeWidth - 12, y: 12, width: closeWidth, height: 28)
        toggleButton.frame = NSRect(x: width - closeWidth - toggleWidth - 20, y: 12, width: toggleWidth, height: 28)
        statusLabel.frame = NSRect(x: 16, y: 18, width: max(60, width - closeWidth - toggleWidth - 50), height: 20)
    }
    func setStatus(_ text: String) {
        statusLabel.stringValue = text
        statusLabel.toolTip = text
    }
    func setTranslations(_ values: [OverlayTranslation]) {
        translations = values
        painted = OverlayRenderer.render(image: selectedImage, translations: values, displayScale: displayScale)
        needsDisplay = true
    }
    @objc private func toggleOriginal() {
        showingOriginal.toggle()
        toggleButton.title = showingOriginal ? "번역 보기 · Space" : "원문 보기 · Space"
        popover?.close()
        needsDisplay = true
    }
    @objc private func closeOverlay() { onClose?() }

    override func draw(_ dirtyRect: NSRect) {
        NSImage(cgImage: frozenImage, size: bounds.size).draw(in: bounds, from: .zero, operation: .copy,
                                                           fraction: 1, respectFlipped: true, hints: nil)
        let shade = NSBezierPath(rect: bounds)
        shade.appendRect(selectedRect)
        shade.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.18).setFill()
        shade.fill()
        if !showingOriginal, let painted = painted {
            painted.image.draw(in: selectedRect, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        }
        NSColor.systemMint.withAlphaComponent(0.7).setStroke()
        let border = NSBezierPath(rect: selectedRect.insetBy(dx: -1, dy: -1))
        border.lineWidth = 1
        border.stroke()
    }
    override func mouseDown(with event: NSEvent) {
        guard !showingOriginal else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard selectedRect.contains(point) else { return }
        let sx = CGFloat(selectedImage.width) / selectedRect.width
        let sy = CGFloat(selectedImage.height) / selectedRect.height
        let imagePoint = CGPoint(x: (point.x - selectedRect.minX) * sx, y: (point.y - selectedRect.minY) * sy)
        guard let translation = translations.first(where: { $0.paragraph.bounds.insetBy(dx: -4, dy: -4).contains(imagePoint) }) else { return }
        showDetails(translation, at: point)
    }
    private func showDetails(_ translation: OverlayTranslation, at point: NSPoint) {
        popover?.close()
        let controller = NSViewController()
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 440, height: 300))
        scroll.hasVerticalScroller = true
        let text = NSTextView(frame: scroll.bounds)
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.font = .systemFont(ofSize: 15)
        text.textContainerInset = NSSize(width: 16, height: 16)
        text.autoresizingMask = [.width]
        text.isVerticallyResizable = true
        text.textContainer?.widthTracksTextView = true
        text.string = "\(targetLanguage.displayName)\n\n\(translation.text)\n\n────────\n\(translation.paragraph.sourceLanguage.displayName) 원문\n\n\(translation.paragraph.source)"
        scroll.documentView = text
        controller.view = scroll
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.contentSize = scroll.frame.size
        popover.behavior = .transient
        popover.show(relativeTo: NSRect(x: point.x, y: point.y, width: 1, height: 1), of: self, preferredEdge: .maxY)
        self.popover = popover
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onClose?() }
        else if event.keyCode == 49 && !event.isARepeat { toggleOriginal() }
        else { super.keyDown(with: event) }
    }
}
