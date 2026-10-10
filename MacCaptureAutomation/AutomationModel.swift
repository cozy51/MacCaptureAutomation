import AppKit
import SwiftUI
import ApplicationServices

struct AutomationSettings: Codable {
    var kindleID = "com.amazon.Kindle"
    var presentationURL = ""
    var switchDelay = 1.0
    var pasteDelay = 1.5
    var keyCode = 125
    var command = false
    var option = false
    var shift = false
    var control = false
}

struct AutomationFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
final class AutomationModel: ObservableObject {
    @Published var settings = AutomationSettings()
    @Published private(set) var running = false
    @Published private(set) var paused = false
    @Published private(set) var operation = "待機中"
    @Published private(set) var elapsed = 0.0
    @Published private(set) var errors = 0
    @Published private(set) var progress = 0.0
    @Published private(set) var pasteUncertain = false
    private var task: Task<Void, Never>?
    private var started: Date?
    private let storageKey = "automationSettings.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode(AutomationSettings.self, from: data) { settings = saved }
        // Apply the requested down-arrow default once to existing installations.
        if !UserDefaults.standard.bool(forKey: "downArrowDefault.v1") {
            settings.keyCode = 125
            settings.command = false; settings.option = false
            settings.shift = false; settings.control = false
            save()
            UserDefaults.standard.set(true, forKey: "downArrowDefault.v1")
        }
        pasteUncertain = UserDefaults.standard.bool(forKey: "pasteUncertain")
    }
    func save() {
        if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: storageKey) }
    }
    func acknowledgePaste() {
        pasteUncertain = false
        UserDefaults.standard.set(false, forKey: "pasteUncertain")
    }
    func pause() { guard running else { return }; paused = true }
    func resume() { paused = false }
    func stop() { task?.cancel(); paused = false }

    private func checkpoint() async throws {
        try Task.checkCancellation()
        elapsed = started.map { Date().timeIntervalSince($0) } ?? 0
        while paused {
            try await Task.sleep(nanoseconds: 50_000_000)
            try Task.checkCancellation()
            elapsed = started.map { Date().timeIntervalSince($0) } ?? 0
        }
    }
    private func wait(_ seconds: Double) async throws {
        var remaining = max(0, seconds)
        while remaining > 0 {
            try await checkpoint()
            let slice = min(0.05, remaining)
            try await Task.sleep(nanoseconds: UInt64(slice * 1_000_000_000))
            remaining -= slice
        }
        try await checkpoint()
    }
    private func application(_ id: String) throws -> NSRunningApplication {
        guard AXIsProcessTrusted() else { throw AutomationFailure(message: "アクセシビリティ権限がありません。") }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first else {
            throw AutomationFailure(message: "アプリが起動していません: \(id)")
        }
        return app
    }
    private func activate(_ id: String, delay: Double) async throws -> NSRunningApplication {
        try await checkpoint()
        let app = try application(id)
        guard app.activate(options: []) else { throw AutomationFailure(message: "アプリ切り替えに失敗しました。") }
        try await wait(delay)
        try verifyFrontmost(app)
        return app
    }
    private func verifyFrontmost(_ app: NSRunningApplication) throws {
        guard AXIsProcessTrusted(), NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
            throw AutomationFailure(message: "対象アプリが前面ではありません。操作を停止しました。")
        }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &windowValue) == .success,
              let windowValue, CFGetTypeID(windowValue) == AXUIElementGetTypeID() else {
            throw AutomationFailure(message: "操作対象のウィンドウを確認できません。")
        }
        let window = unsafeBitCast(windowValue, to: AXUIElement.self)
        var modal: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXModalAttribute as CFString, &modal) == .success,
           (modal as? Bool) == true { throw AutomationFailure(message: "ダイアログを検出しました。") }
        var sheets: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, "AXSheets" as CFString, &sheets) == .success,
           let array = sheets as? [AXUIElement], !array.isEmpty { throw AutomationFailure(message: "シートを検出しました。") }
    }
    private func presentationID(_ string: String) -> String? {
        guard let url = URL(string: string), url.scheme == "https", url.host == "docs.google.com" else { return nil }
        let parts = url.path.split(separator: "/")
        guard parts.count >= 3, parts[0] == "presentation", parts[1] == "d", !parts[2].isEmpty else { return nil }
        return String(parts[2])
    }
    private func verifySlides(_ app: NSRunningApplication, expectedURL: String) throws {
        try verifyFrontmost(app)
        guard let expected = presentationID(expectedURL) else { throw AutomationFailure(message: "対象のGoogleスライドURLを設定してください。") }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { throw AutomationFailure(message: "Chromeのウィンドウを確認できません。") }
        let window = unsafeBitCast(value, to: AXUIElement.self)
        var document: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXDocumentAttribute as CFString, &document) == .success,
              let documentURL = document as? String, presentationID(documentURL) == expected else {
            throw AutomationFailure(message: "Chromeの対象タブを確認できません。設定したスライドを前面で開いてください。AXDocumentを取得できないChrome環境では貼り付けを停止します。")
        }
    }
    private func sendKey(_ code: Int, flags: CGEventFlags, app: NSRunningApplication) throws {
        try verifyFrontmost(app)
        guard (0...127).contains(code),
              let down = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: false) else {
            throw AutomationFailure(message: "キーイベントを作成できません。")
        }
        down.flags = flags; up.flags = flags
        down.postToPid(app.processIdentifier); up.postToPid(app.processIdentifier)
    }
    private func flags(_ s: AutomationSettings) -> CGEventFlags {
        var result: CGEventFlags = []
        if s.command { result.insert(.maskCommand) }
        if s.option { result.insert(.maskAlternate) }
        if s.shift { result.insert(.maskShift) }
        if s.control { result.insert(.maskControl) }
        return result
    }
    func start(capture: CaptureModel, transfer: Bool, chromeKeyTest: Bool = false) {
        guard !running, !capture.busy else { return }
        if transfer && pasteUncertain { capture.record("前回の貼り付け結果を手動確認し、確認済みボタンを押してください。"); return }
        let config = settings
        guard config.switchDelay.isFinite, config.pasteDelay.isFinite,
              (0...60).contains(config.switchDelay), (0...60).contains(config.pasteDelay) else {
            capture.record("待機時間は0〜60秒にしてください。"); return
        }
        save(); running = true; paused = false; progress = 0; started = Date()
        task = Task {
            defer { self.running = false; self.paused = false; self.task = nil }
            do {
                _ = try application(chromeKeyTest ? "com.google.Chrome" : config.kindleID)
                if transfer {
                    _ = try application("com.google.Chrome")
                    guard CGPreflightScreenCaptureAccess(), capture.selected != nil else { throw AutomationFailure(message: "画面収録権限と保存済み範囲が必要です。") }
                    guard presentationID(config.presentationURL) != nil else { throw AutomationFailure(message: "有効なGoogleスライドURLを設定してください。") }
                }
                operation = chromeKeyTest ? "Chromeへ切り替え" : "Kindleへ切り替え"; capture.record(operation)
                let kindle = try await activate(chromeKeyTest ? "com.google.Chrome" : config.kindleID, delay: config.switchDelay)
                progress = 0.2
                if transfer {
                    operation = "キャプチャ"; capture.record(operation)
                    capture.preview = nil
                    await capture.capture()
                    try await checkpoint()
                    guard let image = capture.preview else { throw AutomationFailure(message: "キャプチャに失敗したため停止しました。") }
                    try verifyFrontmost(kindle)
                    operation = "画像をクリップボードへコピー"
                    let board = NSPasteboard.general
                    board.clearContents()
                    guard board.writeObjects([image]) else { throw AutomationFailure(message: "クリップボードへのコピーに失敗しました。") }
                    let changeCount = board.changeCount
                    progress = 0.6
                    operation = "Chromeへ切り替え"; capture.record(operation)
                    let chrome = try await activate("com.google.Chrome", delay: config.switchDelay)
                    try await checkpoint()
                    try verifySlides(chrome, expectedURL: config.presentationURL)
                    guard board.changeCount == changeCount else { throw AutomationFailure(message: "クリップボードが変更されたため停止しました。") }
                    // Persist before emitting a non-idempotent action; never retry automatically.
                    pasteUncertain = true; UserDefaults.standard.set(true, forKey: "pasteUncertain")
                    operation = "貼り付けキー送信"
                    try sendKey(9, flags: [.maskCommand], app: chrome)
                    capture.record("Command + Vを送信しました。貼り付け結果はGoogleスライドで手動確認してください。")
                    try await wait(config.pasteDelay)
                    operation = "貼り付け結果の手動確認待ち"
                } else {
                    try await checkpoint()
                    operation = chromeKeyTest ? "Chromeへ下矢印を送信" : "Kindleへ設定したキーを送信"
                    if chromeKeyTest { try verifySlides(kindle, expectedURL: config.presentationURL) }
                    try sendKey(chromeKeyTest ? 125 : config.keyCode, flags: chromeKeyTest ? [] : flags(config), app: kindle)
                    capture.record(chromeKeyTest ? "下矢印を送信しました。スライド送りの結果を確認してください。" : "設定したキーを送信しました。Kindleの結果を確認してください。")
                    operation = "キー送信終了"
                }
                progress = 1
            } catch is CancellationError {
                operation = "停止"; capture.record("停止しました。送信済みのキー操作は取り消せません。")
            } catch {
                errors += 1; operation = "エラーで停止"; capture.record(error.localizedDescription)
            }
        }
    }
}
