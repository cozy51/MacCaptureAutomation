import SwiftUI

struct AutomationView: View {
    @ObservedObject var automation: AutomationModel
    @ObservedObject var capture: CaptureModel
    @State private var showTiming = false
    @State private var showLayout = false
    @State private var showTests = false
    private var needsTestConfirmation: Bool {
        !automation.procedureResultPending && (automation.pasteUncertain || automation.backgroundUncertain || automation.readyForNextPage || automation.navigationUncertain || automation.plan.active)
    }
    private var preparationControls: some View {
        GroupBox("1. 準備") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Kindleを撮影開始ページ、Chromeを貼り付け先のスライドに合わせてください。")
                Text("撮影範囲：\(capture.selected?.name ?? "未設定（キャプチャ設定で選択）")")
                HStack {
                    Button(capture.rangeOverlayVisible ? "範囲枠を隠す" : "範囲を画面で確認") { capture.toggleRangeOverlay() }
                    Button("撮影をテスト") { Task { await capture.capture() } }
                }.disabled(capture.selected == nil || automation.running || capture.busy)
                Text("貼り付け先のGoogleスライドURL").font(.system(size: 20, weight: .semibold))
                TextField("https://docs.google.com/presentation/d/…", text: $automation.settings.presentationURL)
                    .textFieldStyle(.roundedBorder).disabled(automation.running)
                Text("撮影 → 貼り付け → 背景設定 → 次ページ。1ページ目は現在のスライドに入り、続きは新しいスライドを追加します。")
                    .foregroundStyle(.secondary)
            }.padding(8)
        }
    }
    private var windowLayoutControls: some View {
        GroupBox("Kindle・Chromeのウィンドウ配置") {
            VStack(alignment: .leading, spacing: 12) {
                Text("両アプリを使いたい位置・サイズに手動で並べて保存します。操作時にKindle、Chromeの順で前面へ切り替えます。復元はこのボタンを押したときだけ行います。")
                    .foregroundStyle(.secondary)
                if let layout = automation.windowLayout {
                    Text("保存済み：Kindle \(Int(layout.kindle.width))×\(Int(layout.kindle.height)) ／ Chrome \(Int(layout.chrome.width))×\(Int(layout.chrome.height)) pt")
                } else { Text("配置は未保存です。") }
                HStack {
                    Button("現在の両ウィンドウ配置を保存") { automation.manageWindowLayout(capture: capture, restore: false) }
                    Button("保存した配置に復元") { automation.manageWindowLayout(capture: capture, restore: true) }
                        .disabled(automation.windowLayout == nil || automation.layoutNeedsReview)
                }.disabled(automation.running || capture.busy || automation.plan.active || automation.procedureResultPending || automation.pasteUncertain || automation.backgroundUncertain || automation.navigationUncertain)
                if automation.layoutNeedsReview {
                    Text("両ウィンドウと撮影範囲を確認してください。サイズ変更でKindleの改行やページ数が変わる場合があります。必要なら範囲を再選択し、テストキャプチャしてください。")
                        .foregroundStyle(.orange)
                    Button("配置と撮影範囲を確認済み") { automation.acknowledgeLayout(capture: capture) }
                        .disabled(automation.running || capture.busy)
                }
                Text("画面構成・表示スケール・対象スライドが保存時と違う場合は復元しません。フルスクリーンを解除して使ってください。")
                    .font(.system(size: 20)).foregroundStyle(.secondary)
            }.padding(8)
        }
    }
    private var continuousControls: some View {
        GroupBox("2. ページ数を指定して実行") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("処理ページ数")
                    TextField("ページ数", value: $automation.continuousPages, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder).frame(width: 90)
                    Text("ページ（1〜500）").foregroundStyle(.secondary)
                }
                    .disabled(automation.running)
                Text("終了後に全ページの対応・重複・抜け・背景設定を確認してください。最後はページ送りをせず終了します。")
                    .foregroundStyle(.secondary)
                Button("\(automation.continuousPages)ページの処理を開始") { automation.startContinuous(capture: capture) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!automation.canRunPlanPage || automation.plan.active || capture.busy)
                Text("処理済み：\(automation.continuousDispatchedPages)ページ（結果は終了後に確認）")
                if automation.continuousRunning {
                    ProgressView(value: automation.progress)
                    Text("現在：\(automation.continuousCurrentPage) / \(automation.continuousTargetPages)ページ\(automation.paused ? "（一時停止中）" : "")　残り：\(max(0, automation.continuousTargetPages - automation.continuousDispatchedPages))ページ")
                    Text("現在の操作：\(automation.operation)")
                    if let seconds = automation.estimatedRemainingSeconds {
                        Text("残り時間の目安：約\(seconds / 60)分\(seconds % 60)秒（一時停止時間を除く）")
                    } else { Text("残り時間の目安：最初のページを処理後に表示") }
                }
                if automation.running && !automation.continuousRunning {
                    Text("現在の操作：\(automation.operation)")
                    ProgressView(value: automation.progress)
                }
                HStack {
                    Button("一時停止") { automation.pause() }.disabled(!automation.running || automation.paused)
                    Button("再開") { automation.resume() }.disabled(!automation.running || !automation.paused)
                    Button("停止", role: .destructive) { automation.stop() }.disabled(!automation.running)
                }
                Text(automation.globalShortcutsAvailable
                     ? "一時停止／再開：⌃⌥⌘P　停止：⌃⌥⌘S（Kindle・Chromeが前面でも使用できます）"
                     : "操作ショートカットを登録できません。画面の停止ボタンを使用してください。")
                    .font(.system(size: 20)).foregroundStyle(automation.globalShortcutsAvailable ? Color.secondary : Color.orange)
                if !automation.canRunPlanPage && !automation.running && !automation.procedureResultPending {
                    Text("開始できない場合は、未確認の操作結果やウィンドウ配置を確認してください。")
                        .foregroundStyle(.orange)
                }
                if automation.procedureResultPending {
                    Text("実行・停止後は作成されたスライドとKindleの位置を確認してください。不明な操作を再送しないでください。")
                        .foregroundStyle(.orange)
                    Button("処理結果とページ位置を確認済み") { automation.acknowledgeProcedureResult(capture: capture) }
                        .disabled(automation.running)
                }
                if automation.procedureResultPending || automation.continuousDispatchedPages > 0 {
                    Text(automation.procedureStatus).textSelection(.enabled)
                }
            }.padding(8)
        }
    }
    private var planControls: some View {
        GroupBox("指定ページ数の処理（毎ページ確認）") {
            VStack(alignment: .leading, spacing: 12) {
                Stepper("指定ページ数：\(automation.requestedPages)", value: $automation.requestedPages, in: 1...1000)
                    .disabled(automation.plan.active || automation.running)
                ProgressView(value: Double(automation.plan.completed), total: Double(automation.plan.target))
                Text("確認済み：\(automation.plan.completed) / \(automation.plan.target)ページ")
                HStack {
                    Button("指定ページ数の処理を開始") { automation.beginPlan(capture: capture) }
                        .disabled(automation.plan.active || !automation.canRunPlanPage || capture.busy)
                    Button("続きの1ページを実行") { automation.runPlanPage(capture: capture) }
                        .disabled(!automation.plan.active || !automation.canRunPlanPage || capture.busy)
                    Button("指定ページ数の処理を終了", role: .destructive) { automation.endPlan(capture: capture) }
                        .disabled(!automation.plan.active)
                }
                Text("最初は2ページで試してください。背景化を確認→両アプリのページ送り→結果確認→Chromeの編集キャンバスを選択→続きの1ページ、の順です。最後のページではページ送りを要求せず終了します。")
                    .foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
    }
    private var timingControls: some View {
        GroupBox("待ち時間") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Kindleのアプリ識別子")
                TextField("例：com.amazon.Lassen", text: $automation.settings.kindleID)
                HStack {
                    Text("アプリ切り替え待機（秒）")
                    TextField("秒", value: $automation.settings.switchDelay, format: .number).frame(width: 90)
                    Text("貼り付け後待機（秒）")
                    TextField("秒", value: $automation.settings.pasteDelay, format: .number).frame(width: 90)
                }
                HStack {
                    Text("連続処理のページ送り後待機（秒）")
                    TextField("秒", value: $automation.continuousPageDelay, format: .number).frame(width: 90)
                    Button("大量処理向け待機を設定") { automation.optimizeContinuousTiming() }
                }
                Text("大量処理向け：切り替え0.2秒・貼り付け0.8秒・ページ送り0.6秒。まず5ページで確認し、描画が間に合わない場合は対応する待機を増やしてください。")
                    .foregroundStyle(.secondary)
                Toggle("連続処理の空白設定は最初の追加時のみ", isOn: $automation.continuousBlankLayoutOnce)
                Text("以降は新規スライドが空白レイアウトを引き継ぐ前提で省略します。入力枠が残る場合はオフにしてください。実行を開始するたびに最初の追加時は設定します。")
                    .foregroundStyle(.secondary)
                Text("クリップボードはキャプチャ画像に置き換わります。必要な内容は実行前に保存してください。")
            }.textFieldStyle(.roundedBorder).padding(8)
        }.disabled(automation.running)
    }
    private var diagnosticControls: some View {
        VStack(alignment: .leading, spacing: 18) {
        Text("通常の連続処理とは別の実行方法です。各操作を確認したい場合や、問題の切り分けに使います。")
            .foregroundStyle(.secondary)
        Picker("次のスライドの準備方法", selection: $automation.slideNavigationMode) {
            ForEach(SlideNavigationMode.allCases) { mode in Text(mode.title).tag(mode) }
        }
        .onChange(of: automation.slideNavigationMode) { _, _ in automation.save() }
        Text("複製は現在の背景画像も引き継ぎます。新規追加は空白レイアウトを選びます。背景色の引き継ぎが必要なら複製を使用してください。ショートカットの結果はテスト用スライドで確認してください。")
            .foregroundStyle(.secondary)

        planControls
        Button("1回だけ実行：撮影→貼り付け→背景設定") {
            automation.start(capture: capture, transfer: true, setBackground: true)
        }
        .buttonStyle(.borderedProminent)
        .disabled(automation.plan.active || automation.running || automation.pasteUncertain || automation.backgroundUncertain || automation.readyForNextPage || automation.navigationUncertain || capture.busy)
        Text("背景設定後は手動確認待ちで停止します。確認後、下のページ送りボタンで次へ進めます。自動繰り返しは行いません。Chromeの編集キャンバスを選択してから実行してください。")
            .foregroundStyle(.secondary)
        HStack {
            Button("1回だけ実行：撮影→貼り付け") { automation.start(capture: capture, transfer: true) }
                .buttonStyle(.borderedProminent).disabled(automation.plan.active || automation.running || automation.pasteUncertain || automation.backgroundUncertain || automation.readyForNextPage || automation.navigationUncertain || capture.busy)
            Button("一時停止") { automation.pause() }.disabled(!automation.running || automation.paused)
            Button("再開") { automation.resume() }.disabled(!automation.running || !automation.paused)
            Button("停止", role: .destructive) { automation.stop() }.disabled(!automation.running)
        }
        if automation.pasteUncertain {
            Text("貼り付け済みの可能性があります。結果を確認し、不要な画像があれば手動で削除してください。確認前の再実行はできません。")
                .foregroundStyle(.orange)
            Button("貼り付け結果を確認済み") { automation.acknowledgePaste() }.disabled(automation.running || automation.backgroundUncertain)
        }
        GroupBox("背景設定テスト") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Chromeで画像を1枚選択してから実行します。撮影・貼り付け・ページ送りは行いません。")
                Picker("メニュー表示キー", selection: $automation.menuShortcut) {
                    Text("Shift + F10").tag(0)
                    Text("Command + Shift + バックスラッシュ").tag(1)
                    Text("Control + Shift + バックスラッシュ").tag(2)
                }.disabled(automation.running)
                    .onChange(of: automation.menuShortcut) { _, _ in automation.save() }
                Button("背景設定テスト") { automation.testBackground(capture: capture) }
                    .disabled(automation.running || automation.backgroundUncertain || capture.busy)
                Button("メニューを手動で開いてテスト") { automation.testBackground(capture: capture, manualMenu: true) }
                    .disabled(automation.running || automation.backgroundUncertain || capture.busy)
                Text("背景設定はマウスクリックを使いません。項目の直接実行操作がなければ、方向キーで移動し、選択を確認してEnterを送ります。メニューが開かない場合は表示キーを変更してください。手動メニューテストではChromeへ切り替わった後、5秒以内に画像を右クリックします。選択状態を確認できなければ停止します。")
                    .foregroundStyle(.secondary)
                if automation.backgroundUncertain {
                    Text("結果を確認してください：選択枠が消え、画像をクリックしても画像オブジェクトとして選択されず、スライド全面の背景になっていますか？結果不明なら再実行しないでください。")
                        .foregroundStyle(.orange)
                    Button("背景設定の結果を手動確認済み") { automation.acknowledgeBackground(capture: capture) }
                        .disabled(automation.running)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
        if automation.readyForNextPage || automation.navigationUncertain {
            GroupBox("確認後のページ送り") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Chromeの左側の現在のスライドサムネイルをクリックしてから実行してください。クリック自体ではページは進みません。このボタンでChromeに設定した移動・複製・追加を送り、Kindleには下矢印を1回送ります。選択情報を取得できない場合、ページ送り結果は手動確認します。")
                    Button("次スライド・Kindleの次ページへ") { automation.advancePages(capture: capture) }
                        .disabled(automation.running || automation.navigationUncertain)
                    Text("Chromeの操作：\(automation.slideNavigationMode.title)")
                    Text("実行段階：\(automation.navigationStage)").textSelection(.enabled)
                    Text("両アプリが次のページになったか確認してください。途中失敗の場合は、片方だけ進んでいる可能性があるため手動で位置を合わせてください。")
                        .foregroundStyle(.orange)
                    Button("両アプリの次ページを手動確認済み") { automation.acknowledgeNavigation(capture: capture) }
                        .disabled(automation.running)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
        }
        ProgressView(value: automation.progress)
        Text("現在の操作：\(automation.operation)\(automation.paused ? "（一時停止中）" : "")")
        Text("経過：\(Int(automation.elapsed)) 秒　エラー：\(automation.errors) 件")
        GroupBox("Kindleへのキー送信テスト") {
            VStack(alignment: .leading, spacing: 12) {
                Text("ページ送りの初期値は下矢印です（Kindle・Chrome共通）。")
                Text("仮想キーコード（0〜127）")
                Picker("キー", selection: $automation.settings.keyCode) {
                    Text("下矢印（ページ送り）").tag(125)
                    Text("右矢印").tag(124); Text("左矢印").tag(123)
                    Text("上矢印").tag(126)
                    Text("Enter").tag(36); Text("Escape").tag(53); Text("Tab").tag(48)
                }
                TextField("キーコード", value: $automation.settings.keyCode, format: .number).frame(width: 100)
                HStack {
                    Toggle("Command", isOn: $automation.settings.command)
                    Toggle("Option", isOn: $automation.settings.option)
                    Toggle("Shift", isOn: $automation.settings.shift)
                    Toggle("Control", isOn: $automation.settings.control)
                }
                Button("Kindleを前面にしてキーを1回送信") { automation.start(capture: capture, transfer: false) }
                Button("Chromeを前面にして下矢印を1回送信") { automation.start(capture: capture, transfer: false, chromeKeyTest: true) }
                Text("Chromeではスライド一覧にフォーカスを置いてください。編集中の画像やテキストにフォーカスがあると移動操作になる場合があります。")
                    .foregroundStyle(.secondary)
            }.padding(8)
        }.disabled(automation.running || capture.busy)
        Text("対象アプリが前面でない場合、権限不足、ダイアログ検出、対象URLを確認できない場合は停止します。ChromeのAXDocumentを取得できない環境では貼り付けできません。")
            .foregroundStyle(.secondary)
        Text(capture.message).textSelection(.enabled)
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Kindle → Googleスライド").font(.title2.bold())
            Text("表示中のKindleページを撮影し、スライドの背景として順番に保存します。")
                .foregroundStyle(.secondary)
            preparationControls
            continuousControls
            DisclosureGroup("ウィンドウ配置の保存・復元", isExpanded: Binding(
                get: { showLayout || automation.layoutNeedsReview }, set: { showLayout = $0 }
            )) { windowLayoutControls }
            DisclosureGroup("待ち時間・詳細設定", isExpanded: $showTiming) {
                timingControls
            }
            DisclosureGroup("毎ページ確認・単独テスト", isExpanded: Binding(
                get: { showTests || needsTestConfirmation }, set: { showTests = $0 }
            )) {
                diagnosticControls
            }
        }
        .frame(maxWidth: 920, alignment: .leading)
        .onDisappear { automation.save() }
    }
}
