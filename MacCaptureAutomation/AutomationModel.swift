import AppKit
import SwiftUI
import ApplicationServices
import CryptoKit
import Carbon

private final class AutomationHotkeys {
    private var eventHandler: EventHandlerRef?
    private var keys: [EventHotKeyRef] = []
    private let action: (UInt32) -> Void
    private(set) var available = false
    init(action: @escaping (UInt32) -> Void) {
        self.action = action
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                          nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard result == noErr, identifier.signature == OSType(0x4D434148) else { return OSStatus(eventNotHandledErr) }
            let controller = Unmanaged<AutomationHotkeys>.fromOpaque(context).takeUnretainedValue()
            let id = identifier.id
            DispatchQueue.main.async { controller.action(id) }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        guard installed == noErr else { return }
        let registrations: [(UInt32, UInt32)] = [(35, 1), (1, 2)]
        for (code, id) in registrations {
            var reference: EventHotKeyRef?
            let result = RegisterEventHotKey(code, UInt32(cmdKey | optionKey | controlKey),
                                            EventHotKeyID(signature: OSType(0x4D434148), id: id),
                                            GetApplicationEventTarget(), 0, &reference)
            guard result == noErr, let reference else { invalidate(); return }
            keys.append(reference)
        }
        available = true
    }
    private func invalidate() {
        for key in keys { UnregisterEventHotKey(key) }
        keys.removeAll()
        if let eventHandler { RemoveEventHandler(eventHandler) }
        eventHandler = nil; available = false
    }
    deinit { invalidate() }
}

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

enum SlideNavigationMode: String, CaseIterable, Identifiable {
    case existing, duplicate, add
    var id: String { rawValue }
    var title: String {
        switch self {
        case .existing: return "既存スライドへ移動（↓）"
        case .duplicate: return "現在のスライドを複製（Command + D）"
        case .add: return "新規スライドを追加（空白）"
        }
    }
    var keyCode: Int? {
        switch self { case .existing: return 125; case .duplicate: return 2; case .add: return nil }
    }
    var flags: CGEventFlags { self == .existing ? [] : [.maskCommand] }
}

struct ConfirmedPlan: Codable {
    var target = 10
    var completed = 0
    var active = false
    static func restore() -> ConfirmedPlan {
        guard let data = UserDefaults.standard.data(forKey: "confirmedPlan.v1"),
              let value = try? JSONDecoder().decode(ConfirmedPlan.self, from: data),
              (1...1000).contains(value.target), (0...value.target).contains(value.completed) else { return ConfirmedPlan() }
        return value
    }
}

struct AutomationFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct LayoutDisplay: Codable, Equatable {
    var id: UInt32
    var frame: SavedRect
    var scale: Double
}
struct WindowLayout: Codable {
    var kindleID: String
    var presentationURL: String
    var kindle: SavedRect
    var chrome: SavedRect
    var displays: [LayoutDisplay]
    static func restore() -> WindowLayout? {
        guard let data = UserDefaults.standard.data(forKey: "windowLayout.v1") else { return nil }
        return try? JSONDecoder().decode(WindowLayout.self, from: data)
    }
}

