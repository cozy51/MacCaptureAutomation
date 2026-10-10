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

enum SlideNavigationMode: String, CaseIterable, Identifiable {
    case existing, duplicate, add
    var id: String { rawValue }
    var title: String {
        switch self {
        case .existing: return "既存スライドへ移動（↓）"
        case .duplicate: return "現在のスライドを複製（Command + D）"
        case .add: return "新規スライドを追加（Command + M）"
        }
    }
    var keyCode: Int {
        switch self { case .existing: return 125; case .duplicate: return 2; case .add: return 46 }
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
        guard !running, !capture.busy else { return }
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
    private func menuClickEvents(_ item: AXUIElement) throws -> (CGEvent, CGEvent) {
        let title = axString(item, "AXTitle").trimmingCharacters(in: .whitespacesAndNewlines)
        guard axString(item, "AXRole") == "AXMenuItem",
              ["画像を背景に設定", "Set image as background"].contains(title),
              (axValue(item, "AXEnabled") as? Bool) == true,
              let positionValue = axValue(item, "AXPosition"),
              let sizeValue = axValue(item, "AXSize"),
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            throw AutomationFailure(message: "背景設定項目の有効状態・位置・サイズを確認できません。クリックしていません。")
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
            throw AutomationFailure(message: "背景設定項目の座標が無効です。クリックしていません。")
        }
        // AXPosition and CGEvent both use global top-left point coordinates.
        let center = CGPoint(x: point.x + dimensions.width / 2, y: point.y + dimensions.height / 2)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(center.x), Float(center.y), &hit) == .success,
              var current = hit else {
            throw AutomationFailure(message: "背景設定項目の位置をヒットテストで確認できません。クリックしていません。")
        }
        var matches = false
        for _ in 0..<12 {
            if CFEqual(current, item) { matches = true; break }
            guard let parent = axValue(current, "AXParent"), CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            current = unsafeBitCast(parent, to: AXUIElement.self)
        }
        guard matches else {
            throw AutomationFailure(message: "背景設定項目の位置が別の要素に重なっています。クリックしていません。")
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
        progress = max(progress, 0.8)
        try verifySlides(chrome, expectedURL: config.presentationURL)
        operation = "背景設定メニューを検索"
        let items = try await backgroundMenuItems(application)
        guard items.count == 1, let item = items.first else {
            throw AutomationFailure(message: "有効な『画像を背景に設定』メニューを一意に取得できません（\(items.count)件）。画像を選択し、メニュー表示キーを変更して試してください。手動メニュー方式も利用できます。背景設定操作は実行していません。")
        }
        var actions: CFArray?
        let actionReadResult = AXUIElementCopyActionNames(item, &actions)
        guard actionReadResult == .success, let names = actions as? [String] else {
            throw AutomationFailure(message: "背景設定メニューの操作一覧を取得できません（AXエラー \(actionReadResult.rawValue)）。操作は実行していません。")
        }
        // Chrome menu items can expose AXConfirm, AXPick, or AXPress.
        // AXShowMenu and AXCancel must never be treated as selection actions.
        let action = ["AXConfirm", "AXPick", "AXPress"].first(where: { names.contains($0) })
        capture.record("背景設定メニューの公開操作: \(names.joined(separator: ", "))。使用操作: \(action ?? "AX位置に基づくクリック")")
        try await checkpoint()
        try verifySlides(chrome, expectedURL: config.presentationURL)
        // Validate and prepare a dynamic click before marking the action uncertain.
        var clickEvents: (CGEvent, CGEvent)?
        if action == nil { clickEvents = try menuClickEvents(item) }
        backgroundUncertain = true
        UserDefaults.standard.set(true, forKey: "backgroundUncertain")
        operation = "背景設定メニューを実行"
        if let action {
            let result = AXUIElementPerformAction(item, action as CFString)
            guard result == .success else {
                throw AutomationFailure(message: "背景設定メニューの実行結果が不明です（AXエラー \(result.rawValue)）。再実行せず、スライドを手動確認してください。")
            }
            capture.record("\(action)要求が受理されました。背景化の成功はまだ未確認です。")
        } else if let (down, up) = clickEvents {
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            capture.record("AXで取得・ヒットテストしたメニュー項目をクリックしました。背景化の成功はまだ未確認です。")
        }
        try await wait(0.5)
        try verifySlides(chrome, expectedURL: config.presentationURL)
        let remaining = try await backgroundMenuItems(application)
        guard remaining.isEmpty else {
            throw AutomationFailure(message: "背景設定後もメニューが残っています。再実行せず、結果を手動確認してください。")
        }
        progress = 1
        operation = "背景設定結果の手動確認待ち"
        capture.record("メニューが閉じました。選択枠が消え、画像が実際の背景になったか確認してください。メニュー閉鎖だけでは成功判定しません。")
    }
    func testBackground(capture: CaptureModel, manualMenu: Bool = false) {
        guard !running, !capture.busy else { return }
        guard !backgroundUncertain else { capture.record("前回の背景設定の結果を確認してから再テストしてください。"); return }
        let config = settings
        let shortcut = menuShortcut
        guard config.switchDelay.isFinite, (0...60).contains(config.switchDelay),
              presentationID(config.presentationURL) != nil else {
            capture.record("対象のGoogleスライドURLと0〜60秒の切り替え待機を設定してください。"); return
        }
        save(); running = true; paused = false; progress = 0; started = Date()
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
        save(); running = true; paused = false; progress = 0; started = Date()
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
                try await checkpoint()
                try verifySlides(chrome, expectedURL: config.presentationURL)
                navigationUncertain = true
                UserDefaults.standard.set(true, forKey: "navigationUncertain.v1")
                setNavigationStage("Chrome操作予定：\(mode.title)・結果未確認")
                operation = "Chrome：\(mode.title)"
                capture.record(operation)
                try sendKey(mode.keyCode, flags: mode.flags, app: chrome)
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
                    capture.record("Chromeへ\(mode.title)のキーを送信しました。スライドの移動・作成は自動確認できていません。")
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
        !running && !pasteUncertain && !backgroundUncertain && !readyForNextPage && !navigationUncertain
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
