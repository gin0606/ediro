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

## リリース

配布物は ad-hoc 署名の zip で、Homebrew の cask がその sha256 で固定する。

`Makefile` の `VERSION` を上げて commit し、同じ版のタグを push すると
`.github/workflows/release.yml` が走る。

```sh
git tag v0.1.0 && git push origin v0.1.0
```

workflow は macOS 26 の runner で `swift test` と `make dist` を回し、zip を
GitHub Release に上げたうえで、[gin0606/homebrew-tap](https://github.com/gin0606/homebrew-tap)
の `Casks/ediro.rb` の `version` と `sha256` を更新する。タグと `VERSION` が
食い違っているとビルドの前に落ちる。

tap への push には GitHub App のトークンを使うので、このリポジトリの secrets に
`APP_ID` と `APP_PRIVATE_KEY` が要る。

公開まで進んだ回をやり直すときは、タグを張り直さず GitHub の re-run を使う。
既に公開された zip があるのに再実行でない回は、古い zip を配らないよう中止する。

## 要件

macOS 26 以降 / Swift 6.2 以降
