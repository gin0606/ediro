import AppKit
import ObjectiveC
import TestSupport
import Testing

@testable import EdiroUI

extension AppKitTests {
  /// 参照 NSTextView が利用者に提供している機能を、プログラムから観測できる範囲で書き出す。
  /// 自前のビューに置き換えたエディタで回復すべき機能を、洗い出す根拠にする。
  ///
  /// EDIRO_INVENTORY=1 swift test --filter ReferenceInventoryTests
  /// 値は開発機のシステム設定 (テキスト置換の一覧や自動スペル修正の既定など) で変わるので、
  /// 既定の `swift test` では走らせない。
  @Suite(.enabled(if: ProcessInfo.processInfo.environment["EDIRO_INVENTORY"] == "1"))
  struct ReferenceInventoryTests {
    private func report(_ title: String, _ lines: [String]) {
      // 値に改行が含まれても、各行に印を付けて抜き出せるようにする。
      let body = lines.flatMap { $0.components(separatedBy: .newlines) }
      print((["INVENTORY ## \(title)"] + body.map { "INVENTORY \($0)" }).joined(separator: "\n"))
    }

    // MARK: - 右クリックメニュー

    /// 項目の検証は、チェック印や切り替わる題名を設定するので、状態を読む前に行う。
    private func validate(_ item: NSMenuItem, textView: NSTextView) -> String? {
      guard let action = item.action else { return nil }
      // 自動の有効化を切ったメニューでは、AppKit は項目の値をそのまま使う。
      if item.menu?.autoenablesItems == false { return item.isEnabled ? "enabled" : "disabled" }
      let target = item.target ?? (textView.responds(to: action) ? textView : nil)
      guard let target else { return "not-responding" }
      // NSTextCheckingController のように、プロトコルを採用せずに検証だけを実装する target もある。
      let validation = #selector(NSMenuItemValidation.validateMenuItem(_:))
      if let object = target as? NSObject, object.responds(to: validation) {
        typealias Validate = @convention(c) (NSObject, Selector, NSMenuItem) -> ObjCBool
        let validate = unsafeBitCast(object.method(for: validation), to: Validate.self)
        return validate(object, validation, item).boolValue ? "enabled" : "disabled"
      }
      if let validator = target as? NSUserInterfaceValidations {
        return validator.validateUserInterfaceItem(item) ? "enabled" : "disabled"
      }
      return item.isEnabled ? "enabled" : "disabled"
    }

    /// `menu(for:)` が返した時点の項目。表示の直前に AppKit が足す項目 (サービスなど) は含まない。
    private func describe(_ menu: NSMenu, textView: NSTextView, depth: Int = 0) -> [String] {
      menu.delegate?.menuNeedsUpdate?(menu)
      let indent = String(repeating: "  ", count: depth)
      var lines: [String] = []
      for item in menu.items {
        let validation = validate(item, textView: textView)
        var fields = [item.isSeparatorItem ? "---" : item.title]
        if let action = item.action { fields.append("action=\(NSStringFromSelector(action))") }
        if let target = item.target { fields.append("target=\(type(of: target))") }
        if item.state == .on { fields.append("state=on") }
        if item.state == .mixed { fields.append("state=mixed") }
        if item.isHidden { fields.append("hidden") }
        if item.isAlternate { fields.append("alternate") }
        if item.isAlternate || !item.keyEquivalent.isEmpty {
          fields.append(
            "key=\(item.keyEquivalent.debugDescription) modifiers=\(item.keyEquivalentModifierMask.rawValue)"
          )
        }
        if item.tag != 0 { fields.append("tag=\(item.tag)") }
        if let validation { fields.append(validation) }
        lines.append(indent + fields.joined(separator: " | "))
        if let submenu = item.submenu {
          lines += describe(submenu, textView: textView, depth: depth + 1)
        }
      }
      return lines
    }

