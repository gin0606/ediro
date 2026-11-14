---
name: release
description: Ediroの新しいversionを公開する。前のリリースからの変更の整理、versionとリリースノートの確認、タグのpush、Release workflowの見届け、リリースノートの反映までを行う。「リリースして」「新しいversionを出して」のような依頼に使う。
---

# リリース

公開は `vX.Y.Z` タグのpushを起点に [Release workflow](../../../.github/workflows/release.yml) が行う。テスト・署名・公証・Releaseの作成・homebrew-tapのcask更新まで含む。versionはタグから導出されるので、versionを上げるcommitは作らない。

## 決めごと

- versionは [Semantic Versioning](https://semver.org/) に従う。1.0.0より前は、互換性を壊す変更でminor、それ以外でpatchを上げる。
- 互換性を壊す変更は、利用者が更新で対応を迫られるもの。動作要件の引き上げ、設定や下書きの保存先・形式の変更、既存の操作の挙動の変更などを指す。
- immutable releasesが有効なので、Releaseが作られるとタグは付け替えも削除もできず、Releaseを消しても同じタグ名は再利用できない。リリースノートは公開後も編集できる。
- タグの削除はユーザーの了承なしに行わない。

## 手順

1. `git fetch --tags` し、HEADがmainで `origin/main` と一致することを確かめる。一致しなければpushなどで合わせず、ユーザーに報告して止める。
2. 最後に公開したReleaseのタグ（`gh release view --json tagName`）からの変更を調べる。タグだけあってReleaseのないversionがあるので、`git describe` の結果を基準にしない。commitのprefixを手がかりにしつつ差分を見て、利用者から見える変更と互換性を壊す変更を挙げる。
3. 決めごとに沿ってversionを決め、変更の整理とリリースノートの下書きと合わせてユーザーに示し、確認を得る。versionが既存のタグ（Releaseのないものも含む）と重なるときは、重ならなくなるまでpatchを上げる。
4. HEADのcommitに対するmainのCI workflowの成功を待つ。失敗したらタグを付けずにユーザーに報告する。
5. HEADに注釈付きタグ（`git tag -a vX.Y.Z -m vX.Y.Z`）を付け、そのタグだけをpushする。
6. タグのcommitをheadShaに持つRelease workflowのrunを特定し（push直後はまだ登録されていないことがある）、成功を確かめる。失敗したら「失敗したとき」に従う。
7. 確認済みのリリースノートを `gh release edit vX.Y.Z --notes-file` で反映する。手順3の後にversionや内容が変わったときは、反映前に改めて確認を得る。

## 失敗したとき

失敗したstepのログから原因を特定し、Releaseが作られたか（`gh release view vX.Y.Z`）を確かめてから、ユーザーに報告する。Releaseが作られていれば、どう出し直すかによらず手順7でそのReleaseにもノートを反映する。

- 原因がタグのcommitの外にある（runnerの不調、証明書・公証、tapへのpushなど）ときは、原因が解消してから `gh run rerun RUN_ID --failed` で失敗したjobだけを再実行する。tapへのpushが拒否されても強制pushはしない。
- 原因がタグのcommitにあるときは、修正はこのskillで行わない。修正が `origin/main` に入った後、どちらで出し直すかをユーザーに確認し、手順1からやり直す。
  - 次のversionで出し直す（推奨）。公開済みのタグを書き換えない。
  - Releaseが作られていないときに限り、同じversionのタグを付け直す。やり直す前にremoteとlocalのタグを削除し、手順3では同じversionを使う。

## リリースノート

Homebrewでediroを使う利用者が、更新するか、更新で何が変わり何をすればよいかを判断できるように書く。

- 英語で書く。
- アプリの利用者から見える変更だけを書く。テスト・CI・文書・内部の整理や、エンジンのAPIのようにアプリの挙動に現れない変更は載せない。
- commit単位ではなく、利用者から見た機能単位でまとめる。
- 互換性を壊す変更を `## Breaking changes` として先頭に置き、何が変わり、利用者が何をすればよいかを書く。
- 続けて `## New features`・`## Fixes` を置く。性能の改善など新機能でない変更は `## Fixes` に入れる。該当する変更のない節は置かない。
- 末尾に `**Full Changelog**: https://github.com/gin0606/ediro/compare/vPREV...vX.Y.Z` を置く。`vPREV` は手順2の基準にしたタグ。
