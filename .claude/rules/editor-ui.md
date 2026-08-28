---
paths:
  - "Sources/EdiroUI/**"
  - "Tests/EdiroUITests/**"
---

# UI 層を編集するとき

ロジックを `NSViewRepresentable` や `NSApplicationDelegate` の中に置かない。テストから到達できなくなる。ビューの組み立てと属性付けは `EditorTextController`、フォント解決は `FontResolver`、属性の適用は `MarkdownAttributer` が持っており、テストはこれらを直接生成する。

書体・色・サイズの変更は、属性に入っている値ではなく描画した画素で検証する。属性の指定と実際に描かれる字形は一致しない。和文はフォントフォールバックで weight が近い段に丸められ、slant は落ちる。`Tests/EdiroUITests/RenderedTextTests.swift` の `inkAmount` と `differingPixels` がその比較にあたる。

`ImageRenderer` は `NSViewRepresentable` を描画できず、禁止マークのプレースホルダに差し替わる。オフスクリーンで画素を検査できるのは純粋な SwiftUI ビューだけなので、エディタを含む合成の確認は実機の撮影で行う。寸法だけを見るテストは、この置き換えが起きていても通ってしまう。
