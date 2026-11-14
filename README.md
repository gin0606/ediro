# エ次郎

下書き専用テキストエディタ。macOS 専用。

ありがとう、[エディ太郎](https://editaro.com)。

## インストール

```sh
brew install --cask gin0606/tap/ediro
```

## 開発

```sh
make test      # テスト
make run       # 開発用ビルドを起動する (Ediro Dev、橙のアイコン)
make release   # 日常使いのビルドを .build/Ediro.app に作る
```

開発用と日常使いのビルドは設定と下書きの保存先が分かれている。
その他のターゲットは `Makefile` を参照。

### 振る舞いの決め方

1. Ediro が明示的に決めた仕様 (テストに値で書いたもの) を正本とする。
2. 編集の意味論のうち、エンジン (`Packages/SwiftEditorEngine`) が規則を持つものはエンジンに揃え、アプリ側で別の規則を計算しない。書記素の区切り、選択のないキャレットの削除範囲、複数カーソル、取り消しのまとまりがこれに当たる。
3. エンジンに規則の無いもの (単語の境界など) と、macOS との統合部分 (IME、スペル・置換、サービス、Writing Tools、アクセシビリティ、右クリックメニュー、Cocoa の標準キーバインドなど) の基準は未定。

3 の基準を決めるまでは今の振る舞いを残す。今の振る舞いの多くは、エディタを自前のビューに置き換える前の NSTextView に合わせたもの。これは置き換えのときの暫定の基準で、NSTextView と同じであることは振る舞いを残す理由にならない。テストが NSTextView と比べる使い方は `Tests/EdiroUITests/ReferenceTextView.swift` にある。

## 保存先

下書きは `~/Library/Application Support/Ediro/draft.md` に自動保存される。
同じ場所に、失われると困るものを置いてある。

- `draft.md.previous` — 直前の保存の内容。全消しなどで消したときはここから戻す
- `draft.md.unreadable-*` — 読めなかった本文の退避先

## 要件

- 動作: macOS 27 以降
- ビルド: Xcode 27 (Swift 6.4) 以降
