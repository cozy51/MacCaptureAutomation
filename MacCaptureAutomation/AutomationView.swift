import SwiftUI

struct AutomationView: View {
    @ObservedObject var automation: AutomationModel
    @ObservedObject var capture: CaptureModel
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
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(8)
        }
    }
    private var continuousControls: some View {
        GroupBox("連続処理（結果を最後にまとめて確認）") {
            VStack(alignment: .leading, spacing: 12) {
                Stepper("処理ページ数：\(automation.continuousPages)", value: $automation.continuousPages, in: 1...500)
                    .disabled(automation.running)
                Text("現在のスライドに1ページ目を貼り付け、以降は新規スライドを追加して空白レイアウトにします。最後は追加・ページ送りをせず終了します。")
                Text("最初は2ページで試してください。背景化とページ移動の成功は自動判定できません。操作中はキーボード・マウスを操作せず、終了後に全ページの対応を確認してください。")
                    .foregroundStyle(.secondary)
                Text("撮影画像が前ページと完全に同じ場合は、次の貼り付け前に停止します。画像の変化だけでは正しい次ページと確定できません。")
                    .font(.caption).foregroundStyle(.secondary)
                Text(automation.globalShortcutsAvailable
                     ? "マウスを動かさず操作：Control＋Option＋Command＋Pで一時停止／再開、Control＋Option＋Command＋Sで停止。Kindle・Chromeが前面でも使えます。"
                     : "グローバルショートカットを登録できません。他のアプリとの競合や、このアプリの別ウィンドウがないか確認してください。")
                    .foregroundStyle(automation.globalShortcutsAvailable ? Color.secondary : Color.orange)
                Button("撮影→貼り付け→背景設定を連続実行") { automation.startContinuous(capture: capture) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!automation.canRunPlanPage || automation.plan.active || capture.busy)
                Text("背景設定の操作送信済み：\(automation.continuousDispatchedPages)ページ（成功確認前）")
                HStack {
                    Button("一時停止") { automation.pause() }.disabled(!automation.running || automation.paused)
                    Button("再開") { automation.resume() }.disabled(!automation.running || !automation.paused)
                    Button("停止", role: .destructive) { automation.stop() }.disabled(!automation.running)
                }
                if automation.procedureResultPending {
                    Text("実行・停止後は作成されたスライドとKindleの位置を確認してください。不明な操作を再送しないでください。")
                        .foregroundStyle(.orange)
                    Button("処理結果とページ位置を確認済み") { automation.acknowledgeProcedureResult(capture: capture) }
                        .disabled(automation.running)
                }
                Text(automation.procedureStatus).textSelection(.enabled)
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
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("確認を挟むページ処理").font(.title2.bold())
            Text("連続処理または毎ページ確認を選べます。編集権限のあるテスト用スライドで、撮影開始ページと貼り付け先を準備してください。")
            GroupBox("実行設定") {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("Kindleのアプリ識別子", text: $automation.settings.kindleID)
                    TextField("対象のGoogleスライドURL", text: $automation.settings.presentationURL)
                    HStack {
                        Text("アプリ切り替え待機（秒）")
                        TextField("秒", value: $automation.settings.switchDelay, format: .number).frame(width: 90)
                        Text("貼り付け後待機（秒）")
                        TextField("秒", value: $automation.settings.pasteDelay, format: .number).frame(width: 90)
                    }
                    Picker("次のスライドの準備方法", selection: $automation.slideNavigationMode) {
                        ForEach(SlideNavigationMode.allCases) { mode in Text(mode.title).tag(mode) }
                    }
                    .onChange(of: automation.slideNavigationMode) { _, _ in automation.save() }
                    Text("複製は現在の背景画像も引き継ぎます。新規追加は空白レイアウトを選びます。背景色の引き継ぎが必要なら複製を使用してください。ショートカットの結果はテスト用スライドで確認してください。")
                        .foregroundStyle(.secondary)
                    Text("クリップボードはキャプチャ画像に置き換わります。必要な内容は実行前に保存してください。")
                }.textFieldStyle(.roundedBorder).padding(8)
            }.disabled(automation.running)
            windowLayoutControls
            continuousControls
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
                    Text("通常テストは選択情報を取得できなくてもメニュー表示を試し、有効な背景設定項目を確認します。メニューが開かない場合は表示キーを変更するか、手動メニュー方式を使用してください。Chromeに切り替わった後、5秒以内に選択画像を右クリックしてください。項目の実行操作が公開されない場合は、AXで取得した位置を検証してクリックします。")
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
        .onDisappear { automation.save() }
    }
}
