# MacCaptureAutomation

許可された資料の画面キャプチャを行う Swift / SwiftUI の macOS アプリです。DRM・コピー保護の解除や回避は行いません。

## 現在の実装：第1段階

- ディスプレイごとのドラッグ選択、半透明の枠、Esc キャンセル
- 範囲の名前付け、複数プリセット、再設定、削除
- UserDefaults に JSON 形式で保存し、再起動後に復元
- ディスプレイ ID / UUID、解像度、スケール、画面配置、絶対・相対座標を保存
- ScreenCaptureKit のテストキャプチャと画像プレビュー
- 画面収録権限の確認、未許可時の停止、システム設定への案内
- ディスプレイ構成変更時の停止と、ユーザーによる範囲再設定
- 日本語 UI と今回の起動中の実行ログ

キャプチャは1ディスプレイ内の範囲に限定します。絶対座標は AppKit の左下原点、相対座標は画面左上原点のポイントです。出力ピクセル数は範囲のポイント数 × backingScaleFactor です。アプリ自身のウィンドウはキャプチャから除外します。macOS 標準スクリーンショットの範囲履歴は使用しません。

## 必要環境・インストール

macOS 14.0 以降、Xcode 15 以降。外部パッケージや API キーは不要です。Xcode の Command Line Tools を選択してください。

1. `MacCaptureAutomation.xcodeproj` を Xcode で開く。
2. `MacCaptureAutomation` ターゲット、実行先 `My Mac` を選ぶ。
3. 必要なら Signing & Capabilities で自分の Team を指定する。
4. Run（Command + R）で起動する。

App Sandbox は無効です。後続の他アプリへの自動操作を想定した構成です。配布用の署名・公証は未設定です。

## コマンドラインビルドと .app

リポジトリのルートで実行します。

```sh
xcodebuild -project MacCaptureAutomation.xcodeproj \
  -scheme MacCaptureAutomation -configuration Debug \
  -derivedDataPath build build CODE_SIGNING_ALLOWED=NO
open build/Build/Products/Debug/MacCaptureAutomation.app
```

Release のローカル成果物は次の手順で生成します。

```sh
xcodebuild -project MacCaptureAutomation.xcodeproj \
  -scheme MacCaptureAutomation -configuration Release \
  -derivedDataPath build build CODE_SIGNING_ALLOWED=NO
```

生成先は `build/Build/Products/Release/MacCaptureAutomation.app`。この未署名アプリは配布用ではありません。一般配布には Developer ID 署名と公証が別途必要です。権限の再許可を避けるため、実行するアプリの場所と署名を安定させてください。

## macOS 権限

環境設定画面で「画面収録の許可を要求」を押し、システム設定 → プライバシーとセキュリティ → 画面収録でアプリを許可します。許可変更後は必要に応じてアプリを終了・再起動してください。画面収録が未許可の場合、キャプチャは開始しません。

アクセシビリティの状態も表示しますが、第1段階では不要です。後続のキー送信や UI 操作を実装する際に必要です。

## 初回動作確認・受け入れ手順

1. 権限未許可で範囲を選び、「テストキャプチャ」が権限エラーで止まることを確認。
2. 画面収録を許可して再起動。許可されたテスト資料を表示する。
3. 「新しい範囲を選択」でドラッグ。枠と保存座標を確認。Esc でのキャンセルも確認。
4. 名前を付けて撮影し、プレビューの範囲・縦横・ログのピクセル数を確認。
5. Retina と外部ディスプレイで、ポイント数 × 表示スケールと出力ピクセル数を比較。
6. 別の範囲を保存し、プリセット切り替え、再設定、削除を確認。
7. アプリを終了・再起動して名前、選択中のプリセット、座標が保持されることを確認。
8. macOS 標準スクリーンショットの範囲を変更しても本アプリの保存範囲が変わらないことを確認。
9. 画面配置・解像度の変更、外部画面の取り外しで撮影が停止し、再設定を促すことを確認。再選択後に撮影を確認。
10. 左・右・上・下に配置した外部画面で、選択位置と撮影結果が一致することを確認。

設定はこのアプリの UserDefaults の `capturePresets.v1` と `selectedPreset` に保存します。画像はメモリ内のプレビューのみで、ファイル保存やクリップボードコピーは未実装です。

## 次の段階と制約

自動キー操作、クリップボード、開始・停止・一時停止、Google スライド背景設定、操作エディタ、ウィンドウ位置管理、永続的な実行履歴は未実装です。対応するサイドバーには未実装の説明を表示します。

背景設定は Mac 上で Accessibility API によるメニュー取得、画像選択状態、操作後の実際の背景化を単独検証してから実装します。メニューが閉じたことだけを成功判定にせず、画像オブジェクトの全面配置で代用しません。対象タブを確実に確認できない場合や結果が不明な場合には停止する方針です。現在のアプリは Kindle や Chrome の操作を行いません。

## この開発環境での検証状況

作成環境は Linux であり、Swift / Xcode / macOS SDK はありません。プロジェクト構成、Info.plist、ファイル参照の整合性は静的検査していますが、Swift のコンパイル、.app 生成、画面収録、Retina 座標変換の実機確認は未実施です。上記の Mac での確認が必要です。
