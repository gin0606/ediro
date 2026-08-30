# エ次郎

下書き専用テキストエディタ。macOS 専用。

ありがとう、[エディ太郎](https://editaro.com)。

## インストール

```sh
brew install --cask gin0606/tap/ediro
```

## 開発

```sh
swift test     # テスト
make run       # 開発用ビルドを起動する (Ediro Dev、橙のアイコン)
make release   # 日常使いのビルドを .build/Ediro.app に作る
```

開発用と日常使いのビルドは設定と下書きの保存先が分かれている。
その他のターゲットは `Makefile` を参照。

## 保存先

下書きは `~/Library/Application Support/Ediro/draft.md` に自動保存される。
同じ場所に、失われると困るものを置いてある。

- `draft.md.previous` — 直前の保存の内容。全消しなどで消したときはここから戻す
- `draft.md.unreadable-*` — 読めなかった本文の退避先

## 要件

macOS 26 以降 / Swift 6.2 以降
