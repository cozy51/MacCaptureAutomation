import SwiftUI
import UniformTypeIdentifiers

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
    func save() {
        guard procedures.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.steps.allSatisfy { kinds.contains($0.kind) && $0.delay.isFinite && (0...60).contains($0.delay) && (0...127).contains($0.keyCode) && (1...1000).contains($0.repetitions) } }) else {
            message = "名前、待機0〜60秒、キー0〜127、回数1〜1000を確認してください。"; return
        }
        do {
            UserDefaults.standard.set(try JSONEncoder().encode(procedures), forKey: "procedures.v1")
            message = "手順を保存しました。"
        } catch { message = "保存失敗: \(error.localizedDescription)" }
    }
}

struct ProcedureEditor: View {
    @StateObject private var store = ProcedureStore()
    @State private var dragging: UUID?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("操作エディタ").font(.largeTitle.bold())
            Text("手順の編集・保存用です。編集手順の実行はまだ接続していません。現在の自動処理の設定には影響しません。")
                .foregroundStyle(.secondary)
            Picker("保存済み手順", selection: $store.selectedID) {
                ForEach(store.procedures) { Text($0.name).tag(Optional($0.id)) }
            }
            HStack {
                Button("新規手順") { let p = Procedure(); store.procedures.append(p); store.selectedID = p.id }
                Button("初期プリセットを追加") { let p = Procedure.initial; store.procedures.append(p); store.selectedID = p.id }
                Button("手順を保存") { store.save() }.buttonStyle(.borderedProminent)
            }
            if let index = store.procedures.firstIndex(where: { $0.id == store.selectedID }) {
                TextField("手順名", text: $store.procedures[index].name).textFieldStyle(.roundedBorder)
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
                                Text("実行方式は未接続です。入れ子の繰り返しは対象外です。").foregroundStyle(.secondary)
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
            Text(store.message).textSelection(.enabled)
        }.padding(28)
    }
    private func move(_ id: UUID, index: Int, delta: Int) {
        guard let from = store.procedures[index].steps.firstIndex(where: { $0.id == id }),
              store.procedures[index].steps.indices.contains(from + delta) else { return }
        store.procedures[index].steps.swapAt(from, from + delta)
    }
}
