# AnkiLite

*[English version / 英語版 README](README.md)*

既存の Anki `.apkg` ファイルを読み込んで学習できる、iOS 向けフラッシュカードアプリ（SwiftUI）。
AnkiMobile の低価格代替として、**apkg インポート互換性**を最重視しています。

> 注: アプリ名 `AnkiLite` は仮称です。設定や `Info.plist` の表示名から変更できます。

## 必要環境

- Xcode 16 以降（プロジェクトは Xcode 16 の同期グループ形式 `objectVersion = 77` を使用）
- iOS 17.0 以降
- Swift 5.9 以降

## 依存ライブラリ（Swift Package Manager）

`AnkiLite.xcodeproj` を開くと自動的に解決されます。

- [GRDB.swift](https://github.com/groue/GRDB.swift) — SQLite 操作
- [ZIPFoundation](https://github.com/weichsel/ZIPFoundation) — ZIP 解凍

## ビルド方法

1. `AnkiLite.xcodeproj` を Xcode で開く
2. Xcode が SPM パッケージ（GRDB / ZIPFoundation）を自動取得するのを待つ
3. 実機またはシミュレータを選んで Run（⌘R）
4. テストは ⌘U（`AnkiLiteTests` ターゲット）

> もし `.xcodeproj` がうまく開けない場合は、新規 iOS App プロジェクトを作成し、
> `AnkiLite/` 以下のフォルダをドラッグして追加、SPM で上記 2 つのパッケージを追加すれば同じ構成になります。

## プロジェクト構造

```
AnkiLite/
├── App/                # エントリーポイント・アプリ設定
├── Models/             # Deck / Card / Note / NoteType / ReviewLog
├── Database/           # GRDB データベース管理・スキーマ
├── Import/             # apkg インポート・テンプレートレンダラー・メディア管理
├── Scheduler/          # SM-2 アルゴリズム・学習セッション
├── Views/              # SwiftUI 画面・WKWebView カード表示・テーマ
└── Utilities/          # ファイル操作・拡張
AnkiLiteTests/          # テンプレート / SM-2 / インポートのユニットテスト
```

## 実装済み機能（P0 / MVP）

- **apkg インポート**: ZIP 解凍 → SQLite 読み込み → アプリ内 DB へ保存。
  `collection.anki21` / `collection.anki2` の両対応。メディアもサンドボックスへ保存。
  進捗バー表示、再インポート時の「上書き / マージ」選択。
- **カードレンダリング（WKWebView）**: `{{Field}}`、`{{FrontSide}}`、`{{cloze:Field}}`、
  条件分岐 `{{#}}` / `{{^}}`、`[sound:...]` → `<audio>`、画像表示、欠損メディアのプレースホルダー、
  ノートタイプ CSS 適用、ダークモード（`night_mode` クラス方式）。
- **学習画面**: 表面 → タップで裏面 → Again / Hard / Good / Easy。各ボタンに次回間隔を表示。
  スワイプ操作（左 = もう一度 / 右 = ふつう）、残数表示（New / Learning / Review）、完了画面。
- **デッキ一覧**: 階層表示（`::`）、状態別カウント、タップで学習開始、スワイプで削除。
- **SM-2 スケジューラ**: 学習ステップ [1分, 10分]、卒業間隔、ease factor 計算（既定 2.50 / 下限 1.30）、
  ファズ、日付の区切り（既定 午前4時、設定変更可）。
- **ダークモード**: 既定はダーク。システム追従 / 常にライト / 常にダークを設定で切替。

## デザイン方針

過度な装飾を避けた、落ち着いたネイティブ寄りの外観です。グラデーションや装飾的な絵文字は使わず、
中間色のグレー基調＋控えめな単色アクセント、ヘアラインの区切り線、SF Symbols を用いています。

## 広告について

**本アプリは広告収益で運営されています。** 学習セッション完了後に AdMob のインタースティシャル広告が
表示されることがあります（数分に1回まで）。バナー広告はなく、復習中に広告が割り込むこともありません。

- Debug ビルドでは常に Google 公式のテスト広告ユニットを使用します。開発ビルドから本番広告を表示・
  タップすると無効なトラフィックとみなされます。
- 起動時に App Tracking Transparency の許可を求めます。拒否しても利用に支障はなく、
  パーソナライズされない広告が表示されます。
- 広告 ID は `AnkiLite/Utilities/AdsManager.swift`（`AdConfig`）と
  `AnkiLite/Info.plist`（`GADApplicationIdentifier`）にあります。fork して配布する場合は
  **必ず自分の ID に差し替えてください。**

## ライセンス

[MIT](LICENSE) © 2026 tamakondayo

## ライセンスに関する注意

`.apkg` は Anki のエクスポート形式です。本アプリは Anki / AnkiWeb とは無関係の独立実装です。