@MainActor
final class AutomationModel: ObservableObject {
    @Published var settings = AutomationSettings()
    @Published private(set) var procedureResultPending = UserDefaults.standard.bool(forKey: "procedureResultPending.v1")
    @Published private(set) var awaitingProcedureResult = false
    @Published private(set) var procedureStatus = UserDefaults.standard.string(forKey: "procedureResultStage.v1") ?? "手順実行は待機中"
    @Published private(set) var running = false
    @Published private(set) var globalShortcutsAvailable = false
    @Published private(set) var windowLayout = WindowLayout.restore()
    @Published private(set) var layoutNeedsReview = UserDefaults.standard.bool(forKey: "layoutNeedsReview.v1")
    @Published var continuousPages = 2
    @Published private(set) var continuousDispatchedPages = 0
    @Published private(set) var continuousRunning = false
    @Published private(set) var continuousTargetPages = 0
    @Published private(set) var continuousCurrentPage = 0
    @Published private(set) var activeElapsed = 0.0
    var estimatedRemainingSeconds: Int? {
        guard continuousRunning, continuousDispatchedPages > 0, progress > 0, progress < 1 else { return nil }
        return Int(ceil(activeElapsed * (1 - progress) / progress))
    }
    @Published private(set) var paused = false
    @Published private(set) var operation = "待機中"
    @Published private(set) var elapsed = 0.0
    @Published private(set) var errors = 0
    @Published private(set) var progress = 0.0
    @Published private(set) var pasteUncertain = false
    @Published private(set) var backgroundUncertain = false
    @Published private(set) var readyForNextPage = UserDefaults.standard.bool(forKey: "readyForNextPage.v1")
    @Published private(set) var navigationUncertain = UserDefaults.standard.bool(forKey: "navigationUncertain.v1")
    @Published private(set) var navigationStage = UserDefaults.standard.string(forKey: "navigationStage.v1") ?? "未実行"
    @Published private(set) var plan = ConfirmedPlan.restore()
    @Published var requestedPages = 10
    @Published var slideNavigationMode = SlideNavigationMode(rawValue: UserDefaults.standard.string(forKey: "slideNavigationMode.v1") ?? "existing") ?? .existing
    private var pendingPlanPage = UserDefaults.standard.bool(forKey: "pendingPlanPage.v1")
    @Published var menuShortcut = UserDefaults.standard.integer(forKey: "backgroundMenuShortcut.v1")
    private var task: Task<Void, Never>?
    private var started: Date?
    private var pauseStarted: Date?
    private var pausedDuration = 0.0
    private var hotkeys: AutomationHotkeys?
    private var lastTargetApplication: NSRunningApplication?
    private var lastTargetWindow: AXUIElement?
    private var resumePresentationURL = ""
    private var needsResumeActivation = false
    private var restoringResumeFocus = false
    private let storageKey = "automationSettings.v1"
    private var combinedBackgroundPending = UserDefaults.standard.bool(forKey: "combinedBackgroundPending.v1")

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
        backgroundUncertain = UserDefaults.standard.bool(forKey: "backgroundUncertain")
        hotkeys = AutomationHotkeys { [weak self] id in
            Task { @MainActor [weak self] in
                guard let self, self.running else { return }
                if id == 1 {
                    if self.paused { self.resume() } else { self.pause() }
                } else if id == 2 { self.stop() }
            }
        }
        globalShortcutsAvailable = hotkeys?.available == true
    }
    func save() {
        UserDefaults.standard.set(menuShortcut, forKey: "backgroundMenuShortcut.v1")
        UserDefaults.standard.set(slideNavigationMode.rawValue, forKey: "slideNavigationMode.v1")
        if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: storageKey) }
    }
    func acknowledgePaste() {
        guard !running, !backgroundUncertain else { return }
        pendingPlanPage = false
        UserDefaults.standard.set(false, forKey: "pendingPlanPage.v1")
        combinedBackgroundPending = false
        UserDefaults.standard.set(false, forKey: "combinedBackgroundPending.v1")
        pasteUncertain = false
        UserDefaults.standard.set(false, forKey: "pasteUncertain")
    }
    func acknowledgeBackground(capture: CaptureModel) {
        guard !running, backgroundUncertain else { return }
        backgroundUncertain = false
        UserDefaults.standard.set(false, forKey: "backgroundUncertain")
        if combinedBackgroundPending {
            if pendingPlanPage && plan.active {
                plan.completed += 1
                if plan.completed >= plan.target { plan.active = false }
                persistPlan()
                capture.record("確認済みページ: \(plan.completed) / \(plan.target)\(plan.active ? "" : "。指定ページ数が完了しました。")")
            }
            readyForNextPage = !(pendingPlanPage && plan.completed >= plan.target)
            UserDefaults.standard.set(readyForNextPage, forKey: "readyForNextPage.v1")
            pendingPlanPage = false
            UserDefaults.standard.set(false, forKey: "pendingPlanPage.v1")
            pasteUncertain = false
            combinedBackgroundPending = false
            UserDefaults.standard.set(false, forKey: "pasteUncertain")
            UserDefaults.standard.set(false, forKey: "combinedBackgroundPending.v1")
        }
        capture.record("背景設定の結果をユーザーが確認しました。自動判定による成功ではありません。")
    }
    func pause() { guard running, !paused else { return }; pauseStarted = Date(); paused = true }
    func resume() {
        guard running, paused else { return }
        finishPauseAccounting()
        needsResumeActivation = true
        paused = false
    }
    func stop() { task?.cancel(); finishPauseAccounting(); paused = false; needsResumeActivation = false }
    private func finishPauseAccounting() {
        if let pauseStarted { pausedDuration += Date().timeIntervalSince(pauseStarted) }
        pauseStarted = nil
    }
    private func updateElapsed() {
        elapsed = started.map { Date().timeIntervalSince($0) } ?? 0
        let currentPause = pauseStarted.map { Date().timeIntervalSince($0) } ?? 0
        activeElapsed = max(0, elapsed - pausedDuration - currentPause)
    }
    private func resetExecutionFocus() {
        lastTargetApplication = nil; lastTargetWindow = nil
        needsResumeActivation = false; restoringResumeFocus = false
        resumePresentationURL = settings.presentationURL
        pauseStarted = nil; pausedDuration = 0; elapsed = 0; activeElapsed = 0
        continuousRunning = false
    }
    private func focusedWindow(_ app: NSRunningApplication) throws -> AXUIElement {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            throw AutomationFailure(message: "再開対象のウィンドウを確認できません。")
        }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private func checkpoint() async throws {
        try Task.checkCancellation()
        updateElapsed()
        while paused {
            try await Task.sleep(nanoseconds: 50_000_000)
            try Task.checkCancellation()
            updateElapsed()
        }
        if needsResumeActivation && !restoringResumeFocus {
            needsResumeActivation = false
            guard let target = lastTargetApplication, let id = target.bundleIdentifier else { return }
            guard !target.isTerminated, try application(id).processIdentifier == target.processIdentifier else {
                throw AutomationFailure(message: "一時停止中に対象アプリが終了・再起動しました。自動再開しません。")
            }
            let expectedWindow = lastTargetWindow
            restoringResumeFocus = true
            defer { restoringResumeFocus = false }
            let app = try await activate(id, delay: settings.switchDelay)
            if let expectedWindow, !CFEqual(try focusedWindow(app), expectedWindow) {
                throw AutomationFailure(message: "一時停止中に対象ウィンドウが変わりました。自動再開しません。")
            }
            if id == "com.google.Chrome", presentationID(resumePresentationURL) != nil {
                try verifySlides(app, expectedURL: resumePresentationURL)
            }
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
        if lastTargetApplication?.processIdentifier != app.processIdentifier { lastTargetWindow = nil }
        lastTargetApplication = app
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier {
            // This app can be in the background after capturing Kindle. Ask
            // Launch Services to activate the existing target application.
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else {
                throw AutomationFailure(message: "アプリの場所を確認できません: \(id)")
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.createsNewApplicationInstance = false
            configuration.addsToRecentItems = false
            if NSApp.isActive { NSApp.yieldActivation(to: app) }
            let opened: NSRunningApplication = try await withCheckedThrowingContinuation { continuation in
                NSWorkspace.shared.openApplication(at: url, configuration: configuration) { application, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let application { continuation.resume(returning: application) }
                    else { continuation.resume(throwing: AutomationFailure(message: "アプリ切り替え要求の結果を取得できません: \(id)")) }
                }
            }
            try await checkpoint()
            guard opened.processIdentifier == app.processIdentifier else {
                throw AutomationFailure(message: "対象アプリのプロセスが変わったため停止しました: \(id)")
            }
            var attempts = 0
            while NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier {
                try await wait(0.05)
                attempts += 1
                if app.isTerminated || attempts >= 100 {
                    let front = NSWorkspace.shared.frontmostApplication
                    let frontName = front?.localizedName ?? "不明"
                    let frontID = front?.bundleIdentifier ?? "不明"
                    throw AutomationFailure(message: "対象アプリを前面にできません: \(id)。現在の前面アプリ: \(frontName)（\(frontID)）。キーは送信していません。")
                }
            }
        }
        try await wait(delay)
        try verifyFrontmost(app)
        lastTargetWindow = try focusedWindow(app)
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
    func start(capture: CaptureModel, transfer: Bool, chromeKeyTest: Bool = false, setBackground: Bool = false, planRun: Bool = false) {
        guard !running, !capture.busy, !procedureResultPending, !layoutNeedsReview else { return }
        if transfer && plan.active && !planRun { capture.record("指定ページ数の処理中です。『続きの1ページを実行』を使用してください。"); return }
        if transfer && (readyForNextPage || navigationUncertain) {
            capture.record("先に次スライド・次ページへの移動と結果確認を完了してください。"); return
        }
        if transfer && backgroundUncertain { capture.record("背景設定の結果を先に確認してください。"); return }
        if transfer && pasteUncertain { capture.record("前回の貼り付け結果を手動確認し、確認済みボタンを押してください。"); return }
        let config = settings
        let shortcut = menuShortcut
        guard config.switchDelay.isFinite, config.pasteDelay.isFinite,
              (0...60).contains(config.switchDelay), (0...60).contains(config.pasteDelay) else {
            capture.record("待機時間は0〜60秒にしてください。"); return
        }
        if setBackground && !(0...2).contains(shortcut) {
            capture.record("メニュー表示キーを設定してください。"); return
        }
        resetExecutionFocus(); save(); running = true; paused = false; progress = 0; started = Date()
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
                    combinedBackgroundPending = setBackground
                    UserDefaults.standard.set(setBackground, forKey: "combinedBackgroundPending.v1")
                    pendingPlanPage = planRun && plan.active && setBackground
                    UserDefaults.standard.set(pendingPlanPage, forKey: "pendingPlanPage.v1")
                    operation = "貼り付けキー送信"
                    try sendKey(9, flags: [.maskCommand], app: chrome)
                    capture.record("Command + Vを送信しました。貼り付け結果はGoogleスライドで手動確認してください。")
                    try await wait(config.pasteDelay)
                    if setBackground {
                        progress = 0.7
                        try await performBackground(capture: capture, chrome: chrome, config: config, shortcut: shortcut, manualMenu: false)
                    } else {
                        operation = "貼り付け結果の手動確認待ち"
                    }
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


extension AutomationModel {
    private func axValue(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }
    private func axString(_ element: AXUIElement, _ attribute: String) -> String {
        axValue(element, attribute) as? String ?? ""
    }
    private func axElements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        axValue(element, attribute) as? [AXUIElement] ?? []
    }
    private func focusedElement(_ app: AXUIElement) -> AXUIElement? {
        guard let value = axValue(app, "AXFocusedUIElement"), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }
    private func selectedImage(_ application: AXUIElement) async throws -> Bool {
        guard let focused = focusedElement(application) else { return false }
        var pending = [focused] + axElements(focused, "AXSelectedChildren")
        var visited: [AXUIElement] = []
        while let element = pending.popLast(), visited.count < 400 {
            if visited.contains(where: { CFEqual($0, element) }) { continue }
            visited.append(element)
            if visited.count % 20 == 0 { try await checkpoint(); await Task.yield() }
            let role = axString(element, "AXRole")
            let selected = (axValue(element, "AXSelected") as? Bool) == true
            if role == "AXImage", selected || CFEqual(element, focused) { return true }
            pending.append(contentsOf: axElements(element, "AXSelectedChildren"))
            pending.append(contentsOf: axElements(element, "AXChildren"))
        }
        return false
    }
    private func backgroundMenuItems(_ application: AXUIElement) async throws -> [AXUIElement] {
        var pending = [application]
        var visited: [AXUIElement] = []
        var matches: [AXUIElement] = []
        while let element = pending.popLast() {
            if visited.contains(where: { CFEqual($0, element) }) { continue }
            visited.append(element)
            if visited.count > 2500 { throw AutomationFailure(message: "ChromeのAccessibility探索上限に達しました。メニューを手動で開くテストを試してください。") }
            if visited.count % 25 == 0 { try await checkpoint(); await Task.yield() }
            let title = axString(element, "AXTitle").trimmingCharacters(in: .whitespacesAndNewlines)
            if axString(element, "AXRole") == "AXMenuItem",
               ["画像を背景に設定", "Set image as background"].contains(title),
               (axValue(element, "AXEnabled") as? Bool) == true {
                matches.append(element)
            }
            pending.append(contentsOf: axElements(element, "AXChildren"))
        }
        return matches
    }
    private func parentMenu(_ item: AXUIElement) -> AXUIElement? {
        var current = item
        for _ in 0..<12 {
            guard let value = axValue(current, "AXParent"), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            current = unsafeBitCast(value, to: AXUIElement.self)
            if axString(current, "AXRole") == "AXMenu" { return current }
        }
        return nil
    }
    private func keyboardSelectedMenuItems(_ menu: AXUIElement, application: AXUIElement) -> [AXUIElement] {
        var candidates = axElements(menu, "AXSelectedChildren")
        for source in [application, AXUIElementCreateSystemWide()] {
            if var focused = focusedElement(source) {
                for _ in 0..<12 {
                    if axString(focused, "AXRole") == "AXMenuItem" { candidates.append(focused); break }
                    guard let value = axValue(focused, "AXParent"), CFGetTypeID(value) == AXUIElementGetTypeID() else { break }
                    focused = unsafeBitCast(value, to: AXUIElement.self)
                }
            }
        }
        var pending = axElements(menu, "AXChildren")
        var visited: [AXUIElement] = []
        while let element = pending.popLast(), visited.count < 250 {
            if visited.contains(where: { CFEqual($0, element) }) { continue }
            visited.append(element)
            let role = axString(element, "AXRole")
            if role == "AXMenu" { continue } // Do not confuse a submenu highlight with this menu.
            if role == "AXMenuItem", (axValue(element, "AXSelected") as? Bool) == true || (axValue(element, "AXFocused") as? Bool) == true {
                candidates.append(element)
            }
            pending.append(contentsOf: axElements(element, "AXChildren"))
        }
        var unique: [AXUIElement] = []
        for candidate in candidates {
            guard axString(candidate, "AXRole") == "AXMenuItem", let parent = parentMenu(candidate), CFEqual(parent, menu),
                  !unique.contains(where: { CFEqual($0, candidate) }) else { continue }
            unique.append(candidate)
        }
        return unique
    }
    private func executeBackgroundWithKeyboard(capture: CaptureModel, chrome: NSRunningApplication,
                                               application: AXUIElement, expectedURL: String) async throws {
        capture.record("背景メニューを上矢印で末尾側から探索します。")
        var lastSelection = ""
        var unreadableSelections = 0
        for index in 0..<80 {
            try await checkpoint()
            try verifySlides(chrome, expectedURL: expectedURL)
            let liveItems = try await backgroundMenuItems(application)
            guard liveItems.count == 1, let target = liveItems.first, let menu = parentMenu(target) else {
                throw AutomationFailure(message: "背景設定メニューが閉じたか、対象を確認できなくなりました。Enterは送信していません。")
            }
            let selected = keyboardSelectedMenuItems(menu, application: application)
            unreadableSelections = selected.isEmpty ? unreadableSelections + 1 : 0
            if unreadableSelections >= 5 {
                var attributes: CFArray?
                AXUIElementCopyAttributeNames(target, &attributes)
                let names = (attributes as? [String] ?? []).joined(separator: ", ")
                throw AutomationFailure(message: "Chromeのメニュー選択状態を取得できません。Enterもクリックも送信していません。背景項目の公開属性: \(names)")
            }
            let selection = selected.map { axString($0, "AXTitle") }.joined(separator: ", ")
            if selection != lastSelection {
                capture.record("背景メニューの選択項目：\(selection.isEmpty ? "取得できません" : selection)")
                lastSelection = selection
            }
            if selected.count == 1, CFEqual(selected[0], target) {
                // Re-read immediately before Enter. Never execute by an assumed row number.
                try verifySlides(chrome, expectedURL: expectedURL)
                let confirmed = keyboardSelectedMenuItems(menu, application: application)
                guard confirmed.count == 1, CFEqual(confirmed[0], target), (axValue(target, "AXEnabled") as? Bool) == true else {
                    throw AutomationFailure(message: "背景設定項目の選択が変わりました。Enterは送信していません。")
                }
                backgroundUncertain = true
                UserDefaults.standard.set(true, forKey: "backgroundUncertain")
                try sendKey(36, flags: [], app: chrome)
                capture.record("背景設定項目の選択を確認し、Enterを送信しました。マウスクリックは使用していません。")
                return
            }
            if index == 79 { break }
            try sendKey(126, flags: [], app: chrome)
            try await wait(0.08)
        }
        throw AutomationFailure(message: "方向キーで背景設定項目の選択を確認できません。ChromeがAXSelected・AXFocused等を公開していない可能性があります。Enterもマウスクリックも送信していません。")
    }
    private func menuClickEvents(_ item: AXUIElement, newSlide: Bool = false, layoutTarget: String? = nil) throws -> (CGEvent, CGEvent) {
        let targetName = layoutTarget ?? (newSlide ? "新しいスライドのボタン" : "背景設定項目")
        let labels = [axString(item, "AXTitle"), axString(item, "AXDescription")] + (layoutTarget == nil ? [] : [axString(item, "AXHelp")])
        let expected = layoutTarget == "レイアウト" ? ["レイアウト", "レイアウトを適用", "スライドのレイアウト", "Layout", "Apply layout", "Slide layout"] :
            layoutTarget == "空白" ? ["空白", "Blank"] :
            newSlide ? ["新しいスライド", "新規スライド", "New slide"] : ["画像を背景に設定", "Set image as background"]
        let roles = layoutTarget == "レイアウト" ? ["AXButton", "AXPopUpButton", "AXMenuButton", "AXMenuBarItem", "AXMenuItem"] :
            layoutTarget == "空白" ? ["AXMenuItem", "AXButton", "AXRadioButton"] :
            [newSlide ? "AXButton" : "AXMenuItem"]
        let named = labels.contains { label in
            let text = label.trimmingCharacters(in: .whitespacesAndNewlines)
            return expected.contains { name in
                text == name || ((newSlide || layoutTarget != nil) && (text.hasPrefix(name + " (") || text.hasPrefix(name + "（")))
            }
        }
        guard roles.contains(axString(item, "AXRole")), named,
              (axValue(item, "AXEnabled") as? Bool) == true,
              let positionValue = axValue(item, "AXPosition"),
              let sizeValue = axValue(item, "AXSize"),
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            throw AutomationFailure(message: "\(targetName)の有効状態・位置・サイズを確認できません。クリックしていません。")
        }
        let position = unsafeBitCast(positionValue, to: AXValue.self)
        let size = unsafeBitCast(sizeValue, to: AXValue.self)
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &point),
              AXValueGetValue(size, .cgSize, &dimensions),
              point.x.isFinite, point.y.isFinite,
              dimensions.width.isFinite, dimensions.height.isFinite,
              dimensions.width > 0, dimensions.height > 0 else {
            throw AutomationFailure(message: "\(targetName)の座標が無効です。クリックしていません。")
        }
        // AXPosition and CGEvent both use global top-left point coordinates.
        let center = CGPoint(x: point.x + dimensions.width / 2, y: point.y + dimensions.height / 2)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(center.x), Float(center.y), &hit) == .success,
              var current = hit else {
            throw AutomationFailure(message: "\(targetName)の位置をヒットテストで確認できません。クリックしていません。")
        }
        var matches = false
        for _ in 0..<12 {
            if CFEqual(current, item) { matches = true; break }
            guard let parent = axValue(current, "AXParent"), CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            current = unsafeBitCast(parent, to: AXUIElement.self)
        }
        guard matches else {
            throw AutomationFailure(message: "\(targetName)の位置が別の要素に重なっています。クリックしていません。")
        }
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: center, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: center, mouseButton: .left) else {
            throw AutomationFailure(message: "クリックイベントを作成できません。")
        }
        down.setIntegerValueField(.mouseEventClickState, value: 1)
        up.setIntegerValueField(.mouseEventClickState, value: 1)
        return (down, up)
    }
    private func performBackground(capture: CaptureModel, chrome: NSRunningApplication, config: AutomationSettings, shortcut: Int, manualMenu: Bool) async throws {
        try verifySlides(chrome, expectedURL: config.presentationURL)
        let application = AXUIElementCreateApplication(chrome.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.5)
        if manualMenu {
            operation = "5秒以内に選択画像を右クリックしてください"; capture.record(operation)
            try await wait(5)
        } else {
            operation = "画像選択状態を確認"
            if try await selectedImage(application) {
                capture.record("Accessibility APIで選択画像を確認しました。")
            } else {
                capture.record("画像選択情報は取得できません。メニュー表示後の有効な背景設定項目を確認してから実行します。")
            }
            try await checkpoint()
            try verifySlides(chrome, expectedURL: config.presentationURL)
            operation = "画像のコンテキストメニューを自動表示"
            switch shortcut {
            case 0:
                try sendKey(109, flags: [.maskShift], app: chrome)
                capture.record("メニュー表示キー: Shift + F10")
            case 1:
                try sendKey(42, flags: [.maskCommand, .maskShift], app: chrome)
                capture.record("メニュー表示キー: Command + Shift + バックスラッシュ")
            case 2:
                try sendKey(42, flags: [.maskControl, .maskShift], app: chrome)
                capture.record("メニュー表示キー: Control + Shift + バックスラッシュ")
            default:
                throw AutomationFailure(message: "メニュー表示キーの設定が無効です。")
            }
            try await wait(1)
        }
        if !continuousRunning { progress = max(progress, 0.8) }
        try verifySlides(chrome, expectedURL: config.presentationURL)
        operation = "背景設定メニューを検索"
        let items = try await backgroundMenuItems(application)
        guard items.count == 1, let item = items.first else {
            throw AutomationFailure(message: "有効な『画像を背景に設定』メニューを一意に取得できません（\(items.count)件）。画像を選択し、メニュー表示キーを変更して試してください。手動メニュー方式も利用できます。背景設定操作は実行していません。")
        }
        var actions: CFArray?
        let actionReadResult = AXUIElementCopyActionNames(item, &actions)
        let names = actionReadResult == .success ? (actions as? [String] ?? []) : []
        // Chrome menu items can expose AXConfirm, AXPick, or AXPress.
        // AXShowMenu and AXCancel must never be treated as selection actions.
        let action = ["AXConfirm", "AXPick", "AXPress"].first(where: { names.contains($0) })
        capture.record("背景設定メニューの公開操作: \(names.joined(separator: ", "))。使用操作: \(action ?? "方向キー＋選択確認＋Enter（マウスなし）")")
        try await checkpoint()
        try verifySlides(chrome, expectedURL: config.presentationURL)
        operation = "背景設定メニューを実行"
        if let action {
            backgroundUncertain = true
            UserDefaults.standard.set(true, forKey: "backgroundUncertain")
            let result = AXUIElementPerformAction(item, action as CFString)
            guard result == .success else {
                throw AutomationFailure(message: "背景設定メニューの実行結果が不明です（AXエラー \(result.rawValue)）。再実行せず、スライドを手動確認してください。")
            }
            capture.record("\(action)要求が受理されました。背景化の成功はまだ未確認です。")
        } else {
            try await executeBackgroundWithKeyboard(capture: capture, chrome: chrome, application: application, expectedURL: config.presentationURL)
        }
        try await wait(0.5)
        try verifySlides(chrome, expectedURL: config.presentationURL)
        let remaining = try await backgroundMenuItems(application)
        guard remaining.isEmpty else {
            throw AutomationFailure(message: "背景設定後もメニューが残っています。再実行せず、結果を手動確認してください。")
        }
        if !continuousRunning { progress = 1 }
        operation = "背景設定結果の手動確認待ち"
        capture.record("メニューが閉じました。選択枠が消え、画像が実際の背景になったか確認してください。メニュー閉鎖だけでは成功判定しません。")
    }
    func testBackground(capture: CaptureModel, manualMenu: Bool = false) {
        guard !running, !capture.busy, !procedureResultPending else { return }
        guard !backgroundUncertain else { capture.record("前回の背景設定の結果を確認してから再テストしてください。"); return }
        let config = settings
        let shortcut = menuShortcut
        guard config.switchDelay.isFinite, (0...60).contains(config.switchDelay),
              presentationID(config.presentationURL) != nil else {
            capture.record("対象のGoogleスライドURLと0〜60秒の切り替え待機を設定してください。"); return
        }
        resetExecutionFocus(); save(); running = true; paused = false; progress = 0; started = Date()
        task = Task {
            defer { self.running = false; self.paused = false; self.task = nil }
            do {
                operation = "背景設定テスト：Chromeへ切り替え"; capture.record(operation)
                let chrome = try await activate("com.google.Chrome", delay: config.switchDelay)
                try await performBackground(capture: capture, chrome: chrome, config: config, shortcut: shortcut, manualMenu: manualMenu)
            } catch is CancellationError {
                operation = "背景設定テスト停止"; capture.record("背景設定テストを停止しました。実行済みの操作は取り消せません。")
            } catch {
                errors += 1; operation = "背景設定テスト：エラーで停止"; capture.record(error.localizedDescription)
            }
        }
    }
}


