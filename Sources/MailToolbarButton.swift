import AppKit
import ApplicationServices

/// Mail 창 기준 상대 위치를 유지하는 비활성 패널. 메시지 내용이나 Mail 도구막대는 변경하지 않는다.
/// 접근성 허용 시 포커스 창을, 그 외에는 공개 창 경계를 사용한다.
@MainActor
final class MailToolbarButton: NSObject, NSWindowDelegate {
    static let shared = MailToolbarButton()
    private let preference = "attachedMailTranslationButton"
    private var timer: Timer?
    private var panel: NSPanel?
    private var targetFrame: NSRect?
    private let offsetPreference = "mailTranslationButtonWindowOffset"
    private var isDragging = false
    var isEnabled: Bool { UserDefaults.standard.bool(forKey: preference) }

    func enable() {
        let alert = NSAlert()
        alert.messageText = "메일 상단에 번역 버튼 붙이기"
        alert.informativeText = "Mail을 볼 때 표시되는 별도 번역 버튼입니다. 버튼이나 왼쪽 손잡이를 끌어 위치를 정하면 Mail 창과의 간격을 기억해 함께 이동합니다. 창 가장자리에 표시하기 어려우면 Mail이 있는 모니터 안에 표시됩니다. 손쉬운 사용 권한 없이도 창 위치를 따라가며, 이 버튼은 권한 요청이나 시스템 설정 변경을 하지 않습니다. Mail의 정식 도구막대 항목은 아닙니다."
        alert.addButton(withTitle: "버튼 켜기")
        alert.addButton(withTitle: "취소")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        UserDefaults.standard.set(true, forKey: preference)
        start()
    }

    func resumeIfEnabled() { if isEnabled { start() } }
    func disable() {
        UserDefaults.standard.set(false, forKey: preference)
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
    }