    @Test func 右クリックメニューの項目を記録する() throws {
      let text = "This is a mispeled word."
      let cases: [(name: String, selection: NSRange, click: Int)] = [
        ("選択あり (選択の上で右クリック)", NSRange(location: 0, length: 4), 1),
        ("選択あり (選択の外の単語の上で右クリック)", NSRange(location: 0, length: 4), 20),
        ("選択なし (キャレットと同じ単語の上)", NSRange(location: 2, length: 0), 1),
        ("選択なし (キャレットから離れた単語の上)", NSRange(location: 2, length: 0), 20),
        ("誤りの単語の上", NSRange(location: 0, length: 0), 12),
      ]
      // 全角・日本語の本文では、変換のサブメニューの中身が変わる。
      let japanese = "全角ＡＢＣ　テスト です"
      let japaneseCases: [(name: String, selection: NSRange, click: Int)] = [
        ("全角の英字と漢字を選択", (japanese as NSString).range(of: "全角ＡＢＣ"), 3)
      ]
      for (text, testCase) in cases.map({ (text, $0) }) + japaneseCases.map({ (japanese, $0) }) {
        let reference = ReferenceTextView(text: text)
        defer { reference.close() }
        reference.textView.setSelectedRange(testCase.selection)
        let event = try #require(reference.rightMouseDown(at: testCase.click))
        let menu = reference.textView.menu(for: event)
        let lines = menu.map { describe($0, textView: reference.textView) } ?? ["(nil)"]
        report(
          "右クリックメニュー: \(testCase.name)",
          [
            "text=\(text) selection=\(testCase.selection) click=\(testCase.click) selectionAfter=\(reference.textView.selectedRange())",
            "note=観測できない: 表示の直前に AppKit が足す項目 (サービスなど) は含まない",
          ] + lines)
      }
    }

    // MARK: - 既定値

    @Test func 設定の既定値を記録する() {
      let reference = ReferenceTextView(text: "hello")
      defer { reference.close() }
      let textView = reference.textView
      let draggedTypesBefore = textView.registeredDraggedTypes.map(\.rawValue).sorted()
      // ウィンドウに載せた時点ではドロップの型が登録されていないので、登録を直接呼んだ後の値も
      // 記録する。
      textView.updateDragTypeRegistration()
      // 書き出せる型は選択に依存する。
      textView.setSelectedRange(NSRange(location: 0, length: 5))
      let values: [(String, Any)] = [
        ("window.isKeyWindow", reference.window.isKeyWindow),
        ("NSApp != nil", NSApp != nil),
        ("isContinuousSpellCheckingEnabled", textView.isContinuousSpellCheckingEnabled),
        ("isGrammarCheckingEnabled", textView.isGrammarCheckingEnabled),
        ("isAutomaticSpellingCorrectionEnabled", textView.isAutomaticSpellingCorrectionEnabled),
        ("smartInsertDeleteEnabled", textView.smartInsertDeleteEnabled),
        ("isAutomaticQuoteSubstitutionEnabled", textView.isAutomaticQuoteSubstitutionEnabled),
        ("isAutomaticDashSubstitutionEnabled", textView.isAutomaticDashSubstitutionEnabled),
        ("isAutomaticLinkDetectionEnabled", textView.isAutomaticLinkDetectionEnabled),
        ("isAutomaticDataDetectionEnabled", textView.isAutomaticDataDetectionEnabled),
        ("isAutomaticTextReplacementEnabled", textView.isAutomaticTextReplacementEnabled),
        ("isAutomaticTextCompletionEnabled", textView.isAutomaticTextCompletionEnabled),
        // NSTextInputTraitType は 0 が default (システムの設定に従う)、1 が no、2 が yes。
        ("inlinePredictionType", textView.inlinePredictionType.rawValue),
        ("mathExpressionCompletionType", textView.mathExpressionCompletionType.rawValue),
        ("enabledTextCheckingTypes", String(textView.enabledTextCheckingTypes, radix: 2)),
        ("writingToolsBehavior", textView.writingToolsBehavior.rawValue),
        ("allowedWritingToolsResultOptions", textView.allowedWritingToolsResultOptions.rawValue),
        (
          "NSWritingToolsCoordinator.isWritingToolsAvailable",
          NSWritingToolsCoordinator.isWritingToolsAvailable
        ),
        ("usesFindBar", textView.usesFindBar),
        ("usesFontPanel", textView.usesFontPanel),
        ("usesRuler", textView.usesRuler),
        ("isRulerVisible", textView.isRulerVisible),
        ("usesInspectorBar", textView.usesInspectorBar),
        ("importsGraphics", textView.importsGraphics),
        ("allowsImageEditing", textView.allowsImageEditing),
        ("displaysLinkToolTips", textView.displaysLinkToolTips),
        ("acceptsGlyphInfo", textView.acceptsGlyphInfo),
        ("allowsCharacterPickerTouchBarItem", textView.allowsCharacterPickerTouchBarItem),
        ("layoutOrientation", textView.layoutOrientation.rawValue),
        ("selectionGranularity", textView.selectionGranularity.rawValue),
        ("registeredDraggedTypes (登録前)", draggedTypesBefore),
        (
          "registeredDraggedTypes (updateDragTypeRegistration 後)",
          textView.registeredDraggedTypes.map(\.rawValue).sorted()
        ),
        ("readablePasteboardTypes", textView.readablePasteboardTypes.map(\.rawValue)),
        ("writablePasteboardTypes (5 文字を選択)", textView.writablePasteboardTypes.map(\.rawValue)),
        ("acceptableDragTypes", textView.acceptableDragTypes.map(\.rawValue)),
        ("textLayoutManager != nil (TextKit 2)", textView.textLayoutManager != nil),
        (
          "NSSpellChecker.isAutomaticSpellingCorrectionEnabled",
          NSSpellChecker.isAutomaticSpellingCorrectionEnabled
        ),
        (
          "NSSpellChecker.isAutomaticTextReplacementEnabled",
          NSSpellChecker.isAutomaticTextReplacementEnabled
        ),
        (
          "NSSpellChecker.isAutomaticTextCompletionEnabled",
          NSSpellChecker.isAutomaticTextCompletionEnabled
        ),
        (
          "NSSpellChecker.isAutomaticInlinePredictionEnabled",
          NSSpellChecker.isAutomaticInlinePredictionEnabled
        ),
        (
          "NSSpellChecker.userReplacementsDictionary.count",
          NSSpellChecker.shared.userReplacementsDictionary.count
        ),
      ]
      report("既定値", values.map { "\($0.0) = \($0.1)" })
    }