extension AutomationModel {
    private func newSlideButton(_ application: AXUIElement) async throws -> AXUIElement {
        var queue = [application]
        var visited: [AXUIElement] = []
        var index = 0
        var matches: [AXUIElement] = []
        while index < queue.count, visited.count < 2500 {
            let element = queue[index]; index += 1
            if visited.contains(where: { CFEqual($0, element) }) { continue }
            visited.append(element)
            if visited.count % 25 == 0 { try await checkpoint(); await Task.yield() }
            if axString(element, "AXRole") == "AXButton",
               (axValue(element, "AXEnabled") as? Bool) == true {
                let labels = [axString(element, "AXTitle"), axString(element, "AXDescription")]
                let expected = ["新しいスライド", "新規スライド", "New slide"]
                let named = labels.contains { label in
                    let text = label.trimmingCharacters(in: .whitespacesAndNewlines)
                    return expected.contains { name in
                        text == name || text.hasPrefix(name + " (") || text.hasPrefix(name + "（")
                    }
                }
                if named { matches.append(element) }
            }
            queue.append(contentsOf: axElements(element, "AXChildren"))
        }
        guard index >= queue.count else {
            throw AutomationFailure(message: "新しいスライドのボタン探索上限に達しました。追加操作は実行していません。複製モードか手動追加を使用してください。")
        }
        guard matches.count == 1, let button = matches.first else {
            throw AutomationFailure(message: "新しいスライドのボタンを一意に取得できません（\(matches.count)件）。追加操作は実行していません。複製モードか手動追加を使用してください。")
        }
        return button
    }
    private func layoutElement(_ application: AXUIElement, target: String) async throws -> AXUIElement {
        let names = target == "レイアウト" ? ["レイアウト", "レイアウトを適用", "スライドのレイアウト", "Layout", "Apply layout", "Slide layout"] : ["空白", "Blank"]
        let roles = target == "レイアウト" ? ["AXButton", "AXPopUpButton", "AXMenuButton", "AXMenuBarItem", "AXMenuItem"] : ["AXMenuItem", "AXButton", "AXRadioButton"]
        var queue = [application]
        var visited: [AXUIElement] = []
        var index = 0
        var matches: [AXUIElement] = []
        var diagnostics: [String] = []
        while index < queue.count, visited.count < 2500 {
            let element = queue[index]; index += 1
            if visited.contains(where: { CFEqual($0, element) }) { continue }
            visited.append(element)
            if visited.count % 25 == 0 { try await checkpoint(); await Task.yield() }
            let labels = [axString(element, "AXTitle"), axString(element, "AXDescription"), axString(element, "AXHelp")]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            let hints = labels.filter { $0.contains("レイアウト") || $0.lowercased().contains("layout") || $0 == "空白" || $0 == "Blank" }
            if !hints.isEmpty, diagnostics.count < 8 {
                let role = axString(element, "AXRole")
                let enabled = (axValue(element, "AXEnabled") as? Bool).map { $0 ? "有効" : "無効" } ?? "有効属性なし"
                diagnostics.append("\(role)／\(enabled)／\(hints.map { String($0.prefix(80)) }.joined(separator: ", "))")
            }
            if roles.contains(axString(element, "AXRole")),
               (axValue(element, "AXEnabled") as? Bool) == true,
               labels.contains(where: { text in names.contains { name in text == name || text.hasPrefix(name + " (") || text.hasPrefix(name + "（") } }) { matches.append(element) }
            queue.append(contentsOf: axElements(element, "AXChildren"))
        }
        guard index >= queue.count, matches.count == 1, let item = matches.first else {
            throw AutomationFailure(message: "『\(target)』を一意に取得できません（\(matches.count)件）。新規スライドは追加済みの可能性があります。Kindleは送っていません。Chromeで手動でレイアウト→空白を選び、位置を確認してください。候補: \(diagnostics.isEmpty ? "なし" : diagnostics.joined(separator: " | "))")
        }
        return item
    }
    private func applyBlankLayout(capture: CaptureModel, chrome: NSRunningApplication, expectedURL: String) async throws {
        let application = AXUIElementCreateApplication(chrome.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.5)
        for target in ["レイアウト", "空白"] {
            try await checkpoint()
            try verifySlides(chrome, expectedURL: expectedURL)
            operation = "新規スライド：\(target)を選択"
            let item = try await layoutElement(application, target: target)
            try await checkpoint()
            try verifySlides(chrome, expectedURL: expectedURL)
            // Use the dynamic, hit-tested click already validated for Chrome.
            let (down, up) = try menuClickEvents(item, layoutTarget: target)
            setNavigationStage("新規スライド追加済み・\(target)操作予定・Kindle未送信")
            down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
            capture.record("AXで検証した『\(target)』をクリックしました。")
            try await wait(0.5)
        }
        setNavigationStage("空白レイアウトの設定要求済み・結果未確認・Kindle未送信")
        capture.record("タイトル入力欄がない空白レイアウトになったか手動確認してください。")
    }
    private func focusedSlideList(_ application: AXUIElement) throws -> (AXUIElement, AXUIElement) {
        guard var current = focusedElement(application) else {
            throw AutomationFailure(message: "Chromeのフォーカスを取得できません。左側のスライド一覧をクリックしてください。")
        }
        for _ in 0..<12 {
            let role = axString(current, "AXRole")
            if role == "AXTextField" || role == "AXTextArea" {
                throw AutomationFailure(message: "文字編集中です。左側のスライド一覧をクリックしてください。")
            }
            if ["AXList", "AXOutline"].contains(role) {
                let selected = axElements(current, "AXSelectedChildren")
                if selected.count == 1, let slide = selected.first {
                    let labels = [axString(current, "AXTitle"), axString(current, "AXDescription"),
                                  axString(slide, "AXTitle"), axString(slide, "AXDescription")].joined(separator: " ").lowercased()
                    if labels.contains("スライド") || labels.contains("slide") { return (current, slide) }
                }
            }
            guard let parent = axValue(current, "AXParent"), CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            current = unsafeBitCast(parent, to: AXUIElement.self)
        }
        throw AutomationFailure(message: "選択中のスライド一覧をAccessibility APIで確認できません。Chromeの左側のサムネイルをクリックしてください。取得できない環境ではページ送りを停止します。")
    }
    private func setNavigationStage(_ text: String) {
        navigationStage = text
        UserDefaults.standard.set(text, forKey: "navigationStage.v1")
    }
    func acknowledgeNavigation(capture: CaptureModel) {
        guard !running, readyForNextPage || navigationUncertain else { return }
        readyForNextPage = false; navigationUncertain = false
        UserDefaults.standard.set(false, forKey: "readyForNextPage.v1")
        UserDefaults.standard.set(false, forKey: "navigationUncertain.v1")
        setNavigationStage("両アプリの次ページを手動確認済み")
        capture.record("次スライドとKindleの次ページをユーザーが確認しました。次の1回実行が可能です。")
    }
    func advancePages(capture: CaptureModel) {
        guard !running, !capture.busy, readyForNextPage, !navigationUncertain,
              !pasteUncertain, !backgroundUncertain else { return }
        let config = settings
        let mode = slideNavigationMode
        guard config.switchDelay.isFinite, (0...60).contains(config.switchDelay), presentationID(config.presentationURL) != nil else {
            capture.record("対象URLと切り替え待機を確認してください。"); return
        }
        resetExecutionFocus(); save(); running = true; paused = false; progress = 0; started = Date()
        task = Task {
            defer { self.running = false; self.paused = false; self.task = nil }
            do {
                _ = try application(config.kindleID)
                operation = "次スライド送り：Chromeへ切り替え"; capture.record(operation)
                let chrome = try await activate("com.google.Chrome", delay: config.switchDelay)
                try verifySlides(chrome, expectedURL: config.presentationURL)
                let application = AXUIElementCreateApplication(chrome.processIdentifier)
                AXUIElementSetMessagingTimeout(application, 0.5)
                // Slides can expose a hidden AXTextArea even when the filmstrip
                // has keyboard focus. Do not equate that with active text editing.
                let slideState = try? focusedSlideList(application)
                if slideState == nil {
                    capture.record("スライド一覧の選択情報は取得できません。対象URLを確認して設定した操作を送信し、結果は手動確認します。")
                }
                var addButton: AXUIElement?
                if mode == .add { addButton = try await newSlideButton(application) }
                try await checkpoint()
                try verifySlides(chrome, expectedURL: config.presentationURL)
                var addUsesPress = false
                var addClickEvents: (CGEvent, CGEvent)?
                if let addButton {
                    var actions: CFArray?
                    let readResult = AXUIElementCopyActionNames(addButton, &actions)
                    let names = actions as? [String] ?? []
                    addUsesPress = readResult == .success && names.contains("AXPress")
                    capture.record("新規追加ボタンの公開操作: \(names.joined(separator: ", "))。使用操作: \(addUsesPress ? "AXPress" : "AX位置クリック")")
                    if !addUsesPress { addClickEvents = try menuClickEvents(addButton, newSlide: true) }
                }
                navigationUncertain = true
                UserDefaults.standard.set(true, forKey: "navigationUncertain.v1")
                setNavigationStage("Chrome操作予定：\(mode.title)・結果未確認")
                operation = "Chrome：\(mode.title)"
                capture.record(operation)
                if mode == .add {
                    guard let addButton else { throw AutomationFailure(message: "新規追加ボタンがありません。") }
                    if addUsesPress {
                        let result = AXUIElementPerformAction(addButton, "AXPress" as CFString)
                        guard result == .success else {
                            throw AutomationFailure(message: "新規追加の結果が不明です（AXエラー \(result.rawValue)）。再送せず手動確認してください。Kindleは送っていません。")
                        }
                        capture.record("新しいスライドのボタンにAXPressを送りました。作成結果は手動確認してください。")
                    } else if let (down, up) = addClickEvents {
                        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
                        capture.record("AX位置とヒットテストで確認した新規追加ボタンをクリックしました。作成結果は手動確認してください。")
                    }
                } else if let code = mode.keyCode {
                    try sendKey(code, flags: mode.flags, app: chrome)
                }
                if let (list, previousSlide) = slideState {
                    operation = "Chromeの選択スライド変更を確認"
                    var changed = false
                    for _ in 0..<30 {
                        try await wait(0.1)
                        try verifySlides(chrome, expectedURL: config.presentationURL)
                        let selected = axElements(list, "AXSelectedChildren")
                        if selected.count == 1, let next = selected.first, !CFEqual(previousSlide, next) {
                            changed = true; break
                        }
                    }
                    guard changed else {
                        throw AutomationFailure(message: "次スライドへの選択変更を確認できません。Kindleは送っていません。両アプリの位置を手動確認・調整してください。")
                    }
                    setNavigationStage("Chromeの選択変更を確認・Kindle未送信")
                    capture.record("Chromeの選択スライドが変わったことを確認しました。")
                } else {
                    try await wait(0.5)
                    try verifySlides(chrome, expectedURL: config.presentationURL)
                    setNavigationStage("Chrome操作送信済み：\(mode.title)・結果未確認・Kindle未送信")
                    capture.record("Chromeへ\(mode.title)の操作を送信しました。スライドの移動・作成は自動確認できていません。")
                }
                if mode == .add {
                    try await applyBlankLayout(capture: capture, chrome: chrome, expectedURL: config.presentationURL)
                }
                progress = 0.5
                operation = "次ページ送り：Kindleへ切り替え"
                let kindle = try await activate(config.kindleID, delay: config.switchDelay)
                try await checkpoint()
                setNavigationStage("Kindleへ下矢印を送信予定・結果未確認")
                try sendKey(125, flags: [], app: kindle)
                try await wait(0.5)
                setNavigationStage("Chrome：\(mode.title)／Kindle：下矢印送信済み・手動確認待ち")
                operation = "次スライド・次ページの手動確認待ち"
                progress = 1
                capture.record("Kindleへ下矢印を送信しました。両アプリが次のページになったことを手動確認してください。自動で再送しません。")
            } catch is CancellationError {
                operation = "ページ送り停止"; capture.record("ページ送りを停止しました。送信済み操作は取り消せません。実行段階を確認してください。")
            } catch {
                errors += 1; operation = "ページ送り：エラーで停止"; capture.record(error.localizedDescription)
            }
        }
    }
}


