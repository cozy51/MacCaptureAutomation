import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct ProcedureStep: Identifiable, Codable {
    var id = UUID()
    var kind = "待機"
    var enabled = true
    var delay = 1.0
    var applicationID = "com.amazon.Lassen"
    var keyCode = 125
    var command = false
    var option = false
    var shift = false
    var control = false
    var repetitions = 1
}
struct Procedure: Identifiable, Codable {
    var id = UUID()
    var name = "新しい手順"
    var steps: [ProcedureStep] = []
    static var initial: Procedure {
        Procedure(name: "Kindle → Googleスライド", steps: [
            ProcedureStep(kind: "アプリ切り替え", applicationID: "com.amazon.Lassen"),
            ProcedureStep(kind: "キャプチャ"), ProcedureStep(kind: "クリップボードへコピー"),
            ProcedureStep(kind: "アプリ切り替え", applicationID: "com.google.Chrome"),
            ProcedureStep(kind: "貼り付け"), ProcedureStep(kind: "画像を背景に設定")])
    }
    static var twoPageTest: Procedure {
        Procedure(name: "2ページテスト（既存スライドへ移動）", steps:
            initial.steps + [
                ProcedureStep(kind: "既存スライドへ移動"),
                ProcedureStep(kind: "ページ送り", applicationID: "com.amazon.Lassen", keyCode: 125)
            ] + initial.steps)
    }
}

@MainActor
final class ProcedureStore: ObservableObject {
    @Published var procedures: [Procedure] = []
    @Published var selectedID: UUID?
    @Published var message = "編集した手順は保存ボタンで保存します。"
    let kinds = ["アプリ切り替え", "キーボード操作", "待機", "キャプチャ", "クリップボードへコピー", "貼り付け", "画像を背景に設定", "既存スライドへ移動", "スライドの複製", "スライドの追加", "ページ送り", "繰り返し"]
    init() {
        if let data = UserDefaults.standard.data(forKey: "procedures.v1") {
            do { procedures = try JSONDecoder().decode([Procedure].self, from: data) }
            catch { message = "保存データを読み込めません。上書きせず、内容を確認してください。" }
        } else { procedures = [.initial] }
        selectedID = procedures.first?.id
    }
    private func valid(_ procedure: Procedure) -> Bool {
        !procedure.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && procedure.steps.count <= 5000 && procedure.steps.allSatisfy {
            kinds.contains($0.kind) && $0.delay.isFinite && (0...60).contains($0.delay) && (0...127).contains($0.keyCode) && (1...1000).contains($0.repetitions)
        }
    }
    func save() {
        guard procedures.allSatisfy(valid) else {
            message = "名前、待機0〜60秒、キー0〜127、回数1〜1000を確認してください。"; return
        }
        do {
            UserDefaults.standard.set(try JSONEncoder().encode(procedures), forKey: "procedures.v1")
            message = "手順を保存しました。"
        } catch { message = "保存失敗: \(error.localizedDescription)" }
    }
    func exportSelected() {
        guard let procedure = procedures.first(where: { $0.id == selectedID }), valid(procedure) else {
            message = "書き出す手順の名前と操作設定を確認してください。"; return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "MacCaptureAutomation-procedure.json"
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(procedure).write(to: url, options: .atomic)
                self.message = "手順ファイルを保存しました：\(url.path)"
            } catch { self.message = "書き出し失敗：\(error.localizedDescription)" }
        }
    }
    func importProcedure() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 1_048_576 else {
                    self.message = "手順ファイルは1MB以下を選んでください。"; return
                }
                var procedure = try JSONDecoder().decode(Procedure.self, from: Data(contentsOf: url))
                guard self.valid(procedure) else {
                    self.message = "手順ファイルの名前、操作、待機時間、キー、回数を確認してください。読み込みませんでした。"; return
                }
                procedure.id = UUID()
                procedure.steps = procedure.steps.map { var step = $0; step.id = UUID(); return step }
                self.procedures.append(procedure)
                self.selectedID = procedure.id
                self.message = "手順を追加しました。内容を確認し、「手順を保存」を押してください。"
            } catch { self.message = "読み込み失敗：\(error.localizedDescription)" }
        }
    }
}

