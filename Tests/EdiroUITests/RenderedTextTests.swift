import AppKit
import EdiroCore
import Testing

@testable import EdiroUI

private let canvas = CGSize(width: 140, height: 40)

private func bitmap(_ text: String, attributes: [NSAttributedString.Key: Any]) throws
  -> NSBitmapImageRep
{
  let rep = try #require(
    NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: Int(canvas.width), pixelsHigh: Int(canvas.height),
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))

  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  NSColor.black.setFill()
  NSRect(origin: .zero, size: canvas).fill()
  var merged = attributes
  merged[.foregroundColor] = NSColor.white
  if merged[.strokeColor] != nil { merged[.strokeColor] = NSColor.white }
  NSAttributedString(string: text, attributes: merged).draw(at: NSPoint(x: 4, y: 4))
  NSGraphicsContext.restoreGraphicsState()
  return rep
}

/// 描画されたインク（前景色の載った量）。太さの比較に使う。
private func inkAmount(_ text: String, attributes: [NSAttributedString.Key: Any]) throws -> Double {
  let rep = try bitmap(text, attributes: attributes)
  var total = 0.0
  for x in 0..<rep.pixelsWide {
    for y in 0..<rep.pixelsHigh {
      total += Double(rep.colorAt(x: x, y: y)?.brightnessComponent ?? 0)
    }
  }
  return total
}

/// 2 つのフォントで描いたときに色が異なる画素の数。字形の変化を捉える。
private func differingPixels(_ text: String, _ a: NSFont, _ b: NSFont) throws -> Int {
  let left = try bitmap(text, attributes: [.font: a])
  let right = try bitmap(text, attributes: [.font: b])
  var count = 0
  for x in 0..<left.pixelsWide {
    for y in 0..<left.pixelsHigh {
      let l = Double(left.colorAt(x: x, y: y)?.brightnessComponent ?? 0)
      let r = Double(right.colorAt(x: x, y: y)?.brightnessComponent ?? 0)
      if abs(l - r) > 0.05 { count += 1 }
    }
  }
  return count
}

/// 実テキストにハイライトを適用し、指定した部分文字列に付いたフォントを取り出す。
private func font(in text: String, at substring: String) throws -> NSFont {
  let storage = NSTextStorage(string: text)
  MarkdownAttributer(theme: .fallback, preferences: .default).apply(to: storage)
  let range = (text as NSString).range(of: substring)
  try #require(range.location != NSNotFound)
  return try #require(storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)
}

@Test func 強調した和文は本文よりはっきり濃く描画される() throws {
  let text = "普通の文字**次男**"
  let body = try inkAmount("次男", attributes: [.font: try font(in: text, at: "普通")])
  let strong = try inkAmount("次男", attributes: [.font: try font(in: text, at: "次男")])
  // ディスクリプタに .bold を付けただけでは和文が一段しか太らず約 10% しか増えない。
  #expect(strong > body * 1.15, "強調のインク量 \(strong) が本文 \(body) に対して不足")
}

@Test func 強調した欧文は本文よりはっきり濃く描画される() throws {
  let text = "plain **bold**"
  let body = try inkAmount("bold", attributes: [.font: try font(in: text, at: "plain")])
  let strong = try inkAmount("bold", attributes: [.font: try font(in: text, at: "bold")])
  #expect(strong > body * 1.15, "強調のインク量 \(strong) が本文 \(body) に対して不足")
}

@Test func 斜体の和文は本文と違う字形で描画される() throws {
  let text = "普通の文字*斜体*"
  let bodyFont = try font(in: text, at: "普通")
  let italicFont = try font(in: text, at: "斜体")
  // 和文には斜体の字面が無いため、トレイト指定だけでは画素が完全に一致する。
  #expect(try differingPixels("斜体", bodyFont, italicFont) > 0)
}

@Test func 斜体の欧文は本文と違う字形で描画される() throws {
  let text = "plain *slanted*"
  let bodyFont = try font(in: text, at: "plain")
  let italicFont = try font(in: text, at: "slanted")
  #expect(try differingPixels("slanted", bodyFont, italicFont) > 0)
}

@Test func 斜体にしても解決したフォントのグリフは送り幅が変わらない() throws {
  let text = "plain *slanted*"
  let bodyFont = try font(in: text, at: "plain")
  let italicFont = try font(in: text, at: "slanted")

  // 和文を含めない。等幅システムフォントに和文の字面は無く、フォールバック先は
  // 各マシンの導入フォントで決まる。素と斜体で別のフォントに解決されうるので、
  // 送り幅の一致はアプリからは保証できない。
  let sample = "monospaced"
  let plain = (sample as NSString).size(withAttributes: [.font: bodyFont]).width
  let slanted = (sample as NSString).size(withAttributes: [.font: italicFont]).width
  #expect(abs(plain - slanted) < 0.01, "\(sample) の桁揃えが崩れている")
}

/// 太い字面を持たないフォントを実機から探す。無い環境では検証を省く。
private func fontFamilyWithoutBold() -> String? {
  for family in NSFontManager.shared.availableFontFamilies {
    guard let font = NSFont(name: family, size: 13), font.isFixedPitch else { continue }
    let traits = font.fontDescriptor.symbolicTraits.union(.bold)
    let bold = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(traits), size: 13)
    if bold == nil || bold?.fontName == font.fontName { return font.fontName }
  }
  return nil
}

@Test func 太い字面を持たないフォントでは太字の合成を要求する() throws {
  guard let name = fontFamilyWithoutBold() else { return }
  var preferences = Preferences.default
  preferences.fontName = name
  let resolver = FontResolver(preferences: preferences)
  let palette = SyntaxPalette(theme: .fallback)

  #expect(resolver.resolve(for: palette.style(for: .strong)).needsSyntheticBold)
  #expect(!resolver.resolve(for: palette.style(for: .link)).needsSyntheticBold)
}

@Test func 合成した太字は本文よりはっきり濃く描画される() throws {
  guard let name = fontFamilyWithoutBold() else { return }
  var preferences = Preferences.default
  preferences.fontName = name

  let text = "plain **bold**"
  let storage = NSTextStorage(string: text)
  MarkdownAttributer(theme: .fallback, preferences: preferences).apply(to: storage)

  func attributes(at substring: String) throws -> [NSAttributedString.Key: Any] {
    let range = (text as NSString).range(of: substring)
    try #require(range.location != NSNotFound)
    return storage.attributes(at: range.location, effectiveRange: nil)
  }

  let body = try inkAmount("bold", attributes: try attributes(at: "plain"))
  let strong = try inkAmount("bold", attributes: try attributes(at: "bold"))
  #expect(strong > body * 1.15, "合成のインク量 \(strong) が本文 \(body) に対して不足")
}
