import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var model: CaptureModel
    @StateObject private var automation = AutomationModel()
    @State private var page = "ダッシュボード"
    @State private var historyExportMessage = ""
    @State private var kindleRunning = false
    @State private var chromeRunning = false
    private let pages = ["ダッシュボード", "キャプチャ設定", "自動処理", "操作エディタ", "プリセット", "実行履歴", "環境設定"]
    var body: some View {
        NavigationSplitView {
            List(pages, id: \.self, selection: $page) { item in Text(item).font(.system(size: 20)).tag(item) }
                .navigationTitle("画面キャプチャ")
            .navigationSplitViewColumnWidth(min: 220, ideal: 240)
            .controlSize(.large)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(page).font(.largeTitle.bold())
                    if page == "ダッシュボード" { dashboardStatus }
                    if page == "環境設定" { permissions }
                    else if page == "実行履歴" { logView }
                    else if page == "自動処理" { AutomationView(automation: automation, capture: model) }
                    else if page == "操作エディタ" { ProcedureEditor(automation: automation, capture: model)
                    } else {
                        captureControls
                        if let preset = model.selected { metadata(preset) }
                        preview
                        Text(model.message).foregroundStyle(model.needsAdjustment ? .red : .secondary)
                        if page == "ダッシュボード" {
                            logView
                        }
                    }
                }.padding(28).font(.system(size: 20)).controlSize(.large)
            }.background(Color.white)
        }
        .onChange(of: model.selectedID) { _, _ in model.preview = nil; model.needsAdjustment = false; model.persist() }
        .onAppear { refreshDashboard() }
        .onChange(of: automation.running) { _, running in
            if running { model.showRangeOverlay() }
            else { model.hideRangeOverlay() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in model.hideRangeOverlay() }
        .onChange(of: automation.settings.kindleID) { _, _ in refreshDashboard() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refreshDashboard() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in refreshDashboard() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in refreshDashboard() }
        .alert("ディスプレイ構成の変更", isPresented: $model.needsAdjustment) {
            Button("範囲を再設定") { model.chooseRegion(replacing: true) }
            Button("キャンセル", role: .cancel) { }
        } message: { Text("解像度、表示スケール、または画面配置が変わっています。現在の画面で範囲を選択し直してください。自動調整は行いません。") }
    }
    private func appRunning(_ id: String) -> Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty }
    private func refreshDashboard() {
        model.refreshPermissions()
        kindleRunning = appRunning(automation.settings.kindleID)
        chromeRunning = appRunning("com.google.Chrome")
    }
    private var dashboardStatus: some View {
        GroupBox("処理状況と実行準備") {
            VStack(alignment: .leading, spacing: 12) {
                Text("現在の操作：\(automation.operation)")
                if automation.running {
                    ProgressView(value: automation.progress)
                    HStack {
                        Button(automation.paused ? "再開" : "一時停止") {
                            if automation.paused { automation.resume() } else { automation.pause() }
                        }
                        Button("停止", role: .destructive) { automation.stop() }
                    }
                }
                if automation.procedureResultPending || automation.pasteUncertain || automation.backgroundUncertain || automation.navigationUncertain {
                    Text("操作結果の確認が必要です。実行した画面で結果を確認してください。")
                        .foregroundStyle(.orange)
                }
                if automation.layoutNeedsReview {
                    Text("復元したウィンドウ配置と撮影範囲の確認が必要です。自動処理画面で確認してください。")
                        .foregroundStyle(.orange)
                }
                Label(kindleRunning ? "Kindle 起動中" : "Kindle 未検出", systemImage: "book")
                Text("検出対象：\(automation.settings.kindleID)").font(.system(size: 20)).textSelection(.enabled)
                Label(chromeRunning ? "Chrome 起動中" : "Chrome 未検出", systemImage: "globe")
                Text("画面収録：\(model.screenPermission ? "許可済み" : "未許可") ／ アクセシビリティ：\(model.accessibilityPermission ? "許可済み" : "未許可")")
                Text("撮影範囲：\(model.selected?.name ?? "未選択")")
                Text(automation.settings.presentationURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "対象スライドURL：未設定" : "対象スライドURL：設定済み（実行時に一致を確認）")
                HStack {
                    Button("状態を更新") { refreshDashboard() }
                    Button("自動処理を開く") { page = "自動処理" }
                    Button("操作エディタを開く") { page = "操作エディタ" }
                    Button("権限設定を開く") { page = "環境設定" }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
    }
    private var captureControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("保存済み範囲", selection: $model.selectedID) {
                Text("未選択").tag(Optional<UUID>.none)
                ForEach(model.presets) { preset in Text(preset.name).tag(Optional(preset.id)) }
            }.frame(maxWidth: 450)
            if let index = model.presets.firstIndex(where: { $0.id == model.selectedID }) {
                TextField("プリセット名", text: $model.presets[index].name).textFieldStyle(.roundedBorder)
                    .onSubmit { model.persist() }
                    .onChange(of: model.presets[index].name) { _, _ in model.persist() }
            }
            HStack {
                Button("新しい範囲を選択") { model.chooseRegion() }
                Button("範囲を再設定") { model.chooseRegion(replacing: true) }.disabled(model.selected == nil)
                Button("削除", role: .destructive) { model.removeSelected() }.disabled(model.selected == nil)
                Button("テストキャプチャ") { Task { await model.capture() } }
                    .buttonStyle(.borderedProminent).disabled(model.selected == nil)
                if model.busy { ProgressView().controlSize(.small) }
            }
            Button(model.rangeOverlayVisible ? "画面上の範囲枠を隠す" : "選択範囲を画面に表示") { model.toggleRangeOverlay() }
                .disabled(model.selected == nil)
            Text("青い枠で保存済み範囲を表示します。枠の表示中も背後のアプリを操作できます。")
                .font(.system(size: 20)).foregroundStyle(.secondary)
        }.disabled(model.busy || automation.running)
    }
    private func metadata(_ preset: CapturePreset) -> some View {
        let rect = preset.absoluteRect.rect
        return GroupBox("保存された範囲") {
            VStack(alignment: .leading, spacing: 8) {
                Text("ディスプレイ ID: \(preset.displayID)  解像度: \(preset.pixelWidth) × \(preset.pixelHeight) px  スケール: \(preset.scale, specifier: "%.2f")")
                Text("絶対座標: X \(rect.minX, specifier: "%.1f") / Y \(rect.minY, specifier: "%.1f") / 幅 \(rect.width, specifier: "%.1f") / 高さ \(rect.height, specifier: "%.1f") pt")
                Text("相対座標: X \(preset.relativeRect.x, specifier: "%.1f") / Y \(preset.relativeRect.y, specifier: "%.1f") pt（画面左上基準）")
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
    }
    private var preview: some View {
        GroupBox("キャプチャプレビュー") {
            if let image = model.preview {
                Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 340)
            } else {
                VStack(spacing: 12) { Image(systemName: "viewfinder").font(.system(size: 48)); Text("テストキャプチャの画像がここに表示されます") }
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 220)
            }
        }
    }
    private var logView: some View {
        GroupBox("実行履歴（最新1000件・再起動後も保持）") {
            VStack(alignment: .leading, spacing: 6) {
                Button("履歴をコピー") {
                    let board = NSPasteboard.general
                    board.clearContents()
                    board.setString(model.logs.joined(separator: "\n"), forType: .string)
                }.disabled(model.logs.isEmpty || automation.running || model.busy)
                Button("履歴をファイルに保存") { exportHistory() }
                    .disabled(model.logs.isEmpty || automation.running || model.busy)
                if !historyExportMessage.isEmpty {
                    Text(historyExportMessage).font(.system(size: 20)).textSelection(.enabled)
                }
                Text("コピーするとクリップボードの内容が履歴のテキストに置き換わります。実行中はコピーできません。")
                    .font(.system(size: 20)).foregroundStyle(.secondary)
                if model.logs.isEmpty { Text("ログはありません").foregroundStyle(.secondary) }
                ForEach(Array(model.logs.enumerated()), id: \.offset) { _, entry in Text(entry).textSelection(.enabled) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
    }
    private func exportHistory() {
        let text = model.logs.joined(separator: "\n") + "\n"
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "MacCaptureAutomation-history.txt"
        panel.title = "実行履歴を保存"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                historyExportMessage = "履歴を保存しました：\(url.path)"
            } catch {
                historyExportMessage = "履歴を保存できませんでした：\(error.localizedDescription)"
            }
        }
    }
    private var permissions: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("画面収録: \(model.screenPermission ? "許可済み" : "未許可")")
            Text("実行中のアプリ：\(Bundle.main.bundleURL.path)").font(.system(size: 20)).textSelection(.enabled)
            Text("識別子：\(Bundle.main.bundleIdentifier ?? "不明")").font(.system(size: 20)).textSelection(.enabled)
            Text("更新のたびに許可が外れる場合は、同じApple Development署名と同じインストール先を使ってください。READMEの『許可設定を繰り返さないための運用』を参照してください。")
                .foregroundStyle(.secondary)
            Button("画面収録の許可を要求") { model.requestScreenPermission() }
            Button("画面収録のシステム設定を開く") { openSettings("Privacy_ScreenCapture") }
            Text("アクセシビリティ: \(model.accessibilityPermission ? "許可済み" : "未許可")")
            Text("自動処理のアプリ切り替えとキー送信にはアクセシビリティ権限が必要です。許可後にアプリを再起動してください。")
            Button("アクセシビリティのシステム設定を開く") { openSettings("Privacy_Accessibility") }
            Button("権限状態を更新") { model.refreshPermissions() }
            Text("画面収録の許可変更後にアプリの再起動が必要な場合があります。")
        }
    }
    private func openSettings(_ section: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(section)") { NSWorkspace.shared.open(url) }
    }
}
