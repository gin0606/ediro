---
paths:
  - "Sources/EdiroUI/**"
  - "Tests/EdiroUITests/**"
---

# UI 層を編集するとき

ロジックを `NSViewRepresentable` や `NSApplicationDelegate` の中に置かない。テストから到達できなくなる。

書体・色・サイズの変更は、属性に入っている値ではなく描画した画素で検証する。属性の指定と実際に描かれる字形は一致しない。和文はフォントフォールバックで weight が近い段に丸められ、slant は落ちる。`Tests/EdiroUITests/RenderedTextTests.swift` の `inkAmount` と `differingPixels` がその比較にあたる。

`ImageRenderer` は `NSViewRepresentable` を描画できず、禁止マークのプレースホルダに差し替わる。エディタを含む合成の確認は実機の撮影で行う。`NSViewRepresentable` を含みうるビューを `ImageRenderer` に通すなら、`colorAt` で色を見るアサーションを置く。寸法だけを見るテストは差し替えが起きていても通る。
