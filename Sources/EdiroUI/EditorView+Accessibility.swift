import AppKit

extension EditorView {
  override func isAccessibilityElement() -> Bool { true }
  override func accessibilityRole() -> NSAccessibility.Role? { .textArea }
  override func accessibilityValue() -> Any? { text }
  override func accessibilityNumberOfCharacters() -> Int { layout.storage.length }
  override func accessibilitySelectedTextRange() -> NSRange { selectedRange() }
  override func accessibilitySelectedTextRanges() -> [NSValue]? {
    session.selections.map { NSValue(range: nsRange(of: $0.range)) }
  }
  override func accessibilitySelectedText() -> String? {
    accessibilityString(for: selectedRange())
  }

  override func accessibilityInsertionPointLineNumber() -> Int {
    guard layout.storage.length > 0, session.primarySelection.isEmpty else { return NSNotFound }
    return accessibilityLine(for: selectedRange().location)
  }

  override func accessibilityLine(for index: Int) -> Int {
    guard index >= 0, index <= layout.storage.length else { return 0 }
    return layout.visualLines().lastIndex { $0.range.location <= index } ?? 0
  }

  override func accessibilityRange(forLine line: Int) -> NSRange {
    let lines = layout.visualLines()
    guard lines.indices.contains(line) else { return NSRange(location: 0, length: 0) }
    return lines[line].range
  }

  override func accessibilityRange(for index: Int) -> NSRange {
    guard index >= 0, index < layout.storage.length else { return NSRange(location: 0, length: 0) }
    return layout.storage.mutableString.rangeOfComposedCharacterSequence(at: index)
  }

  override func accessibilityString(for range: NSRange) -> String? {
    guard validAccessibilityRange(range) else { return nil }
    return layout.storage.mutableString.substring(with: range)
  }

  override func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? {
    guard validAccessibilityRange(range), range.length > 0 else { return nil }
    let result = NSMutableAttributedString(
      string: layout.storage.mutableString.substring(with: range))
    layout.storage.enumerateAttributes(in: range) { attributes, run, _ in
      var converted: [NSAttributedString.Key: Any] = [:]
      if let font = attributes[.font] as? NSFont {
        var description: [NSAccessibility.FontAttributeKey: Any] = [
          .fontName: font.fontName, .fontSize: font.pointSize,
        ]
        description[.fontFamily] = font.familyName
        description[.visibleName] = font.displayName
        converted[.accessibilityFont] = description
      }
      for (source, target) in [
        (
          NSAttributedString.Key.foregroundColor,
          NSAttributedString.Key.accessibilityForegroundColor
        ),
        (.backgroundColor, .accessibilityBackgroundColor),
        (.underlineColor, .accessibilityUnderlineColor),
        (.strikethroughColor, .accessibilityStrikethroughColor),
      ] {
        if let color = attributes[source] as? NSColor,
          let rgb = color.usingColorSpace(.deviceRGB)
        {
          converted[target] =
            NSColor(
              calibratedRed: rgb.redComponent, green: rgb.greenComponent,
              blue: rgb.blueComponent, alpha: rgb.alphaComponent
            ).cgColor
        }
      }
      for (source, target) in [
        (NSAttributedString.Key.underlineStyle, NSAttributedString.Key.accessibilityUnderline),
        (.strikethroughStyle, .accessibilityStrikethrough),
        (.superscript, .accessibilitySuperscript),
      ] {
        converted[target] = attributes[source]
      }
      if let paragraph = attributes[.paragraphStyle] as? NSParagraphStyle {
        let alignment =
          paragraph.alignment == .natural
          ? (paragraph.baseWritingDirection == .rightToLeft ? NSTextAlignment.right : .left)
          : paragraph.alignment
        converted[.accessibilityAlignment] = alignment.rawValue
      }
      result.setAttributes(
        converted, range: NSRange(location: run.location - range.location, length: run.length))
    }
    return result
  }

