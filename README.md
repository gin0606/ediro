# Ediro

チャットに貼る前の下書きに使う、単一ウィンドウの Markdown エディタ。macOS 専用。

[エディ太郎](https://editaro.com)（Electron 製・MIT）の使い勝手を引き継ぎつつ、AppKit と
TextKit 2 で書き直したもの。見た目とテーマはエディ太郎に揃えてある。

## できること

- Markdown のシンタックスハイライト（見出し・強調・コード・リンク・リスト・引用）
- テーマ 9 種、フォントファミリ/サイズ、タブ幅の変更
- 常に最前面に表示するトグル
- 文字数（書記素単位）と行数の表示
- 書式なしのコピー。チャット欄に貼っても装飾が付いてこない
- 本文の自動保存。`~/Library/Application Support/Ediro/draft.md` に平文で置くので、
  他のツールから読める

## 開発

```sh
swift build          # ビルド
swift test           # テスト
make app             # .app バンドルを組み立てて ad-hoc 署名
make run             # 組み立てて起動
make relaunch        # 起動中のものを終了してから起動し直す
make shot            # 起動中のウィンドウを artifacts/window.png に撮影
```

Xcode プロジェクトは持たない。SwiftPM は app バンドルを生成できないため、
`make app` が実行ファイルに `Support/Info.plist` を添えて `.app` を構成する。

## 構成

| ターゲット | 内容 |
| --- | --- |
| `EdiroCore` | UI 非依存のロジック。ハイライト、テーマ、設定、保存 |
| `EdiroUI` | AppKit / SwiftUI のビューとウィンドウ |
| `Ediro` | 実行ファイル。`EdiroApp.run()` を呼ぶだけ |

## 要件

macOS 26 以降 / Swift 6.2 以降
