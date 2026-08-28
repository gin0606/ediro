# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Ediro：チャットに貼る前の下書きに使う単一ウィンドウの Markdown エディタ。macOS 専用、個人利用。
App Store 配布はせず ad-hoc 署名で自分用にビルドする。

## 変更の検証

このリポジトリはコーディングエージェントが自力で検証を完結できることを設計上の要件にしている。
実装を変えたら以下のどれかで結果を確かめる。目視の印象だけで完了にしない。

`.xcodeproj` を持たない構成のため XCUITest は使えない。代わりに 3 経路がある。

- `swift test` — ロジックに加え、`ImageRenderer` でビューをオフスクリーン描画して画素を検査できる。
  画面収録権限もアプリ起動も要らず決定論的なので、見た目の回帰はここで押さえる
- `make run && make shot` — 実機で起動して撮影し、生成された PNG を読む。非決定的なので回帰には使わない
- `osascript` + System Events — アクセシビリティ権限が付与済みで、メニュー操作やキー入力を自動化できる。
  App メニューの `Preferences…` は macOS が `Settings…` に自動改称するため、その名前で参照する

## 注意点

`~/Library/Application Support/Ediro/draft.md` には実際の下書きが入る。テストや動作確認で
上書きしない（テストは一時ディレクトリの `DocumentStore` を使う）。