  override func accessibilityStyleRange(for index: Int) -> NSRange {
    guard index >= 0, index < layout.storage.length else { return NSRange(location: 0, length: 0) }
    var range = NSRange()
    let full = NSRange(location: 0, length: layout.storage.length)
    accessibilityAttributedString(for: full)?.attributes(
      at: index, longestEffectiveRange: &range, in: full)
    return range
  }

  override func accessibilityFrame(for range: NSRange) -> NSRect {
    guard validAccessibilityRange(range) else { return .zero }
    let rects =
      range.length == 0 ? [layout.caretRect(at: range.location)] : layout.selectionRects(range)
    guard let first = rects.first else { return .zero }
    let frame = rects.dropFirst().reduce(first) { $0.union($1) }
      .offsetBy(dx: textOrigin.x, dy: textOrigin.y)
    guard let window else { return frame }
    return window.convertToScreen(convert(frame, to: nil))
  }

  override func accessibilityRange(for point: NSPoint) -> NSRange {
    guard let window else { return NSRange(location: 0, length: 0) }
    let local = containerPoint(window: window.convertPoint(fromScreen: point))
    guard bounds.contains(CGPoint(x: local.x + textOrigin.x, y: local.y + textOrigin.y)),
      layout.visualLines().contains(where: {
        $0.frame.minY <= local.y && local.y < $0.frame.maxY && local.x < $0.frame.maxX
      }), let index = layout.characterIndex(at: local)
    else { return NSRange(location: 0, length: 0) }
    return accessibilityRange(for: index)
  }

  override func accessibilityVisibleCharacterRange() -> NSRange {
    let visible = visibleRect.offsetBy(dx: -textOrigin.x, dy: -textOrigin.y)
    let lines = layout.visualLines().filter {
      $0.frame.maxY > visible.minY && $0.frame.minY < visible.maxY
    }
    guard let first = lines.first, let last = lines.last else {
      return NSRange(location: 0, length: 0)
    }
    return NSRange(
      location: first.range.location, length: NSMaxRange(last.range) - first.range.location)
  }

  override func setAccessibilitySelectedTextRange(_ range: NSRange) {
    setAccessibilitySelectedTextRanges([NSValue(range: range)])
  }

  override func setAccessibilitySelectedTextRanges(_ ranges: [NSValue]?) {
    guard let ranges, !ranges.isEmpty, ranges.allSatisfy({ validAccessibilityRange($0.rangeValue) })
    else { return }
    commitCompositionForPointer()
    let string = layout.storage.mutableString
    let normalized = ranges.map { value in
      let range = value.rangeValue
      let start =
        range.location < string.length
        ? string.rangeOfComposedCharacterSequence(at: range.location).location : range.location
      var end = range.length == 0 ? start : NSMaxRange(range)
      // エンジンの位置はサロゲートペアの途中を表せない。
      if end > 0, end < string.length,
        (0xD800...0xDBFF).contains(string.character(at: end - 1)),
        (0xDC00...0xDFFF).contains(string.character(at: end))
      {
        end += 1
      }
      return NSRange(location: start, length: end - start)
    }
    select(normalized, primary: 0)
  }

  override func setAccessibilitySelectedText(_ value: String?) {
    guard let value else { return }
    let range = selectedRange()
    commitCompositionForPointer()
    let replacement = Self.normalizingLineEndings(value)
    let end = range.location + replacement.utf16.count
    let edit = Replacement(range, replacement)
    var selecting = selections(after: [edit])
    selecting[session.primaryIndex] = (end, end)
    replace([edit], selecting: selecting)
  }

  override func setAccessibilityValue(_ value: Any?) {
    guard let value = value as? String else { return }
    commitCompositionForPointer()
    let replacement = Self.normalizingLineEndings(value)
    let end = replacement.utf16.count
    replace(
      [Replacement(NSRange(location: 0, length: layout.storage.length), replacement)],
      selecting: Array(repeating: (end, end), count: session.selections.count))
  }

  private func validAccessibilityRange(_ range: NSRange) -> Bool {
    range.location >= 0 && range.location <= layout.storage.length
      && range.length >= 0 && range.length <= layout.storage.length - range.location
  }
}