extension AutomationModel {
    private func persistPlan() {
        if let data = try? JSONEncoder().encode(plan) { UserDefaults.standard.set(data, forKey: "confirmedPlan.v1") }
    }
    var canRunPlanPage: Bool {
        !running && !pasteUncertain && !backgroundUncertain && !readyForNextPage && !navigationUncertain && !procedureResultPending && !layoutNeedsReview
    }
    func beginPlan(capture: CaptureModel) {
        guard !plan.active, canRunPlanPage, !capture.busy, (1...1000).contains(requestedPages) else { return }
        plan = ConfirmedPlan(target: requestedPages, completed: 0, active: true)
        persistPlan()
        capture.record("確認を挟む指定ページ数の処理を開始: \(plan.target)ページ")
        runPlanPage(capture: capture)
    }
    func runPlanPage(capture: CaptureModel) {
        guard plan.active, plan.completed < plan.target, canRunPlanPage, !capture.busy else { return }
        capture.record("ページ \(plan.completed + 1) / \(plan.target) を実行します。")
        start(capture: capture, transfer: true, setBackground: true, planRun: true)
    }
    func endPlan(capture: CaptureModel) {
        guard plan.active else { return }
        stop()
        plan.active = false
        persistPlan()
        capture.record("指定ページ数の処理を終了しました。未確認の操作は確認待ちのまま保持します。")
    }
}


