# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Ediro：チャットに貼る前の下書きに使う単一ウィンドウの Markdown エディタ。macOS 専用、個人利用。
UI 文言は英語（Preferences 等の項目名）と日本語が混在するが、エディ太郎（https://editaro.com）の
表記に揃えている。App Store 配布はせず ad-hoc 署名で自分用にビルドする。

## コマンド

- `swift build` — ビルド
- `swift test` — テスト（全 target）
- `swift test --filter <名前>` — 部分実行
- `make app` — `.app` バンドルを組み立てて ad-hoc 署名
- `make run` / `make relaunch` — 起動 / 再起動
- `make shot` — 起動中のウィンドウを `artifacts/window.png` に撮影
- `make stop` — 起動中のアプリを終了

Xcode プロジェクトは持たない（`.xcodeproj` は `.gitignore` 済み）。SwiftPM は app バンドルを
生成できないため、`make app` が実行ファイルに `Support/Info.plist` を添えて `.app` を構成する。
この構成のため XCUITest は使えない。UI の検証は後述の 2 つの手段で行う。

## 変更を検証する手段

このリポジトリはコーディングエージェントが自力で検証を完結できることを設計上の要件にしている。
実装を変えたら、必ず以下のどれかで結果を確かめること。目視だけで済ませない。

1. **`swift test`** — ロジックとフォント解決と属性付けまでカバーする。数百 ms で終わる
2. **オフスクリーン描画** — `Tests/EdiroUITests/RenderingTests.swift` の `render()` が
   `ImageRenderer` でビューを PNG 化し、画素を検査する。画面収録権限もアプリ起動も要らず、
   決定論的なのでテーマの見た目の回帰はここで押さえる
3. **`make run && make shot`** — 実機で起動して撮影し、生成された PNG を読む。
   非決定的なので回帰テストには使わない。最終確認用

### 描画結果を検証する。属性値を検証しない

「設定した属性が入っていること」を assert するテストは、その属性が実際の表示に反映されるかを
何も保証しない。フォントのトレイトは典型で、`.font` 属性に bold が入っていても、
描画側の都合で見た目が変わらないことがある。

書体・色・サイズの検証は `Tests/EdiroUITests/RenderedTextTests.swift` の `inkAmount()` のように、
**実際に描画してピクセルを測る**形で書くこと。

## アーキテクチャ上の要点

### Core は AppKit に依存しない（最重要の不変条件）

`EdiroCore` は `import AppKit` / `import SwiftUI` を持たない。色は `RGBA`、塗りは `Fill` という
独自の値型で表現し、`NSColor` への変換は `EdiroUI/AppKitBridge.swift` が担う。

この境界を守ることで、ハイライト・テーマ・設定・保存のテストが GUI を起動せずに走る。
Core に AppKit を持ち込むと検証ループの速度が落ちるので、UI 由来の型を Core へ引き上げない。

### フレームワーク境界に処理を置かない

`NSViewRepresentable` や `NSApplicationDelegate` の中にロジックを書くと、テストから到達できなく
なる。`EditorTextView`（NSViewRepresentable）は `EditorTextController` を保持するだけの薄い層で、
NSTextView の組み立てと属性付けは全て `EditorTextController` にある。テストはこちらを直接生成する。

同じ理由で、フォント解決は `FontResolver`、属性適用は `MarkdownAttributer` に切り出してある。

### プレーンテキストのコピー

`NSTextView.isRichText = false` にしているのは、Cmd+C でクリップボードに書式付きデータを
載せないため。チャット欄に貼ったときに装飾が付いてこないことが、このアプリの主目的のひとつ。
この設定を外す変更をするなら、コピー結果がプレーンテキストのままであることを別の手段で担保すること。

### NSTextView.font へ代入しない

`textView.font = ...` は本文全体のフォントを一律に塗り替え、トークンごとに付けた見出しサイズや
太字を消す。入力中の書体を変えたいときは `typingAttributes[.font]` を使う。

### ハイライトは全文を毎回走査する

`EditorTextController.textStorage(_:didProcessEditing:...)` が編集のたびに全文を再ハイライトする。
下書き用途の文量では体感に出ないため、差分更新の複雑さを持ち込んでいない。長文で問題が出たら
このコメントごと方針を見直すこと。

### ウィンドウの撮影

`Tools/winid.swift` はアプリのウィンドウ ID を引く。アプリはメニューバーや画面外の内部ウィンドウ
（500x500 の空ウィンドウ等）も所有しているため、**表示中（onscreen）のレイヤ 0** に絞ってから
最大面積のものを選んでいる。表示状態で絞らないと画面に出ていないウィンドウを撮ってしまう。

## 注意点

- 依存は増やさない方針。Markdown のパースも `NSRegularExpression` で自前に持っている。
  CommonMark 準拠が必要になったら swift-markdown の導入を検討するが、それまでは足さない
- `~/Library/Application Support/Ediro/draft.md` は実際の下書きが入る。テストや動作確認で
  上書きしないこと（テストは一時ディレクトリの `DocumentStore` を使う）
