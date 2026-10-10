import AppKit
import ScreenCaptureKit
import SwiftUI
import CryptoKit

struct SavedRect: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    init(_ rect: CGRect) { x = rect.origin.x; y = rect.origin.y; width = rect.width; height = rect.height }
    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

struct CapturePreset: Identifiable, Codable {
    var id = UUID()
    var name: String
    var displayID: UInt32
    var displayUUID: String
    var displayFrame: SavedRect
    var pixelWidth: Int
    var pixelHeight: Int
    var scale: Double
    // Absolute coordinates use AppKit's global bottom-left point coordinates.
    var absoluteRect: SavedRect
    // Relative coordinates use ScreenCaptureKit's display-local top-left points.
    var relativeRect: SavedRect
}

@MainActor
final class CaptureModel: ObservableObject {
    @Published var presets: [CapturePreset] = []
    @Published var selectedID: UUID?
    @Published var preview: NSImage?
    private(set) var captureFingerprint: SHA256.Digest?
    @Published var message = "キャプチャ範囲を選択してください。"
    @Published var busy = false
    @Published var screenPermission = CGPreflightScreenCaptureAccess()
    @Published var accessibilityPermission = AXIsProcessTrusted()
    @Published var logs: [String] = []
    @Published var needsAdjustment = false
    private var selection: SelectionCoordinator?
    private let defaults = UserDefaults.standard
    private let storageKey = "capturePresets.v1"
    var selected: CapturePreset? { presets.first { $0.id == selectedID } }

    init() {
        logs = Array((defaults.stringArray(forKey: "executionLogs.v1") ?? []).suffix(1000))
        if let data = defaults.data(forKey: storageKey) {
            do { presets = try JSONDecoder().decode([CapturePreset].self, from: data) }
            catch { message = "保存データを読み込めませんでした。既存データは保持しています。" }
        }
        if let value = defaults.string(forKey: "selectedPreset"), let id = UUID(uuidString: value), presets.contains(where: { $0.id == id }) { selectedID = id }
        else { selectedID = presets.first?.id }
    }

    func record(_ text: String) {
        message = text
        logs.append("\(Date().formatted(date: .numeric, time: .standard))  \(text)")
        if logs.count > 1000 { logs.removeFirst(logs.count - 1000) }
        defaults.set(logs, forKey: "executionLogs.v1")
    }

    func persist() {
        do {
            let data = try JSONEncoder().encode(presets)
            defaults.set(data, forKey: storageKey)
            defaults.set(selectedID?.uuidString, forKey: "selectedPreset")
        } catch { record("設定の保存に失敗しました: \(error.localizedDescription)") }
    }

    func refreshPermissions() {
        screenPermission = CGPreflightScreenCaptureAccess()
        accessibilityPermission = AXIsProcessTrusted()
    }

    func requestScreenPermission() {
        _ = CGRequestScreenCaptureAccess()
        refreshPermissions()
        record("画面収録を許可した後、必要に応じてアプリを再起動してください。")
    }

    func chooseRegion(replacing: Bool = false) {
        guard !busy, selection == nil else { return }
        let oldID = replacing ? selectedID : nil
        selection = SelectionCoordinator { [weak self] screen, rect in
            guard let self else { return }
            self.selection = nil
            guard let screen, let rect else { self.record("範囲選択をキャンセルしました。"); return }
            let id = screen.displayID
            let relative = CGRect(x: rect.minX - screen.frame.minX, y: screen.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
            var preset = CapturePreset(name: "範囲 \(self.presets.count + 1)", displayID: id,
                displayUUID: screen.stableID, displayFrame: SavedRect(screen.frame),
                pixelWidth: CGDisplayPixelsWide(id), pixelHeight: CGDisplayPixelsHigh(id),
                scale: screen.backingScaleFactor, absoluteRect: SavedRect(rect), relativeRect: SavedRect(relative))
            if let oldID, let index = self.presets.firstIndex(where: { $0.id == oldID }) {
                preset.id = oldID; preset.name = self.presets[index].name; self.presets[index] = preset
            } else { self.presets.append(preset) }
            self.selectedID = preset.id; self.preview = nil; self.needsAdjustment = false
            self.persist(); self.record("キャプチャ範囲を保存しました。")
        }
        selection?.begin()
    }

    func removeSelected() {
        guard !busy, let selectedID else { return }
        presets.removeAll { $0.id == selectedID }
        self.selectedID = presets.first?.id; preview = nil; persist()
    }

    func capture() async {
        captureFingerprint = nil
        guard !busy else { return }
        refreshPermissions()
        guard screenPermission else { record("画面収録権限がありません。環境設定で許可してください。"); return }
        guard let preset = selected else { record("範囲を選択してください。"); return }
        guard let screen = NSScreen.screens.first(where: { $0.stableID == preset.displayUUID }),
              screen.displayID == preset.displayID,
              SavedRect(screen.frame) == preset.displayFrame,
              CGDisplayPixelsWide(screen.displayID) == preset.pixelWidth,
              CGDisplayPixelsHigh(screen.displayID) == preset.pixelHeight,
              screen.backingScaleFactor == preset.scale else {
            needsAdjustment = true; record("ディスプレイ構成が変わりました。範囲を確認して再設定してください。"); return
        }
        let rect = preset.relativeRect.rect
        guard rect.width >= 2, rect.height >= 2,
              CGRect(origin: .zero, size: screen.frame.size).contains(rect) else {
            record("キャプチャ範囲が画面外です。再設定してください。"); return
        }
        busy = true
        defer { busy = false }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == preset.displayID }) else {
                record("ディスプレイが見つかりません。"); return
            }
            let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
            let config = SCStreamConfiguration()
            config.sourceRect = rect
            config.width = Int((rect.width * preset.scale).rounded())
            config.height = Int((rect.height * preset.scale).rounded())
            config.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            if let pixels = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                captureFingerprint = SHA256.hash(data: pixels)
            }
            preview = NSImage(cgImage: image, size: rect.size)
            record("キャプチャ成功: \(image.width) × \(image.height) ピクセル")
        } catch { record("キャプチャ失敗: \(error.localizedDescription)") }
    }
}

extension NSScreen {
    var displayID: UInt32 { (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0 }
    var stableID: String {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { return "display-\(displayID)" }
        return CFUUIDCreateString(nil, uuid) as String
    }
}