extension AutomationModel {
    private func markProcedureMutation() {
        UserDefaults.standard.set(procedureStatus, forKey: "procedureResultStage.v1")
        procedureResultPending = true
        UserDefaults.standard.set(true, forKey: "procedureResultPending.v1")
    }
    func acknowledgeProcedureResult(capture: CaptureModel) {
        guard procedureResultPending, !running || awaitingProcedureResult else { return }
        procedureResultPending = false
        pasteUncertain = false; backgroundUncertain = false; navigationUncertain = false
        for key in ["procedureResultPending.v1", "pasteUncertain", "backgroundUncertain", "navigationUncertain.v1"] {
            UserDefaults.standard.set(false, forKey: key)
        }
        capture.record("編集手順の操作結果をユーザーが確認しました。")
    }
    private func waitForProcedureConfirmation(capture: CaptureModel) async throws {
        guard procedureResultPending else { return }
        awaitingProcedureResult = true
        defer { awaitingProcedureResult = false }
        operation = "編集手順：操作結果の手動確認待ち"
        capture.record("操作結果を確認し、操作エディタの『操作結果を確認して続ける』を押してください。")
        while procedureResultPending { try await wait(0.05) }
        try await checkpoint()
    }
    func startContinuous(capture: CaptureModel) {
        guard (1...500).contains(continuousPages), settings.pasteDelay.isFinite,
              (0...60).contains(settings.pasteDelay), (0...2).contains(menuShortcut) else {
            capture.record("ページ数1〜500、貼り付け待機0〜60秒、メニュー表示キーを確認してください。"); return
        }
        guard capture.selected != nil, CGPreflightScreenCaptureAccess(),
              presentationID(settings.presentationURL) != nil else {
            capture.record("撮影範囲・画面収録権限・対象スライドURLを確認してください。"); return
        }
        var steps: [ProcedureStep] = []
        for page in 0..<continuousPages {
            if page > 0 {
                steps.append(ProcedureStep(kind: "スライドの追加", delay: 1))
                steps.append(ProcedureStep(kind: "ページ送り", delay: 1, applicationID: settings.kindleID, keyCode: 125))
            }
            steps += [
                ProcedureStep(kind: "アプリ切り替え", applicationID: settings.kindleID),
                ProcedureStep(kind: "キャプチャ"),
                ProcedureStep(kind: "クリップボードへコピー"),
                ProcedureStep(kind: "貼り付け", delay: max(1, settings.pasteDelay)),
                ProcedureStep(kind: "画像を背景に設定", delay: 1)
            ]
        }
        runProcedure(Procedure(name: "連続処理（\(continuousPages)ページ）", steps: steps), capture: capture, continuous: true)
    }
    func runProcedure(_ procedure: Procedure, capture: CaptureModel, continuous: Bool = false) {
        guard canRunPlanPage, !capture.busy, !plan.active else {
            capture.record("実行中の処理または未確認の操作があります。先に結果を確認してください。"); return
        }
        let enabled = procedure.steps.filter { $0.enabled }
        let repeatSteps = enabled.filter { $0.kind == "繰り返し" }
        let steps = enabled.filter { $0.kind != "繰り返し" }
        let repetitions = repeatSteps.first?.repetitions ?? 1
        let allowed = Set(["アプリ切り替え", "キーボード操作", "待機", "キャプチャ", "クリップボードへコピー", "貼り付け", "画像を背景に設定", "既存スライドへ移動", "スライドの複製", "スライドの追加", "ページ送り"])
        guard !steps.isEmpty, repeatSteps.count <= 1, (1...1000).contains(repetitions),
              steps.count * repetitions <= 5000,
              enabled.allSatisfy({ $0.delay.isFinite && (0...60).contains($0.delay) && (0...127).contains($0.keyCode) && allowed.contains($0.kind) || ($0.kind == "繰り返し" && (1...1000).contains($0.repetitions)) }) else {
            capture.record("手順を確認してください。有効操作が必要です。繰り返し指定は1個、合計5000操作までです。"); return
        }
        var hasImage = false
        var hasCopy = false
        for step in steps {
            if step.kind == "キャプチャ" { hasImage = true; hasCopy = false }
            if step.kind == "クリップボードへコピー" {
                guard hasImage else { capture.record("コピーの前にキャプチャを登録してください。"); return }
                hasCopy = true
            }
            if step.kind == "貼り付け", !hasCopy { capture.record("貼り付け前にキャプチャとコピーを登録してください。"); return }
        }
        let config = settings
        let shortcut = menuShortcut
        guard config.switchDelay.isFinite, (0...60).contains(config.switchDelay) else { capture.record("切り替え待機は0〜60秒にしてください。"); return }
        resetExecutionFocus(); save(); running = true; paused = false; progress = 0; started = Date()
        if continuous {
            continuousRunning = true
            continuousDispatchedPages = 0
            continuousCurrentPage = 1
            continuousTargetPages = steps.filter { $0.kind == "キャプチャ" }.count * repetitions
        }
        task = Task {
            defer { self.updateElapsed(); self.continuousRunning = false; self.running = false; self.paused = false; self.awaitingProcedureResult = false; self.task = nil }
            do {
                guard AXIsProcessTrusted() else { throw AutomationFailure(message: "アクセシビリティ権限が必要です。") }
                var previousCaptureFingerprint: SHA256.Digest?
                for cycle in 0..<repetitions {
                    var image: NSImage?
                    var copiedChangeCount: Int?
                    for (index, step) in steps.enumerated() {
                        try await checkpoint()
                        procedureStatus = "\(procedure.name)：\(cycle + 1)/\(repetitions)回、操作\(index + 1)/\(steps.count)：\(step.kind)"
                        operation = procedureStatus; capture.record(procedureStatus)
                        switch step.kind {
                        case "アプリ切り替え":
                            _ = try await activate(step.applicationID, delay: config.switchDelay)
                        case "待機": break
                        case "キャプチャ":
                            if continuous { continuousCurrentPage = continuousDispatchedPages + 1 }
                            guard CGPreflightScreenCaptureAccess() else { throw AutomationFailure(message: "画面収録権限が必要です。") }
                            let kindle = try application(config.kindleID)
                            try verifyFrontmost(kindle)
                            capture.preview = nil
                            await capture.capture()
                            try await checkpoint()
                            try verifyFrontmost(kindle)
                            guard let fresh = capture.preview else { throw AutomationFailure(message: "キャプチャに失敗しました。") }
                            if continuous {
                                guard let fingerprint = capture.captureFingerprint else {
                                    throw AutomationFailure(message: "撮影画像の比較情報を取得できません。貼り付けず停止しました。")
                                }
                                guard previousCaptureFingerprint != fingerprint else {
                                    throw AutomationFailure(message: "撮影画像が前ページと同じです。Kindleのページ送り不発・本の終端・撮影範囲を確認してください。\(continuousDispatchedPages + 1)ページ目は貼り付けていません。新規スライドは追加済みの可能性があります。")
                                }
                                previousCaptureFingerprint = fingerprint
                                if continuousDispatchedPages > 0 { capture.record("前ページとの撮影画像の変化を検出しました。ページ番号の一致は終了後に確認してください。") }
                            }
                            image = fresh
                        case "クリップボードへコピー":
                            guard let image else { throw AutomationFailure(message: "今回のキャプチャ画像がありません。") }
                            let board = NSPasteboard.general; board.clearContents()
                            guard board.writeObjects([image]) else { throw AutomationFailure(message: "画像コピーに失敗しました。") }
                            copiedChangeCount = board.changeCount
                        case "貼り付け":
                            let chrome = try await activate("com.google.Chrome", delay: config.switchDelay)
                            try verifySlides(chrome, expectedURL: config.presentationURL)
                            guard let copiedChangeCount, NSPasteboard.general.changeCount == copiedChangeCount else {
                                throw AutomationFailure(message: "クリップボードが変更されています。貼り付けは送信していません。")
                            }
                            markProcedureMutation()
                            pasteUncertain = true; UserDefaults.standard.set(true, forKey: "pasteUncertain")
                            try sendKey(9, flags: [.maskCommand], app: chrome)
                        case "画像を背景に設定":
                            let chrome = try await activate("com.google.Chrome", delay: config.switchDelay)
                            try verifySlides(chrome, expectedURL: config.presentationURL)
                            markProcedureMutation()
                            try await performBackground(capture: capture, chrome: chrome, config: config, shortcut: shortcut, manualMenu: false)
                            if continuous { continuousDispatchedPages += 1 }
                        case "キーボード操作", "ページ送り":
                            let app = try await activate(step.applicationID, delay: config.switchDelay)
                            if step.applicationID == "com.google.Chrome" { try verifySlides(app, expectedURL: config.presentationURL) }
                            var modifiers: CGEventFlags = []
                            if step.command { modifiers.insert(.maskCommand) }
                            if step.option { modifiers.insert(.maskAlternate) }
                            if step.shift { modifiers.insert(.maskShift) }
                            if step.control { modifiers.insert(.maskControl) }
                            markProcedureMutation()
                            try sendKey(step.keyCode, flags: modifiers, app: app)
                        case "既存スライドへ移動", "スライドの複製", "スライドの追加":
                            let chrome = try await activate("com.google.Chrome", delay: config.switchDelay)
                            try verifySlides(chrome, expectedURL: config.presentationURL)
                            if step.kind == "スライドの追加" {
                                let app = AXUIElementCreateApplication(chrome.processIdentifier)
                                AXUIElementSetMessagingTimeout(app, 0.5)
                                let button = try await newSlideButton(app)
                                let (down, up) = try menuClickEvents(button, newSlide: true)
                                markProcedureMutation()
                                down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
                                try await wait(0.5)
                                try await applyBlankLayout(capture: capture, chrome: chrome, expectedURL: config.presentationURL)
                            } else {
                                markProcedureMutation()
                                try sendKey(step.kind == "スライドの複製" ? 2 : 125,
                                            flags: step.kind == "スライドの複製" ? [.maskCommand] : [], app: chrome)
                            }
                        default: throw AutomationFailure(message: "未対応の操作です: \(step.kind)")
                        }
                        try await wait(step.delay)
                        if !continuous { try await waitForProcedureConfirmation(capture: capture) }
                        progress = Double(cycle * steps.count + index + 1) / Double(repetitions * steps.count)
                    }
                }
                procedureStatus = continuous
                    ? "連続処理の操作送信が完了しました（\(continuousDispatchedPages)ページ）。背景とページ対応を確認してください。"
                    : "編集手順の全操作が完了しました。"
                UserDefaults.standard.set(procedureStatus, forKey: "procedureResultStage.v1")
                operation = procedureStatus; capture.record(procedureStatus)
            } catch is CancellationError {
                procedureStatus = "編集手順を停止しました。続きは自動再開しません。"
                operation = procedureStatus; capture.record(procedureStatus)
            } catch {
                errors += 1
                procedureStatus = "編集手順はエラーで停止しました。続きは自動再開しません。"
                operation = procedureStatus; capture.record(error.localizedDescription)
            }
        }
    }
}

