import AppKit
import EdiroCore
import Testing

@testable import EdiroUI

/// 文字列を実際に描画して、インク（前景色の載った量）を測る。
private func inkAmount(_ text: String, font: NSFont) throws -> Double {
  let size = CGSize(width: 120, height: 40)
  let rep = try #require(
    NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))

  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  NSColor.black.setFill()
  NSRect(origin: .zero, size: size).fill()
  NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.white])
    .draw(at: NSPoint(x: 4, y: 4))
  NSGraphicsContext.restoreGraphicsState()

  var total = 0.0
  for x in 0..<rep.pixelsWide {
    for y in 0..<rep.pixelsHigh {
      guard let color = rep.colorAt(x: x, y: y) else { continue }
      total += color.brightnessComponent
    }
  }
  return total
}

/// 実テキストにハイライトを適用し、指定した部分文字列に付いたフォントを取り出す。
private func font(in text: String, at substring: String) throws -> NSFont {
  let storage = NSTextStorage(string: text)
  MarkdownAttributer(theme: .fallback, preferences: .default).apply(to: storage)
  let range = (text as NSString).range(of: substring)
  try #require(range.location != NSNotFound)
  return try #require(storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)
}

@Test func 強調した和文は本文より濃く描画される() throws {
  let text = "普通の文字**次男**"
  let bodyFont = try font(in: text, at: "普通")
  let strongFont = try font(in: text, at: "次男")

  let body = try inkAmount("次男", font: bodyFont)
  let strong = try inkAmount("次男", font: strongFont)
  #expect(strong > body * 1.05, "強調のインク量 \(strong) が本文 \(body) と変わらない")
}

@Test func 強調した欧文は本文より濃く描画される() throws {
  let text = "plain **bold**"
  let bodyFont = try font(in: text, at: "plain")
  let strongFont = try font(in: text, at: "bold")

  let body = try inkAmount("bold", font: bodyFont)
  let strong = try inkAmount("bold", font: strongFont)
  #expect(strong > body * 1.05, "強調のインク量 \(strong) が本文 \(body) と変わらない")
}