    // MARK: - 入力への効果

    private func describeAttributes(_ storage: NSTextStorage) -> String {
      var keys: [String] = []
      storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) {
        attributes, range, _ in
        for (key, value) in attributes
        where ![.font, .paragraphStyle, .foregroundColor].contains(key) {
          keys.append("\(key.rawValue)@\(range.location),\(range.length)=\(value)")
        }
      }
      keys.sort()
      return keys.isEmpty ? "(なし)" : keys.joined(separator: "; ")
    }

    /// TextKit 2 の rendering attribute の区間。スペルの下線や置換の記録はここに付く。
    private func renderingRuns(_ textView: NSTextView) throws -> [(
      location: Int, length: Int, attributes: [NSAttributedString.Key: Any]
    )] {
      let layoutManager = try #require(textView.textLayoutManager)
      let start = layoutManager.documentRange.location
      var runs: [(location: Int, length: Int, attributes: [NSAttributedString.Key: Any])] = []
      layoutManager.enumerateRenderingAttributes(from: start, reverse: false) {
        _, attributes, range in
        runs.append(
          (
            layoutManager.offset(from: start, to: range.location),
            layoutManager.offset(from: range.location, to: range.endLocation), attributes
          ))
        return true
      }
      return runs
    }

    private func describeRenderingAttributes(_ textView: NSTextView) throws -> String {
      let runs = try renderingRuns(textView)
      return runs.isEmpty
        ? "(なし)"
        : runs.map { "\($0.location),\($0.length)=\($0.attributes.keys.map(\.rawValue).sorted())" }
          .joined(separator: "; ")
    }

