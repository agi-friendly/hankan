import AppKit
import ImageIO

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private var statusItem: NSStatusItem!
    private var overlayWindows: [NSWindow] = []
    private var job: Task<Void, Never>?
    private var runID = UUID()
    private let original = NSTextView()
    private let translated = NSTextView()
    private let preview = NSImageView()
    private let status = NSTextField(labelWithString: "영역 번역을 누르고 읽고 싶은 부분을 드래그해줘.")
    private let progress = NSProgressIndicator()
    private var captureButton: NSButton!
    private var fileButton: NSButton!
    private var retryButton: NSButton!
    private var copyButton: NSButton!
    private var cancelButton: NSButton!

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        buildWindow()
        showWindow()
        if let index = CommandLine.arguments.firstIndex(of: "--open-image"), CommandLine.arguments.count > index + 1 {
            openImage(URL(fileURLWithPath: CommandLine.arguments[index + 1]))
        }
        if let path = argument("--preview-overlay"),
           let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            previewOverlay(image)
        }
    }

    private func button(_ title: String, action: Selector) -> NSButton {
        let control = NSButton(title: title, target: self, action: action)
        control.bezelStyle = .rounded
        control.controlSize = .large
        return control
    }

    private func buildMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        menu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "한칸 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let taskMenuItem = NSMenuItem(title: "번역", action: nil, keyEquivalent: "")
        let taskMenu = NSMenu(title: "번역")
        let capture = NSMenuItem(title: "영역 번역…", action: #selector(beginCapture), keyEquivalent: "t")
        capture.keyEquivalentModifierMask = [.command, .shift]
        capture.target = self
        taskMenu.addItem(capture)
        let show = NSMenuItem(title: "결과 창 열기", action: #selector(showWindow), keyEquivalent: "0")
        show.target = self
        taskMenu.addItem(show)
        taskMenuItem.submenu = taskMenu
        menu.addItem(taskMenuItem)
        let editItem = NSMenuItem(title: "편집", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "편집")
        for (name, selector, key) in [("잘라내기", #selector(NSText.cut(_:)), "x"), ("복사", #selector(NSText.copy(_:)), "c"), ("붙여넣기", #selector(NSText.paste(_:)), "v"), ("전체 선택", #selector(NSText.selectAll(_:)), "a")] {
            editMenu.addItem(withTitle: name, action: selector, keyEquivalent: key)
        }
        editItem.submenu = editMenu
        menu.addItem(editItem)
        NSApp.mainMenu = menu

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "한칸")
        let trayMenu = NSMenu()
        for (name, action) in [("영역 번역…", #selector(beginCapture)), ("결과 창 열기", #selector(showWindow))] {
            let item = NSMenuItem(title: name, action: action, keyEquivalent: "")
            item.target = self
            trayMenu.addItem(item)
        }
        trayMenu.addItem(.separator())
        trayMenu.addItem(withTitle: "종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        statusItem.menu = trayMenu
    }

    private func textPane(title: String, detail: String, textView: NSTextView, editable: Bool) -> NSView {
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 18, weight: .semibold)
        let subtitle = NSTextField(labelWithString: detail)
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 12
        textView.isEditable = editable
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = .systemFont(ofSize: 16)
        textView.textColor = .labelColor
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 14, height: 14)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        scroll.documentView = textView
        let stack = NSStackView(views: [heading, subtitle, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([scroll.widthAnchor.constraint(equalTo: stack.widthAnchor), scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 240)])
        return stack
    }

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 760),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "한칸"
        window.minSize = NSSize(width: 800, height: 640)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        let root = NSView()
        window.contentView = root
        let targetName = TranslationSettings.load().targetLanguage.displayName
        let title = NSTextField(labelWithString: "화면 속 글자를 \(targetName)로")
        title.font = .systemFont(ofSize: 25, weight: .bold)
        let subtitle = NSTextField(labelWithString: "문단별 자동 감지 → \(targetName) · Space 원문 전환 · Esc 닫기")
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor
        captureButton = button("영역 번역", action: #selector(beginCapture))
        captureButton.contentTintColor = .systemTeal
        fileButton = button("이미지 열기…", action: #selector(chooseImage))
        retryButton = button("원문 다시 번역", action: #selector(retranslate))
        copyButton = button("번역 복사", action: #selector(copyTranslation))
        cancelButton = button("중지", action: #selector(cancelWork))
        cancelButton.isHidden = true
        retryButton.isEnabled = false
        copyButton.isEnabled = false
        let toolbar = NSStackView(views: [captureButton, fileButton, retryButton, copyButton, cancelButton])
        toolbar.spacing = 8
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.wantsLayer = true
        preview.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.05).cgColor
        preview.layer?.cornerRadius = 12
        preview.toolTip = "선택한 화면 조각"
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.heightAnchor.constraint(equalToConstant: 155).isActive = true
        let panes = NSStackView(views: [textPane(title: "인식한 원문", detail: "잘못 읽은 글자는 직접 고칠 수 있어.", textView: original, editable: true),
                                        textPane(title: "\(targetName) 번역", detail: "이 Mac에서 번역한 결과", textView: translated, editable: false)])
        panes.orientation = .horizontal
        panes.distribution = .fillEqually
        panes.alignment = .top
        panes.spacing = 18
        for pane in panes.arrangedSubviews { pane.heightAnchor.constraint(equalTo: panes.heightAnchor).isActive = true }
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byWordWrapping
        status.maximumNumberOfLines = 3
        let footer = NSStackView(views: [progress, status])
        footer.spacing = 8
        let stack = NSStackView(views: [title, subtitle, toolbar, preview, panes, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
            preview.widthAnchor.constraint(equalTo: stack.widthAnchor),
            panes.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    @objc func showWindow() {
        if !overlayWindows.isEmpty {
            runID = UUID()
            job?.cancel()
            clearOverlays()
            busy(false, message: "인식한 원문과 번역을 확인할 수 있어.")
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func busy(_ active: Bool, message: String) {
        captureButton.isEnabled = !active
        fileButton.isEnabled = !active
        retryButton.isEnabled = !active && !original.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        original.isEditable = !active
        copyButton.isEnabled = !active && !translated.string.isEmpty
        cancelButton.isHidden = !active
        active ? progress.startAnimation(nil) : progress.stopAnimation(nil)
        status.stringValue = message
    }

    private func clearOverlays() {
        for overlay in overlayWindows {
            (overlay.contentView as? OverlayResultView)?.dispose()
            overlay.orderOut(nil)
        }
        overlayWindows.removeAll()
    }
    private func finishOverlay() {
        runID = UUID()
        job?.cancel()
        job = nil
        clearOverlays()
        busy(false, message: "화면 번역을 닫았어. 메뉴 막대에서 다시 시작할 수 있어.")
        window.orderOut(nil)
        NSApp.hide(nil)
    }
    @objc func cancelWork() {
        runID = UUID()
        job?.cancel()
        job = nil
        clearOverlays()
        busy(false, message: "취소했어. 다시 영역을 선택할 수 있어.")
        showWindow()
    }
    @objc func beginCapture() {
        runID = UUID()
        let id = runID
        job?.cancel()
        clearOverlays()
        busy(true, message: "화면을 준비하고 있어…")
        window.orderOut(nil)
        job = Task { [self] in
            do {
                try await Task.sleep(nanoseconds: 180_000_000)
                let displays = try await ScreenCapture.freeze()
                try Task.checkCancellation()
                guard runID == id else { return }
                for display in displays {
                    let view = SelectionView(image: display.image, frame: NSRect(origin: .zero, size: display.screen.frame.size))
                    let overlay = SelectionWindow(contentRect: display.screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                    overlay.level = .screenSaver
                    overlay.isOpaque = true
                    overlay.backgroundColor = .black
                    overlay.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                    overlay.contentView = view
                    overlay.acceptsMouseMovedEvents = true
                    view.onSelect = { [weak self, weak overlay] image, selection in
                        guard let self = self, let overlay = overlay else { return }
                        self.startOverlay(selectedImage: image, frozenImage: display.image,
                                          selection: selection, in: overlay)
                    }
                    view.onCancel = { [weak self] in self?.finishOverlay() }
                    overlayWindows.append(overlay)
                    overlay.makeKeyAndOrderFront(nil)
                    overlay.makeFirstResponder(view)
                }
                NSApp.activate(ignoringOtherApps: true)
            } catch is CancellationError { }
            catch {
                guard runID == id else { return }
                showError(error)
            }
        }
    }

    private func startOverlay(selectedImage: CGImage, frozenImage: CGImage, selection: NSRect, in overlay: NSWindow) {
        job?.cancel()
        runID = UUID()
        let id = runID
        // One snapshot keeps model and language choices consistent throughout this capture.
        let settings = TranslationSettings.load()
        for other in overlayWindows where other !== overlay {
            (other.contentView as? OverlayResultView)?.dispose()
            other.orderOut(nil)
        }
        overlayWindows = [overlay]
        let view = OverlayResultView(frozenImage: frozenImage, selectedImage: selectedImage,
                                     selection: selection, frame: NSRect(origin: .zero, size: overlay.frame.size),
                                     targetLanguage: settings.targetLanguage)
        view.onClose = { [weak self] in self?.finishOverlay() }
        overlay.contentView = view
        overlay.makeKeyAndOrderFront(nil)
        overlay.makeFirstResponder(view)
        preview.image = NSImage(cgImage: selectedImage, size: NSSize(width: selectedImage.width, height: selectedImage.height))
        original.string = ""
        translated.string = ""
        busy(true, message: "화면 위에 번역하고 있어…")
        let start = Date()
        job = Task {
            do {
                let analysis = try await OCRWorker.shared.analyzeOverlay(selectedImage, targetLanguage: settings.targetLanguage)
                try Task.checkCancellation()
                guard runID == id else { return }
                guard !analysis.paragraphs.isEmpty else {
                    view.setStatus("번역할 다른 언어의 본문을 찾지 못했어 · Esc 닫기")
                    busy(false, message: "이미 \(settings.targetLanguage.displayName)인 글과 숫자·계정명은 유지해. 작은 글자나 불명확한 언어는 영역을 조정해서 다시 시도해줘.")
                    return
                }
                original.string = analysis.paragraphs.map(\.source).joined(separator: "\n\n")
                var completed: [OverlayTranslation] = []
                for (index, paragraph) in analysis.paragraphs.enumerated() {
                    try Task.checkCancellation()
                    view.setStatus("\(paragraph.sourceLanguage.displayName) → \(settings.targetLanguage.displayName) · \(index + 1)/\(analysis.paragraphs.count)")
                    let text = try await TranslationCore.translate(paragraph.source, sourceLanguage: paragraph.sourceLanguage, settings: settings)
                    try Task.checkCancellation()
                    guard runID == id else { return }
                    completed.append(OverlayTranslation(paragraph: paragraph, text: text))
                    view.setTranslations(completed)
                    translated.string = completed.map(\.text).joined(separator: "\n\n")
                }
                let message = String(format: "자동 → %@ · %d문단 · %.1f초", settings.targetLanguage.displayName, completed.count, Date().timeIntervalSince(start))
                view.setStatus(message)
                busy(false, message: message)
            } catch is CancellationError { }
            catch {
                guard runID == id else { return }
                // Successful paragraphs stay visible; untranslated ones retain their original pixels.
                view.setStatus(error.localizedDescription + " · Esc 닫기")
                busy(false, message: error.localizedDescription)
            }
        }
    }

    private func previewOverlay(_ image: CGImage) {
        guard let screen = NSScreen.main else { return }
        window.orderOut(nil)
        let size = NSSize(width: image.width, height: image.height)
        let scale = min(1, min((screen.visibleFrame.width - 80) / size.width, (screen.visibleFrame.height - 100) / size.height))
        let frame = NSRect(x: screen.visibleFrame.midX - size.width * scale / 2,
                           y: screen.visibleFrame.midY - size.height * scale / 2,
                           width: size.width * scale, height: size.height * scale)
        let overlay = SelectionWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        overlay.level = .screenSaver
        overlay.isOpaque = true
        overlay.backgroundColor = .black
        startOverlay(selectedImage: image, frozenImage: image,
                     selection: NSRect(origin: .zero, size: frame.size), in: overlay)
    }

    private func showError(_ error: Error) {
        clearOverlays()
        showWindow()
        busy(false, message: error.localizedDescription)
        let alert = NSAlert()
        alert.messageText = "번역을 시작하지 못했어"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "확인")
        if error is CaptureError {
            alert.addButton(withTitle: "화면 기록 설정 열기")
        }
        alert.beginSheetModal(for: window) { response in
            if response == .alertSecondButtonReturn,
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    @objc func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic]
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK, let url = panel.url { self?.openImage(url) }
        }
    }
    private func openImage(_ url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            busy(false, message: "이미지를 읽지 못했어. PNG 또는 JPEG 파일로 시도해줘.")
            return
        }
        previewOverlay(image)
    }
    @objc func retranslate() {
        let source = original.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return }
        job?.cancel()
        runID = UUID()
        let id = runID
        translated.string = ""
        busy(true, message: "수정한 원문을 번역하고 있어…")
        let start = Date()
        job = Task {
            do {
                let text = try await TranslationCore.translate(source)
                try Task.checkCancellation()
                guard runID == id else { return }
                translated.string = text
                busy(false, message: String(format: "번역 완료 · %.1f초", Date().timeIntervalSince(start)))
            } catch is CancellationError { }
            catch { if runID == id { busy(false, message: error.localizedDescription) } }
        }
    }
    @objc func copyTranslation() {
        guard !translated.string.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(translated.string, forType: .string)
        status.stringValue = "번역을 복사했어."
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }
    func applicationDidResignActive(_ notification: Notification) {
        // A frozen window must not remain over another app after Cmd-Tab or a click on a second display.
        if !overlayWindows.isEmpty { finishOverlay() }
    }
    func applicationWillTerminate(_ notification: Notification) { job?.cancel(); clearOverlays() }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        runID = UUID()
        job?.cancel()
        clearOverlays()
        busy(false, message: "메뉴 막대에서 다시 영역 번역을 시작할 수 있어.")
        return true
    }
}