    private func start() {
        guard timer == nil else { return }
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 98, height: 28),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.title = "Mail 번역 버튼"
        p.delegate = self
        p.isMovable = true
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 98, height: 28))
        let handle = MailTranslationDragHandle(frame: NSRect(x: 0, y: 0, width: 20, height: 28))
        handle.toolTip = "끌어서 번역 버튼 위치 옮기기"
        handle.setAccessibilityLabel("번역 버튼 위치 손잡이")
        handle.beginDrag = { [weak self] in
            guard let self else { return }
            self.isDragging = true
        }
        handle.endDrag = { [weak self] in
            guard let self, let panel = self.panel else { return }
            if let target = self.targetFrame {
                let offset = NSPoint(x: target.maxX - panel.frame.maxX, y: target.maxY - panel.frame.maxY)
                UserDefaults.standard.set(NSStringFromPoint(offset), forKey: self.offsetPreference)
            }
            self.isDragging = false
        }
        content.addSubview(handle)
        let button = MovableMailTranslationButton(title: "번역", image: NSImage(systemSymbolName: "translate", accessibilityDescription: "선택한 메일 번역") ?? NSImage(), target: self, action: #selector(translate))
        button.frame = NSRect(x: 20, y: 0, width: 78, height: 28)
        button.bezelStyle = .rounded
        button.imagePosition = .imageLeading
        button.beginDrag = handle.beginDrag
        button.endDrag = handle.endDrag
        button.toolTip = "클릭: 선택한 메일 번역 · 끌기: 이 버튼 위치 이동"
        button.setAccessibilityIdentifier("mail-translation-overlay-button")
        content.addSubview(button)
        p.contentView = content
        panel = p
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePosition() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        updatePosition()
    }

    @objc private func translate() {
        panel?.orderOut(nil)
        AppModel.shared.translateSelectedMail()
    }

    private func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
        return result
    }
    private func rect(_ element: AXUIElement) -> CGRect? {
        guard let p = value(element, kAXPositionAttribute), CFGetTypeID(p) == AXValueGetTypeID(),
              let s = value(element, kAXSizeAttribute), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point),
              AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }
    private func children(_ element: AXUIElement) -> [AXUIElement] {
        value(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }
    private func updatePosition() {
        guard !isDragging else { return }
        guard isEnabled, let panel,
              let front = NSWorkspace.shared.frontmostApplication,
              front.bundleIdentifier == "com.apple.mail" else {
            panel?.orderOut(nil)
            return
        }

        var target: NSRect?
        if AXIsProcessTrusted() {
            let app = AXUIElementCreateApplication(front.processIdentifier)
            if let raw = value(app, kAXFocusedWindowAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() {
                let window = raw as! AXUIElement
                // 최소화 또는 확인 시트 표시 중에는 조작 대상을 가리지 않는다.
                if value(window, kAXMinimizedAttribute) as? Bool == true ||
                    children(window).contains(where: { value($0, kAXRoleAttribute) as? String == kAXSheetRole }) {
                    panel.orderOut(nil)
                    return
                }
                if let bounds = rect(window), let height = WindowGeometry.primaryDisplayHeight() {
                    target = NSRect(x: bounds.minX, y: height - bounds.maxY, width: bounds.width, height: bounds.height)
                }
            }
        }
        // Read only Mail's visible window geometry; no title, content, or screenshot.
        if target == nil {
            target = WindowGeometry.otherAppWindows(ownerPID: front.processIdentifier).first?.frame
        }
        guard let target, target.width > 0, target.height > 0,
              let screen = WindowGeometry.screen(mostOverlapping: target) else {
            targetFrame = nil
            panel.orderOut(nil)
            return
        }
        targetFrame = target
        var offset = NSPoint(x: 12, y: 8)
        if let saved = UserDefaults.standard.string(forKey: offsetPreference) {
            let point = NSPointFromString(saved)
            if point.x.isFinite, point.y.isFinite { offset = point }
        } else if let saved = UserDefaults.standard.string(forKey: "mailTranslationButtonManualFrame") {
            // Migrate the former fixed position only when it belongs to this Mail screen.
            let frame = NSRectFromString(saved)
            if frame.width == 98, frame.height == 28,
               screen.visibleFrame.contains(frame), frame.intersects(target) {
                offset = NSPoint(x: target.maxX - frame.maxX, y: target.maxY - frame.maxY)
                UserDefaults.standard.set(NSStringFromPoint(offset), forKey: offsetPreference)
            }
        }
        let area = screen.visibleFrame
        var frame = NSRect(x: target.maxX - offset.x - 98, y: target.maxY - offset.y - 28, width: 98, height: 28)
        // Keep the preferred offset intact even when a smaller screen forces the button inward.
        frame.origin.x = min(max(frame.minX, area.minX), max(area.minX, area.maxX - frame.width))
        frame.origin.y = min(max(frame.minY, area.minY), max(area.minY, area.maxY - frame.height))
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        panel.orderFrontRegardless()
    }

}


/// Moves only this application's own panel; does not inspect another window.
private final class MailButtonDrag {
    private var mouse: NSPoint?
    private var origin = NSPoint.zero
    func begin(_ window: NSWindow?) {
        guard let window else { return }
        mouse = NSEvent.mouseLocation
        origin = window.frame.origin
    }
    func move(_ window: NSWindow?) {
        guard let mouse, let window else { return }
        let now = NSEvent.mouseLocation
        window.setFrameOrigin(NSPoint(x: origin.x + now.x - mouse.x, y: origin.y + now.y - mouse.y))
    }
    func end() { mouse = nil }
}

private final class MailTranslationDragHandle: NSView {
    var beginDrag: (() -> Void)?
    var endDrag: (() -> Void)?
    private let drag = MailButtonDrag()
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func mouseDown(with event: NSEvent) { beginDrag?(); drag.begin(window) }
    override func mouseDragged(with event: NSEvent) { drag.move(window) }
    override func mouseUp(with event: NSEvent) { drag.move(window); drag.end(); endDrag?() }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.secondaryLabelColor.setFill()
        for y in [CGFloat(9), CGFloat(14), CGFloat(19)] {
            NSBezierPath(ovalIn: NSRect(x: 8, y: y - 1, width: 3, height: 3)).fill()
        }
    }
}

private final class MovableMailTranslationButton: NSButton {
    var beginDrag: (() -> Void)?
    var endDrag: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let startMouse = NSEvent.mouseLocation
        let startOrigin = window.frame.origin
        var moved = false
        // NSButton's default tracking consumes dragged events. Track this exact
        // button ourselves so an ordinary drag moves it and a click translates.
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let now = NSEvent.mouseLocation
            let dx = now.x - startMouse.x
            let dy = now.y - startMouse.y
            if !moved && hypot(dx, dy) >= 4 {
                moved = true
                beginDrag?()
            }
            if moved {
                window.setFrameOrigin(NSPoint(x: startOrigin.x + dx, y: startOrigin.y + dy))
            }
            if next.type == .leftMouseUp {
                if moved { endDrag?() }
                else if let action, bounds.contains(convert(next.locationInWindow, from: nil)) {
                    NSApp.sendAction(action, to: target, from: self)
                }
                break
            }
        }
    }
}