struct ProcedureEditor: View {
    @ObservedObject var automation: AutomationModel
    @ObservedObject var capture: CaptureModel
    @StateObject private var store = ProcedureStore()
    @State private var dragging: UUID?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("操作エディタ").font(.largeTitle.bold())
            Text("保存した手順を実行できます。貼り付け・背景設定・キー操作等の後は結果確認待ちで止まります。無人の連続実行ではありません。")
                .foregroundStyle(.secondary)
            Picker("保存済み手順", selection: $store.selectedID) {
                ForEach(store.procedures) { Text($0.name).tag(Optional($0.id)) }
            }
            HStack {
                Button("新規手順") { let p = Procedure(); store.procedures.append(p); store.selectedID = p.id }
                Button("初期プリセットを追加") { let p = Procedure.initial; store.procedures.append(p); store.selectedID = p.id }
                Button("2ページテストを追加") { let p = Procedure.twoPageTest; store.procedures.append(p); store.selectedID = p.id }
                Button("手順を保存") { store.save() }.buttonStyle(.borderedProminent)
            }
            HStack {
                Button("選択手順をファイルに保存") { store.exportSelected() }.disabled(store.selectedID == nil)
                Button("手順ファイルを読み込む") { store.importProcedure() }
            }.disabled(automation.running || capture.busy)
            Text("ファイルには現在の編集内容を保存します。読み込みは別手順として追加されます。実行用の保存には「手順を保存」を押してください。")
                .font(.caption).foregroundStyle(.secondary)
            if let index = store.procedures.firstIndex(where: { $0.id == store.selectedID }) {
                TextField("手順名", text: $store.procedures[index].name).textFieldStyle(.roundedBorder)
                Button("保存済みの選択手順を実行") {
                    // Run exactly the stored snapshot, not unsaved edits.
                    guard let data = UserDefaults.standard.data(forKey: "procedures.v1"),
                          let saved = try? JSONDecoder().decode([Procedure].self, from: data),
                          let selected = saved.first(where: { $0.id == store.selectedID }) else {
                        store.message = "先に手順を保存してください。"; return
                    }
                    automation.runProcedure(selected, capture: capture)
                }.buttonStyle(.borderedProminent)
                    .disabled(automation.running || !automation.canRunPlanPage || automation.plan.active || capture.busy)

                HStack {
                    Button("操作を追加") { store.procedures[index].steps.append(ProcedureStep()) }
                    Button("手順を複製") {
                        var p = store.procedures[index]; p.id = UUID(); p.name += " コピー"
                        p.steps = p.steps.map { var step = $0; step.id = UUID(); return step }
                        store.procedures.append(p); store.selectedID = p.id
                    }
                    Button("手順を削除", role: .destructive) {
                        store.procedures.remove(at: index); store.selectedID = store.procedures.first?.id
                    }
                }
                ForEach($store.procedures[index].steps) { $step in
                    GroupBox {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Image(systemName: "line.3.horizontal")
                                Toggle("有効", isOn: $step.enabled).frame(width: 100)
                                Picker("操作", selection: $step.kind) { ForEach(store.kinds, id: \.self) { Text($0).tag($0) } }
                                Button("削除", role: .destructive) { store.procedures[index].steps.removeAll { $0.id == step.id } }
                            }
                            HStack {
                                Text("操作後待機（秒）")
                                TextField("秒", value: $step.delay, format: .number).frame(width: 80)
                                Button("↑") { move(step.id, index: index, delta: -1) }
                                Button("↓") { move(step.id, index: index, delta: 1) }
                            }
                            if ["アプリ切り替え", "キーボード操作", "ページ送り"].contains(step.kind) {
                                TextField("アプリ識別子", text: $step.applicationID)
                            }
                            if step.kind == "キーボード操作" || step.kind == "ページ送り" {
                                HStack {
                                    TextField("キーコード", value: $step.keyCode, format: .number).frame(width: 100)
                                    Toggle("Command", isOn: $step.command); Toggle("Option", isOn: $step.option)
                                    Toggle("Shift", isOn: $step.shift); Toggle("Control", isOn: $step.control)
                                }
                            }
                            if step.kind == "繰り返し" {
                                Stepper("手順全体の回数：\(step.repetitions)", value: $step.repetitions, in: 1...1000)
                                Text("全操作を指定回数実行します。最後の回も登録されたページ送りを行います。入れ子は対象外です。").foregroundStyle(.secondary)
                            }
                        }.padding(6).textFieldStyle(.roundedBorder)
                    }
                    .onDrag { dragging = step.id; return NSItemProvider(object: step.id.uuidString as NSString) }
                    .onDrop(of: [UTType.text], isTargeted: nil) { providers in
                        guard !providers.isEmpty, let source = dragging,
                              let from = store.procedures[index].steps.firstIndex(where: { $0.id == source }),
                              let to = store.procedures[index].steps.firstIndex(where: { $0.id == step.id }) else { return false }
                        let moved = store.procedures[index].steps.remove(at: from)
                        store.procedures[index].steps.insert(moved, at: to)
                        dragging = nil; return true
                    }
                }
            }
            HStack {
                Button("一時停止") { automation.pause() }.disabled(!automation.running || automation.paused)
                Button("再開") { automation.resume() }.disabled(!automation.paused)
                Button("停止", role: .destructive) { automation.stop() }.disabled(!automation.running)
            }
            if automation.procedureResultPending {
                Text("貼り付け、背景化、ページ位置など、直前の操作が正しく反映されたか確認してください。失敗・停止後は手動で状態を確定してから解除してください。")
                    .foregroundStyle(.orange)
                Button("操作結果を確認して続ける") { automation.acknowledgeProcedureResult(capture: capture) }
                    .disabled(automation.running && !automation.awaitingProcedureResult)
            }
            Text(automation.procedureStatus).textSelection(.enabled)
            Text(capture.message).textSelection(.enabled)
            Text(store.message).textSelection(.enabled)
        }.padding(28)
    }
    private func move(_ id: UUID, index: Int, delta: Int) {
        guard let from = store.procedures[index].steps.firstIndex(where: { $0.id == id }),
              store.procedures[index].steps.indices.contains(from + delta) else { return }
        store.procedures[index].steps.swapAt(from, from + delta)
    }
}