    @Test func 入力支援の効果を記録する() async throws {
      let checker = NSSpellChecker.shared
      // 結果が変わらなくても、効果が無いとは限らない。観測できない場合は、その旨を記録に添える。
      let unchanged: (String, String) -> Bool = { input, result in input == result }
      let replacementNote: (String, String) -> String? = { input, result in
        guard unchanged(input, result) else { return nil }
        return checker.userReplacementsDictionary["omw"] == nil
          ? "観測できない: このプロセスから見えるテキスト置換の一覧に omw が無い"
          : "観測できない: 置換の一覧に omw があるが、本文には適用されなかった"
      }
      let correctionNote: (String, String) -> String? = { input, result in
        guard unchanged(input, result) else { return nil }
        let candidate = checker.correction(
          forWordRange: (input as NSString).range(of: "teh"), in: input,
          language: "en", inSpellDocumentWithTag: 0)
        guard let candidate else { return "観測できない: スペルチェッカーが修正候補を返さない" }
        return "観測できない: スペルチェッカーは修正候補 \(candidate) を返すが、本文には適用されなかった"
      }
      let grammarNote: (NSTextView) throws -> String? = { textView in
        let marked = try self.renderingRuns(textView).contains { run in
          run.attributes.keys.contains { $0.rawValue.localizedCaseInsensitiveContains("grammar") }
            || (run.attributes[.spellingState] as? Int).map {
              $0 & NSAttributedString.SpellingState.grammar.rawValue != 0
            } == true
        }
        return marked ? nil : "観測できない: 文法の誤りの印が rendering attribute に現れない"
      }
      let inlineNote: (String, String) -> String? = { input, result in
        guard unchanged(input, result) else { return nil }
        return "観測できない: 予測、数式、テキスト補完の候補は、入力メソッドが本文の外に出す"
      }
      let none: (String, String) -> String? = { _, _ in nil }
      let cases:
        [(
          name: String, input: String, note: (String, String) -> String?,
          configure: (NSTextView) -> Void
        )] = [
          ("既定のまま引用符・ダッシュ・リンク", "\"a\" it's a--b https://example.com ", none, { _ in }),
          ("引用符の置換をオン", "\"a\" it's ", none, { $0.isAutomaticQuoteSubstitutionEnabled = true }),
          ("ダッシュの置換をオン", "a--b ", none, { $0.isAutomaticDashSubstitutionEnabled = true }),
          (
            "テキスト置換をオン (omw)", "omw ", replacementNote,
            { $0.isAutomaticTextReplacementEnabled = true }
          ),
          ("既定のまま綴りの誤り", "I saw teh cat ", none, { _ in }),
          (
            "自動スペル修正と入力中のチェックをオン", "I saw teh cat ", correctionNote,
            {
              $0.isAutomaticSpellingCorrectionEnabled = true
              $0.isContinuousSpellCheckingEnabled = true
            }
          ),
          (
            "スマートリンクをオン", "see https://example.com now ", none,
            { $0.isAutomaticLinkDetectionEnabled = true }
          ),
          (
            "データ検出をオン", "call 03-1234-5678 tomorrow at 3pm ", none,
            { $0.isAutomaticDataDetectionEnabled = true }
          ),
          ("既定のまま数式", "2+3=", inlineNote, { _ in }),
          ("数式補完をオン", "2+3=", inlineNote, { $0.mathExpressionCompletionType = .yes }),
          ("既定のまま入力の途中", "Thank you very ", inlineNote, { _ in }),
          ("インライン予測をオン", "Thank you very ", inlineNote, { $0.inlinePredictionType = .yes }),
          (
            "テキスト補完をオフ", "Thank you very ", inlineNote,
            { $0.isAutomaticTextCompletionEnabled = false }
          ),
        ]
      for testCase in cases {
        let reference = ReferenceTextView()
        defer { reference.close() }
        testCase.configure(reference.textView)
        await reference.type(testCase.input)
        report(
          "入力: \(testCase.name)",
          [
            "input=\(testCase.input.debugDescription)",
            "result=\(reference.textView.string.debugDescription)",
            "attributes=\(describeAttributes(try #require(reference.textView.textStorage)))",
            "renderingAttributes=\(try describeRenderingAttributes(reference.textView))",
          ]
            + [testCase.note(testCase.input, reference.textView.string)].compactMap {
              $0.map { "note=\($0)" }
            })
      }

      // 文法の誤りは、入力中のチェックと文法チェックの両方がオンのときに検査される。
      let grammar = ReferenceTextView()
      defer { grammar.close() }
      grammar.textView.isContinuousSpellCheckingEnabled = true
      grammar.textView.isGrammarCheckingEnabled = true
      let sentence = "He go to school yesterday and they is happy. "
      await grammar.type(sentence, settle: .seconds(1))
      report(
        "入力: 入力中のチェックと文法チェックをオン",
        [
          "input=\(sentence.debugDescription)",
          "result=\(grammar.textView.string.debugDescription)",
          "renderingAttributes=\(try describeRenderingAttributes(grammar.textView))",
        ] + [try grammarNote(grammar.textView)].compactMap { $0.map { "note=\($0)" } })
    }

