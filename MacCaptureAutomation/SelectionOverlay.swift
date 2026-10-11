import AppKit

@MainActor
final class SavedRangeOverlay {
    private var window: NSWindow?
    func show(rect: CGRect) {
        hide()
        let frame = rect.insetBy(dx: -4, dy: -4)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.level = .screenSaver
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = SavedRangeBorder(frame: CGRect(origin: .zero, size: frame.size))
        window = panel
        panel.orderFrontRegardless()
    }
    func hide() {
        window?.orderOut(nil)
        window?.close()
        window = nil
    }
}

private final class SavedRangeBorder: NSView {
    override func draw(_ dirtyRect: NSRect) {
        // Draw outside the saved rectangle, keeping the captured content clear.
        let path = NSBezierPath(rect: bounds.insetBy(dx: 2, dy: 2))
        NSColor.systemBlue.setStroke()
        path.lineWidth = 3
        path.stroke()
    }
}

@MainActor
final class SelectionCoordinator {
    private var windows: [NSWindow] = []
    private var completion: ((NSScreen?, CGRect?) -> Void)?
    init(completion: @escaping (NSScreen?, CGRect?) -> Void) { self.completion = completion }
    func begin() {
        NSApp.activate()
        for screen in NSScreen.screens {
            let window = SelectionWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.level = .screenSaver
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let view = SelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
            view.completed = { [weak self] rect in
                let absolute = rect?.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
                self?.finish(screen: rect == nil ? nil : screen, rect: absolute)
            }
            window.contentView = view
            windows.append(window)
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(view)
        }
    }
    private func finish(screen: NSScreen?, rect: CGRect?) {
        let callback = completion
        completion = nil
        windows.forEach { $0.orderOut(nil); $0.close() }
        windows.removeAll()
        callback?(screen, rect)
    }
}

private final class SelectionWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

private final class SelectionView: NSView {
    var completed: ((CGRect?) -> Void)?
    private var anchor: CGPoint?
    private var selection = CGRect.zero
    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func mouseDown(with event: NSEvent) {
        anchor = convert(event.locationInWindow, from: nil)
        selection = .zero; needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard let anchor else { return }
        let point = convert(event.locationInWindow, from: nil)
        selection = CGRect(x: min(anchor.x, point.x), y: min(anchor.y, point.y), width: abs(point.x - anchor.x), height: abs(point.y - anchor.y)).intersection(bounds)
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        mouseDragged(with: event)
        guard selection.width >= 2, selection.height >= 2 else { anchor = nil; return }
        completed?(selection)
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { completed?(nil) }
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()
        if !selection.isEmpty {
            NSColor.systemBlue.withAlphaComponent(0.2).setFill(); selection.fill()
            NSColor.systemBlue.setStroke()
            let path = NSBezierPath(rect: selection); path.lineWidth = 2; path.stroke()
        }
        let text = "ドラッグして範囲を選択 • Escでキャンセル"
        text.draw(at: CGPoint(x: 24, y: bounds.height - 60), withAttributes: [.font: NSFont.systemFont(ofSize: 22, weight: .semibold), .foregroundColor: NSColor.white])
    }
}