extension AutomationModel {
    private func layoutDisplays() -> [LayoutDisplay] {
        NSScreen.screens.compactMap { screen -> LayoutDisplay? in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return LayoutDisplay(id: id.uint32Value, frame: SavedRect(screen.frame), scale: screen.backingScaleFactor)
        }.sorted { $0.id < $1.id }
    }
    private func layoutWindow(_ app: NSRunningApplication) throws -> AXUIElement {
        try verifyFrontmost(app)
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.5)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            throw AutomationFailure(message: "配置対象のウィンドウを確認できません。")
        }
        let window = unsafeBitCast(value, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(window, 0.5)
        for attribute in ["AXFullScreen", "AXMinimized"] {
            var flag: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, attribute as CFString, &flag) == .success, flag as? Bool == true {
                throw AutomationFailure(message: "フルスクリーン・最小化を解除してから配置を操作してください。")
            }
        }
        return window
    }
    private func layoutRect(_ window: AXUIElement) throws -> SavedRect {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            throw AutomationFailure(message: "ウィンドウの位置・サイズを取得できません。")
        }
        var point = CGPoint.zero; var size = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(positionValue, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeBitCast(sizeValue, to: AXValue.self), .cgSize, &size) else {
            throw AutomationFailure(message: "ウィンドウの座標形式を確認できません。")
        }
        let rect = SavedRect(CGRect(origin: point, size: size))
        try validateLayoutRect(rect)
        return rect
    }
    private func validateLayoutRect(_ rect: SavedRect) throws {
        guard [rect.x, rect.y, rect.width, rect.height].allSatisfy({ $0.isFinite }),
              rect.width >= 100, rect.height >= 100, let primary = NSScreen.screens.first else {
            throw AutomationFailure(message: "保存するウィンドウの座標・サイズが不正です。")
        }
        let visible = NSScreen.screens.contains { screen in
            let frame = screen.visibleFrame
            let axFrame = CGRect(x: frame.minX, y: primary.frame.maxY - frame.maxY, width: frame.width, height: frame.height)
            let intersection = axFrame.intersection(rect.rect)
            return !intersection.isNull && intersection.width >= 100 && intersection.height >= 100
        }
        guard visible else { throw AutomationFailure(message: "ウィンドウが画面外です。手動で画面内に移動してください。") }
    }
    private func layoutSettable(_ window: AXUIElement) throws {
        for attribute in [kAXPositionAttribute, kAXSizeAttribute] {
            var settable: DarwinBoolean = false
            guard AXUIElementIsAttributeSettable(window, attribute as CFString, &settable) == .success, settable.boolValue else {
                throw AutomationFailure(message: "位置・サイズの変更が許可されていません。配置は変更していません。")
            }
        }
    }
    private func setLayoutRect(_ rect: SavedRect, window: AXUIElement) async throws {
        var point = rect.rect.origin; var size = rect.rect.size
        guard let positionValue = AXValueCreate(.cgPoint, &point), let sizeValue = AXValueCreate(.cgSize, &size) else {
            throw AutomationFailure(message: "配置の座標を作成できません。")
        }
        // Move to the destination before resizing so the current display edge
        // does not constrain the requested size. Resizing can move a window,
        // so apply the destination position once more after the size change.
        for (attribute, value) in [(kAXPositionAttribute, positionValue), (kAXSizeAttribute, sizeValue), (kAXPositionAttribute, positionValue)] {
            try await checkpoint()
            let result = AXUIElementSetAttributeValue(window, attribute as CFString, value)
            guard result == .success else {
                throw AutomationFailure(message: "配置の復元が途中で停止しました（\(attribute)、AXエラー\(result.rawValue)）。両アプリの位置を手動確認してください。")
            }
            try await wait(0.2)
        }
    }
    func acknowledgeLayout(capture: CaptureModel) {
        guard !running else { return }
        layoutNeedsReview = false
        UserDefaults.standard.set(false, forKey: "layoutNeedsReview.v1")
        capture.record("ウィンドウ配置と撮影範囲をユーザーが確認しました。")
    }
    func manageWindowLayout(capture: CaptureModel, restore: Bool) {
        guard !running, !capture.busy, !plan.active, !procedureResultPending,
              !pasteUncertain, !backgroundUncertain, !navigationUncertain else { return }
        let config = settings
        let saved = windowLayout
        guard config.switchDelay.isFinite, (0...60).contains(config.switchDelay) else { return }
        if restore {
            guard let saved, saved.kindleID == config.kindleID,
                  presentationID(saved.presentationURL) == presentationID(config.presentationURL),
                  saved.displays == layoutDisplays() else {
                capture.record("保存時と画面構成・対象アプリ・対象スライドが違います。配置を手動調整して保存し直してください。"); return
            }
        }
        resetExecutionFocus(); save(); running = true; paused = false; started = Date(); progress = 0
        task = Task {
            defer { running = false; paused = false; task = nil }
            do {
                let displays = layoutDisplays()
                let kindle = try await activate(config.kindleID, delay: config.switchDelay)
                let kindleWindow = try layoutWindow(kindle)
                let kindleRect = try layoutRect(kindleWindow)
                let chrome = try await activate("com.google.Chrome", delay: config.switchDelay)
                try verifySlides(chrome, expectedURL: config.presentationURL)
                let chromeWindow = try layoutWindow(chrome)
                let chromeRect = try layoutRect(chromeWindow)
                guard displays == layoutDisplays() else { throw AutomationFailure(message: "画面構成が変わったため配置操作を停止しました。") }
                if restore, let saved {
                    try validateLayoutRect(saved.kindle); try validateLayoutRect(saved.chrome)
                    try layoutSettable(kindleWindow); try layoutSettable(chromeWindow)
                    layoutNeedsReview = true
                    UserDefaults.standard.set(true, forKey: "layoutNeedsReview.v1")
                    for (app, window, rect) in [(kindle, kindleWindow, saved.kindle), (chrome, chromeWindow, saved.chrome)] {
                        _ = try await activate(app.bundleIdentifier ?? "", delay: config.switchDelay)
                        guard CFEqual(try layoutWindow(app), window), displays == layoutDisplays() else {
                            throw AutomationFailure(message: "対象ウィンドウまたは画面構成が変わりました。配置を手動確認してください。")
                        }
                        if app.processIdentifier == chrome.processIdentifier { try verifySlides(chrome, expectedURL: config.presentationURL) }
                        try await setLayoutRect(rect, window: window)
                        var actual = try layoutRect(window)
                        for _ in 0..<40 {
                            if abs(actual.x - rect.x) <= 2, abs(actual.y - rect.y) <= 2,
                               abs(actual.width - rect.width) <= 2, abs(actual.height - rect.height) <= 2 { break }
                            try await wait(0.05)
                            try verifyFrontmost(app)
                            actual = try layoutRect(window)
                        }
                        guard abs(actual.x - rect.x) <= 2, abs(actual.y - rect.y) <= 2,
                              abs(actual.width - rect.width) <= 2, abs(actual.height - rect.height) <= 2 else {
                            let name = app.localizedName ?? app.bundleIdentifier ?? "対象アプリ"
                            throw AutomationFailure(message: "\(name)の配置が一致しません。保存値: X\(rect.x) Y\(rect.y) \(rect.width)×\(rect.height) pt ／ 実際: X\(actual.x) Y\(actual.y) \(actual.width)×\(actual.height) pt。配置を手動確認してください。")
                        }
                        capture.record("\(app.localizedName ?? "対象アプリ")の配置復元を確認しました。")
                    }
                    capture.preview = nil
                    operation = "配置を復元しました。撮影範囲を確認してください。"
                } else {
                    let layout = WindowLayout(kindleID: config.kindleID, presentationURL: config.presentationURL,
                                              kindle: kindleRect, chrome: chromeRect, displays: displays)
                    let data = try JSONEncoder().encode(layout)
                    UserDefaults.standard.set(data, forKey: "windowLayout.v1")
                    windowLayout = layout
                    operation = "KindleとChromeの配置を保存しました。"
                }
                progress = 1; capture.record(operation)
            } catch is CancellationError {
                operation = "配置操作を停止しました。変更済みの位置は手動確認してください。"; capture.record(operation)
            } catch {
                errors += 1; operation = "配置操作はエラーで停止しました。"; capture.record(error.localizedDescription)
            }
        }
    }
}