    @Test func 入力中のスペルチェックの表示を記録する() async throws {
      let reference = ReferenceTextView()
      defer { reference.close() }
      reference.textView.isContinuousSpellCheckingEnabled = true
      let text = "This is a mispeled word. "
      let word = (text as NSString).range(of: "mispeled")
      await reference.type(text, settle: .zero)
      // 誤りの単語に、ちょうど印が付いたら観測できたとみなす。
      func isMarked() -> Bool {
        let runs = (try? renderingRuns(reference.textView)) ?? []
        return runs.contains {
          $0.location == word.location && $0.length == word.length
            && $0.attributes[.spellingState] != nil
        }
      }
      let observed = await waitUntil(isMarked, timeout: .seconds(3))
      report(
        "入力中のスペルチェック",
        ["renderingAttributes=\(try describeRenderingAttributes(reference.textView))"])
      // 誤りの単語に印が付かなければ、下線を観測できていないので記録として使えない。
      #expect(observed)
    }

    @Test func 単語単位の削除と貼り付けの空白の調整を記録する() throws {
      let smartPaste = NSPasteboard.PasteboardType("NeXT smart paste pasteboard type")
      for smart in [true, false] {
        var lines: [String] = []
        // ダブルクリックで単語を選んだ状態は、選択の粒度が単語になっている。
        for granularity in [NSSelectionGranularity.selectByWord, .selectByCharacter] {
          let deletion = ReferenceTextView(text: "hello world foo")
          defer { deletion.close() }
          deletion.textView.smartInsertDeleteEnabled = smart
          let smartRange = deletion.textView.smartDeleteRange(
            forProposedRange: NSRange(location: 6, length: 5))
          deletion.textView.setSelectedRange(NSRange(location: 6, length: 5))
          deletion.textView.selectionGranularity = granularity
          deletion.textView.delete(nil)
          lines.append(
            "granularity=\(granularity == .selectByWord ? "word" : "character") smartDeleteRange({6, 5}) -> \(smartRange), delete 'world' from 'hello world foo' -> '\(deletion.textView.string)'"
          )
        }
        // スマートペーストの型は、単語単位で選んでコピーしたときに付く。
        for marked in [true, false] {
          let insertion = ReferenceTextView(text: "hellofoo")
          defer { insertion.close() }
          insertion.textView.smartInsertDeleteEnabled = smart
          let pasteboard = NSPasteboard(name: NSPasteboard.Name("ediro-inventory-\(UUID())"))
          defer { pasteboard.releaseGlobally() }
          pasteboard.declareTypes(marked ? [.string, smartPaste] : [.string], owner: nil)
          pasteboard.setString("world", forType: .string)
          if marked { pasteboard.setString("", forType: smartPaste) }
          insertion.textView.setSelectedRange(NSRange(location: 5, length: 0))
          try #require(insertion.textView.readSelection(from: pasteboard))
          lines.append(
            "smartPasteType=\(marked) paste 'world' at 5 of 'hellofoo' -> '\(insertion.textView.string)'"
          )
        }
        report("スマートコピー/ペースト: smartInsertDeleteEnabled=\(smart)", lines)
      }
    }

    @Test func 文字列以外の型の貼り付けを記録する() throws {
      let rtf = try NSAttributedString(
        string: "rich", attributes: [.font: NSFont.boldSystemFont(ofSize: 12)]
      )
      .data(
        from: NSRange(location: 0, length: 4),
        documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
      let directory = TestArtifacts.directory()
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let file = directory.appending(path: "pasted file.md")
      try "# file contents\n".write(to: file, atomically: true, encoding: .utf8)
      let cases: [(String, (NSPasteboard) -> Void)] = [
        // ペーストボードは RTF から文字列の型を自動で足す。
        ("RTF (文字列の型が自動で加わる)", { $0.setData(rtf, forType: .rtf) }),
        ("HTML のみ", { $0.setString("<b>html</b> text", forType: .html) }),
        ("URL のみ", { $0.writeObjects([URL(string: "https://example.com/a")! as NSURL]) }),
        ("ファイル URL のみ", { $0.writeObjects([file as NSURL]) }),
      ]
      var lines: [String] = []
      for (name, write) in cases {
        let reference = ReferenceTextView(text: "[]")
        defer { reference.close() }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ediro-inventory-\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        write(pasteboard)
        reference.textView.setSelectedRange(NSRange(location: 1, length: 0))
        let accepted = reference.textView.readSelection(from: pasteboard)
        let storage = try #require(reference.textView.textStorage)
        // 書式が残ったかは、貼った文字の属性が本文の "[" と同じかで見る。
        let inserted = storage.length - 2
        let keptFormatting =
          inserted > 0
          ? "\(!NSDictionary(dictionary: storage.attributes(at: 1, effectiveRange: nil)).isEqual(to: storage.attributes(at: 0, effectiveRange: nil)))"
          : "(挿入なし)"
        lines.append(
          "\(name): types=\(pasteboard.types?.map(\.rawValue) ?? []) accepted=\(accepted) result=\(reference.textView.string.debugDescription) attributes=\(describeAttributes(storage)) 本文と属性が違う=\(keptFormatting)"
            .replacingOccurrences(of: directory.path(percentEncoded: false), with: "<一時ディレクトリ>")
        )
      }
      report("貼り付け: readSelection(from:)", lines)
    }

    @Test func 補完と取り消しの動作名を記録する() async {
      let text = "hello help helium "
      let reference = ReferenceTextView(text: text)
      defer { reference.close() }
      let partial = NSRange(location: (text as NSString).length, length: 3)
      reference.textView.setSelectedRange(NSRange(location: partial.location, length: 0))
      await reference.type("hel")
      var index = -1
      let completions = reference.textView.completions(
        forPartialWordRange: partial, indexOfSelectedItem: &index)
      var lines = [
        "completions('hel') = \(completions ?? []) selected=\(index)",
        "typing -> \(reference.textView.string.debugDescription) undoActionName='\(reference.textView.undoManager?.undoActionName ?? "(nil)")'",
      ]
      // 操作ごとに本文と取り消せるかも記録し、動作名が空なのか、操作が効かなかったのか、
      // 取り消しに載らなかったのかを区別できるようにする。
      let steps: [(String, NSRange, (NSTextView) -> Void)] = [
        ("delete:", NSRange(location: 0, length: 5), { $0.delete(nil) }),
        ("deleteForward:", NSRange(location: 0, length: 0), { $0.deleteForward(nil) }),
        ("deleteBackward: (選択あり)", NSRange(location: 0, length: 2), { $0.deleteBackward(nil) }),
      ]
      for (name, selection, operation) in steps {
        // 前の操作の履歴が残ると、この操作が取り消しに載ったかを canUndo で見分けられない。
        reference.textView.undoManager?.removeAllActions()
        reference.textView.setSelectedRange(selection)
        operation(reference.textView)
        try? await Task.sleep(for: .milliseconds(100))
        lines.append(
          "\(name) -> \(reference.textView.string.debugDescription) canUndo=\(reference.textView.undoManager?.canUndo ?? false) undoActionName='\(reference.textView.undoManager?.undoActionName ?? "(nil)")'"
        )
      }
      report("補完と取り消しの動作名", lines)
    }

    // MARK: - 応答するセレクタ

    /// プロトコルが宣言するインスタンスメソッド。必須と任意の両方を含む。
    /// 実行時に登録されていないプロトコルは nil を返す。
    private func selectors(of name: String) -> [Selector]? {
      guard let proto = objc_getProtocol(name) else { return nil }
      return [true, false].flatMap { required -> [Selector] in
        var count: UInt32 = 0
        guard let list = protocol_copyMethodDescriptionList(proto, required, true, &count) else {
          return []
        }
        defer { free(list) }
        return (0..<Int(count)).compactMap { list[$0].name }
      }
      .sorted { NSStringFromSelector($0) < NSStringFromSelector($1) }
    }

    /// NSTextView.h・NSText.h・NSResponder.h が sender を取る action として宣言しているもののうち、
    /// NSStandardKeyBindingResponding に無いもの。本文の編集に関わらない NSResponder の
    /// newWindowForTab: と showContextHelp: は除く。
    private static let textViewActions = """
      alignCenter: alignJustified: alignLeft: alignRight: changeAttributes: changeColor: \
      changeDocumentBackgroundColor: changeFont: changeLayoutOrientation: checkSpelling: \
      checkTextInDocument: checkTextInSelection: copy: copyFont: copyRuler: cut: delete: \
      highlight: loosenKerning: lowerBaseline: orderFrontLinkPanel: orderFrontListPanel: \
      orderFrontSharingServicePicker: orderFrontSpacingPanel: orderFrontSubstitutionsPanel: \
      orderFrontTablePanel: outline: paste: pasteAsPlainText: pasteAsRichText: pasteFont: \
      pasteRuler: performFindPanelAction: performTextFinderAction: raiseBaseline: \
      showGuessPanel: showWritingTools: startSpeaking: stopSpeaking: subscript: superscript: \
      tightenKerning: toggleAutomaticDashSubstitution: toggleAutomaticDataDetection: \
      toggleAutomaticLinkDetection: toggleAutomaticQuoteSubstitution: \
      toggleAutomaticSpellingCorrection: toggleAutomaticTextCompletion: \
      toggleAutomaticTextReplacement: toggleBaseWritingDirection: toggleContinuousSpellChecking: \
      toggleGrammarChecking: toggleQuickLookPreviewPanel: toggleRuler: toggleSmartInsertDelete: \
      toggleTraditionalCharacterShape: turnOffKerning: turnOffLigatures: underline: unscript: \
      useAllLigatures: useStandardKerning: useStandardLigatures:
      """.split(separator: " ").map { NSSelectorFromString(String($0)) }

    /// 参照の右クリックメニューに出る、target を持たない action のうち、ヘッダの宣言に無いもの。
    /// target を持つ項目 (候補・共有・調べるなど) は、その target が処理するので含めない。
    private static let menuActions = """
      replaceQuotesInSelection: replaceDashesInSelection: replaceTextInSelection: \
      convertToFullWidth: convertToHalfWidth: _searchWithGoogleFromMenu: \
      _invokeProofreadingFeedbackReportConcern:
      """.split(separator: " ").map { NSSelectorFromString(String($0)) }

    /// AppKit のクラスはこのプロトコルを採用しておらず、実行時に登録されない場合がある。
    private static let servicesRequestor = [
      "readSelectionFromPasteboard:", "writeSelectionToPasteboard:types:",
    ].map(NSSelectorFromString)

    /// そのクラスが自分で実装しているか。NSView から継承しただけの応答は区別する。
    private func mark(_ type: AnyClass, _ selector: Selector) -> String {
      func implementation(_ type: AnyClass) -> IMP? {
        class_getInstanceMethod(type, selector).map(method_getImplementation)
      }
      guard let own = implementation(type) else { return "-" }
      return own == implementation(NSView.self) ? "i" : "o"
    }

    @Test func 応答するセレクタを記録する() throws {
      let reference = ReferenceTextView()
      defer { reference.close() }
      var groups: [(String, [Selector])] = []
      for name in [
        "NSStandardKeyBindingResponding", "NSChangeSpelling", "NSIgnoreMisspelledWords",
        "NSTextInputClient", "NSTextCheckingClient", "NSTextInputTraits", "NSDraggingSource",
        "NSDraggingDestination",
      ] {
        guard let list = selectors(of: name) else {
          report("応答するセレクタ: \(name)", ["観測できない: プロトコルが実行時に登録されていない"])
          continue
        }
        groups.append((name, list))
      }
      groups += [
        ("NSServicesMenuRequestor", Self.servicesRequestor),
        ("NSTextView/NSText の action", Self.textViewActions),
        ("右クリックメニューの action", Self.menuActions),
      ]
      for (name, list) in groups {
        report(
          "応答するセレクタ: \(name) (参照 / EditorView。i は NSView から継承した応答だけ)",
          list.map { selector in
            "\(mark(NSTextView.self, selector)) \(mark(EditorView.self, selector)) \(NSStringFromSelector(selector))"
          })
      }

      // 旧来の名前の型と UTI の型とで応答が違うので、両方を記録する。
      let legacyString = NSPasteboard.PasteboardType("NSStringPboardType")
      func describeRequestor(_ requestor: Any?) -> String {
        guard let requestor else { return "nil" }
        return (requestor as AnyObject) === reference.textView ? "self" : "\(type(of: requestor))"
      }
      var services: [String] = []
      for selection in [NSRange(location: 0, length: 0), NSRange(location: 0, length: 5)] {
        reference.textView.string = "hello world"
        reference.textView.setSelectedRange(selection)
        for (name, pasteboardType) in [
          (".string", NSPasteboard.PasteboardType.string), ("NSStringPboardType", legacyString),
        ] {
          let send = reference.textView.validRequestor(forSendType: pasteboardType, returnType: nil)
          let receive = reference.textView.validRequestor(
            forSendType: nil, returnType: pasteboardType)
          services.append(
            "selection=\(selection) \(name) send=\(describeRequestor(send)) return=\(describeRequestor(receive))"
          )
        }
      }
      report("サービス: validRequestor(forSendType:returnType:)", services)
    }
  }
}
