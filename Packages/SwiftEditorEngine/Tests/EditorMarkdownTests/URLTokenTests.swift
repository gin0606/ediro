import Testing
import EditorEngine
@testable import EditorMarkdown
import Foundation

/// The text of each `url` token of `text`.
@MainActor func urls(_ text: String) throws -> [String] {
    try tokens(text).filter { $0.kind == .url }.map { (text as NSString).substring(with: NSRange($0.range)) }
}

// The expected URLs follow NSDataDetector on macOS 27.2.1 (26B131).
@Suite @MainActor struct URLTokenTests {
    @Test func urlsInTextAndInsideConstructs() throws {
        #expect(try urls("見て https://example.com/a と http://example.org/b") == ["https://example.com/a", "http://example.org/b"])
        #expect(try urls("# 見出し https://example.com/a") == ["https://example.com/a"])
        #expect(try urls("## https://example.com/a") == ["https://example.com/a"])
        #expect(try urls("> 引用 http://example.com/a") == ["http://example.com/a"])
        #expect(try urls("> https://example.com/a") == ["https://example.com/a"])
        #expect(try urls("- https://example.com/a") == ["https://example.com/a"])
        #expect(try urls("1. http://example.com/a") == ["http://example.com/a"])
        #expect(try urls("*https://example.com/a*") == ["https://example.com/a"])
        #expect(try urls("HTTPS://EXAMPLE.COM/A") == ["HTTPS://EXAMPLE.COM/A"])
        // A URL nests inside the construct around it.
        #expect(try tokens("**https://example.com/a**") == [FlatToken(kind: .strong, range: 0..<25), FlatToken(kind: .url, range: 2..<23)])
        #expect(try tokens("# https://example.com/a") == [FlatToken(kind: .heading(level: 1), range: 0..<23),
                                                          FlatToken(kind: .url, range: 2..<23)])
        // The rest of a closing fence's line is text.
        #expect(try urls("```\nx\n``` https://example.com/a") == ["https://example.com/a"])
    }

    @Test func theDetectorDecidesWhereAURLEnds() throws {
        #expect(try urls("https://example.comを参照") == ["https://example.com"])
        #expect(try urls("https://ja.wikipedia.org/wiki/日本語") == ["https://ja.wikipedia.org/wiki/日本語"])
        #expect(try urls("(https://example.com/Foo_(bar))") == ["https://example.com/Foo_(bar))"])
        #expect(try urls("詳しくは https://example.com/a。") == ["https://example.com/a"])
        #expect(try urls("https://example.com/a.") == ["https://example.com/a"])
    }

    @Test func aURLEndsWhereItsSpanDoes() throws {
        #expect(try urls("https://en.wikipedia.org/wiki/M*A*S*H") == ["https://en.wikipedia.org/wiki/M"])
        #expect(try urls("**https://example.com/a**b") == ["https://example.com/a"])
        #expect(try urls("https://example.com/a`code`") == ["https://example.com/a"])
        #expect(try urls("https://example.com/a[b](c)") == ["https://example.com/a"])
        #expect(try urls("https://example.com/a<ab:c>") == ["https://example.com/a"])
    }

    @Test func theCharactersBeforeTheSchemeCount() throws {
        #expect(try urls("__https://example.com/u__") == [])
        #expect(try urls("xhttps://example.com") == [])
        #expect(try urls("1https://example.com") == [])
        #expect(try urls("あ1https://example.com") == ["https://example.com"])
        // The window reaches back over more ASCII than the extra characters.
        #expect(try urls("あ123456789https://example.com") == ["https://example.com"])
        // Context further back than one character changes the result: `。1https://…` alone has
        // no URL.
        #expect(try urls("日本。1https://example.com/a b") == ["https://example.com/a"])
        // A scheme inside a URL does not start another.
        #expect(try urls("https://a.example/r?to=https://b.example") == ["https://a.example/r?to=https://b.example"])
        let long = "https://a.example/" + String(repeating: "x", count: 90) + "?to=https://b.example"
        #expect(try urls(long) == [long])
        // Nor does one inside a link that starts before its scheme.
        #expect(try urls("x" + long) == [])
    }

    @Test func aURLLongerThanTheFirstWindowIsWhole() throws {
        let path = String(repeating: "path/", count: 40) + "end"
        #expect(try urls("本文のhttps://example.com/\(path)を参照。") == ["https://example.com/\(path)"])
        // A `(` or `{` left open widens the window up to the bracket closing it.
        let paren = "https://example.com/Foo_(bar" + String(repeating: "あ", count: 150) + ")"
        #expect(try urls(paren + "。") == [paren])
        let brace = "https://example.com/api/{" + String(repeating: "あ", count: 150) + "}"
        #expect(try urls(brace + "。") == [brace])
        // The detector drops a `.` or `,` where the first window cuts the URL, 16 units
        // before its end.
        for mark in [".", ","] {
            let url = "https://example.com/" + String(repeating: "a", count: 107) + mark + "bcdefghij"
            #expect(try urls("本文 \(url) を参照") == [url], "\(mark)")
        }
        // Nor where it drops more than 16 units of punctuation.
        let dots = "https://example.com/" + String(repeating: "a", count: 90) + String(repeating: ".", count: 30) + "bcdefghij"
        #expect(try urls("本文 \(dots) を参照") == [dots])
        // The window keeps growing past 1,024 units for a URL that reaches its end.
        let words = String(repeating: " word", count: 500)
        let long = "https://example.com/" + String(repeating: "abcd/", count: 300) + "a"
        #expect(try urls("本文 \(long)\(words)") == [long])
        // Followed by a bracket, the detector itself ends such a URL early, in the whole span
        // too.
        #expect(try urls(long + "(abc def)" + words).map(\.count) == [179])
        // A window of 1,024 units that would end inside a surrogate pair ends after it. The
        // bracket closes beyond 1,024 units, so the window stops there, and the detector, not
        // seeing it closed, finds no link at the scheme.
        let emoji = "https://example.com/" + String(repeating: "abcd/", count: 120) + "(" + String(repeating: "あ", count: 402) + "😀)"
        #expect(try urls(emoji + "。") == [])
        let bracketed = "https://example.com/(" + String(repeating: "abcd/", count: 300) + ")"
        #expect(try urls("本文 \(bracketed)と(\(String(repeating: "あ", count: 600))") == ["https://example.com/"])
        // Where the window cuts a dotted path, the detector may end the URL tens of units
        // before the cut.
        for path in ["a-b_c.d~e/", "a.b/", "x.y-z/", "path/v1.2.3/"] {
            for padding in ["zz", "zzzz", "zzzzzz"] {
                let url = "https://example.com/\(padding)" + String(repeating: path, count: 30)
                #expect(try urls("本文 \(url) 次") == [url], "\(url)")
            }
        }
        // A second bracket left open, nested brackets closed once or twice, a pair inside the
        // open one, and hosts for which the detector finds nothing in a window that cuts the
        // brackets.
        for url in ["https://example.com/w/(a)(b" + String(repeating: "あ", count: 150) + ")",
                    "https://example.com/a_((b" + String(repeating: "あ", count: 150) + ")c)",
                    "https://example.com/a_((b" + String(repeating: "あ", count: 150) + ")",
                    "https://example.com/a_(b" + String(repeating: "あ", count: 150) + "(x))",
                    "https://zenn.dev/a_(" + String(repeating: "あ", count: 150) + ")",
                    "http://localhost:8080/a_(" + String(repeating: "x", count: 50) + String(repeating: "あ", count: 100) + ")"] {
            #expect(try urls("本文 \(url)。") == [url], "\(url)")
        }
    }

    /// Where the window cuts a URL with characters other than ASCII, or one holding another
    /// URL, the URL is the one the detector finds in the whole span.
    @Test func aCutURLIsTheOneInTheWholeSpan() {
        let detector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let wikipedia = "https://ja.wikipedia.org/wiki/Foo_(" + String(repeating: "あ", count: 120) + ")"
        for url in ["https://example.com/日本語/" + String(repeating: "x.y-z/", count: 30),
                    "https://example.com/aa~aa#a#a(a)aaaaa#a#aaa&a=aaaaaa.aa';aa本?a=a&a=a&a=2-a.aa#a'(a)&a=a?a=aa語a&a=aaa%aa%aa%aa(a)%aa%aa%aaa~語-a.~a",
                    "https://web.archive.org/web/2020/" + String(repeating: "x.y-z/", count: 8) + "https://example.com/"
                        + String(repeating: "path/v1.2.3/", count: 20),
                    "https://web.archive.org/web/2020/" + wikipedia, "https://www.google.com/url?q=" + wikipedia,
                    "https://web.archive.org/web/2020/https://example.com/" + String(repeating: "abcd/", count: 300) + "end",
                    "https://accounts.google.com/ServiceLogin?service=mail&passive=1209600&osid=1&continue=https://mail.google.com/mail/u/0/&followup=https://mail.google.com/mail/u/0/&emr=1",
                    "https://www.google.com/url?q=https://web.archive.org/web/2019/https://example.com/page&sa=D&source=editors&ust=1690000000000000&usg=AOvVaw0abcdefghijklmnopqrst"] {
            let text = "本文 \(url) 次"
            let units = Array(text.utf16)
            let whole = detector.matches(in: text, range: NSRange(location: 0, length: units.count)).map {
                $0.range.location..<($0.range.location + $0.range.length)
            }
            #expect(whole.count == 1 && whole[0].count > 128, "\(url)")
            #expect(URLDetector().urls(in: units, 0..<units.count) == whole, "\(url)")
        }
        // Nor does a URL inside it, which its window cuts, or a link that starts before the
        // scheme, hide the next URL.
        for (start, inner) in [("本文 ", "?u=https://f.org/"), ("本文 ", "/https://e.org/"), ("本文x", ""), ("本文x", "a"), ("本文x", "aaaaaaa")] {
            let text = "\(start)https://example.com/a\(inner)" + String(repeating: "b", count: 100) + "を参照、https://example.org/x 次"
            let units = Array(text.utf16)
            let whole = detector.matches(in: text, range: NSRange(location: 0, length: units.count)).map {
                $0.range.location..<($0.range.location + $0.range.length)
            }
            #expect(whole.count == 2, "\(text)")
            #expect(URLDetector().urls(in: units, 0..<units.count) == whole.filter { httpSchemeLength(units, at: $0.lowerBound, before: units.count) != nil }, "\(text)")
        }
        // A URL that ends just before a window's end, followed by another URL, is whole.
        let archive = "https://web.archive.org/web/20200101000000/https://example.com/articles/" + String(repeating: "a", count: 40)
        for text in ["見て\(archive)、https://next.example/a を参照", "見て\(archive))https://next.example/a を参照",
                     "[\"\(archive)\",\"https://web.archive.org/web/2021/https://example.org/b\"]"] {
            let units = Array(text.utf16)
            let whole = detector.matches(in: text, range: NSRange(location: 0, length: units.count)).map {
                $0.range.location..<($0.range.location + $0.range.length)
            }
            #expect(whole.count == 2 && whole[0].count == archive.utf16.count, "\(text)")
            #expect(URLDetector().urls(in: units, 0..<units.count) == whole, "\(text)")
        }
        let quoted = Array(("本文 https://example.com/a?u=https://f.org/" + String(repeating: "b", count: 100) + "\",\"https://example.org/x 次").utf16)
        #expect(URLDetector().urls(in: quoted, 0..<quoted.count).count == 2)
        let playground = "https://www.typescriptlang.org/play/?#code/" + String(repeating: "PTAEHUFMBsGMHsC2lQBd5oBYEsB2BzUAZwFhBQByqGWGOOnpVEJ", count: 50)
        let ids = "https://example.com/?ids=" + (1...100).map(String.init).joined(separator: ",")
        for text in ["これを見て" + String(playground.prefix(1_500)) + "を参照。", "見て\(ids)を参照", "http://zenn.dev/日本語/%E3%81%82/v1.2.3/日本語/2024これはhttps://example.com/v1.2.3/Foo_(bar)/日本語/v1.2.3/~user/q/index.html/page-12/q→http://localhost:8080/日本語/a/b を参照"] {
            let units = Array(text.utf16)
            let whole = detector.matches(in: text, range: NSRange(location: 0, length: units.count)).map {
                $0.range.location..<($0.range.location + $0.range.length)
            }.filter { httpSchemeLength(units, at: $0.lowerBound, before: units.count) != nil }
            #expect(!whole.isEmpty)
            #expect(URLDetector().urls(in: units, 0..<units.count) == whole, "\(text)")
        }
        // Where printable ASCII a URL may hold goes on past the largest window, the URL is not
        // seen whole, even where the detector ends it earlier.
        for text in ["これを見て\(playground)を参照。", "見て https://example.com/" + String(repeating: "x.y-z/", count: 400) + "end 次"] {
            let units = Array(text.utf16)
            #expect(detector.firstMatch(in: text, range: NSRange(location: 0, length: units.count)) != nil)
            #expect(URLDetector().urls(in: units, 0..<units.count) == [], "\(text)")
        }
    }

    /// In a line of URLs without spaces, the next URL stops a window's growth, and an edit
    /// runs the detector only for the windows around it.
    @Test func windowsInALineOfURLsStayNearTheirScheme() {
        let urls300 = (0..<300).map { "https://example.com/\($0)" }
        let quoted = urls300.map { "\"\($0)\"" }
        // The detector takes URLs joined by commas, or quoted with `'`, for one link, which its
        // window cuts, so it is no URL.
        let single = urls300.map { "'\($0)'" }
        let joined = (0..<600).map { "https://example.com/docs/page-\($0)" }
        // Brackets left open, closed within 1,024 units.
        let opened = (0..<30).map { "\"https://example.com/(\($0)\"" }
        let lines: [(String, Int, Int)] = [
            ("[" + quoted.joined(separator: ",") + "]", 300, 300),
            ("[" + single.joined(separator: ",") + "]", 300, 0),
            ("(" + urls300.joined(separator: ")(") + ")", 300, 300),
            (urls300.map { ")/\($0)" }.joined(), 300, 300),
            ("[" + opened.joined(separator: ",") + String(repeating: ")", count: 30) + "]", 30, 30),
            (joined.joined(separator: ","), 600, 0),
        ]
        for (line, schemes, expected) in lines {
            let detector = URLDetector()
            var units = Array(line.utf16)
            let urls = detector.urls(in: units, 0..<units.count)
            #expect(urls.count == expected, "\(line.prefix(30))")
            #expect(detector.detections < schemes + 20, "\(line.prefix(30))")
            let before = detector.detections
            units.insert(0x61, at: units.count / 2)
            _ = detector.urls(in: units, 0..<units.count)
            #expect(detector.detections - before < 10, "\(line.prefix(30))")
        }
    }

    /// A window grows no further than 2,048 units, nor past a `"`, so a keystroke in a long
    /// run of ASCII after a URL runs the detector only for short windows. A URL the window
    /// still cuts is none, so no token holds part of a URL.
    @Test func windowsStayShortInLongASCII() {
        let data = String(repeating: "QUJDRA+/", count: 1000)
        let json = Array(#"{"url":"https://example.com/a.png","data":"\#(data)"}"#.utf16)
        let detector = URLDetector()
        #expect(detector.urls(in: json, 0..<json.count) == [8..<33])
        #expect(detector.detections == 1)
        let long = Array(("https://example.com/" + String(repeating: "abcd/", count: 1000)).utf16)
        #expect(detector.urls(in: long, 0..<long.count) == [])
        let shorter = Array(("https://example.com/" + String(repeating: "abcd/", count: 400)).utf16)
        #expect(detector.urls(in: shorter, 0..<shorter.count) == [0..<shorter.count])
        // A URL that ends right before the largest window's end, with a space between, is whole.
        let fits = "https://example.com/" + String(repeating: "abcd/", count: 403) + "a"
        let followed = Array((fits + " see more details here about the link").utf16)
        #expect(detector.urls(in: followed, 0..<followed.count) == [0..<fits.utf16.count])
        // A link the window cuts covers the ASCII text after it, up to a space.
        #expect(detector.urls(in: long + Array(" https://example.org/b".utf16), 0..<(long.count + 22)) == [(long.count + 1)..<(long.count + 22)])
        let inside = Array(("x" + String(decoding: long, as: UTF16.self) + "/https://b.example/path 次").utf16)
        #expect(detector.urls(in: inside, 0..<inside.count) == [])
        // Japanese text, or a `"`, ends what it covers.
        let list = Array(("[\"" + String(decoding: long, as: UTF16.self) + "\",\"https://example.org/b\"]").utf16)
        #expect(detector.urls(in: list, 0..<list.count) == [(list.count - 23)..<(list.count - 2)])
        let next = Array((String(decoding: long, as: UTF16.self) + "を参照、https://example.org/x").utf16)
        #expect(detector.urls(in: next, 0..<next.count).last == (next.count - 21)..<next.count)
        for mark in ["<b", ">b"] {
            let tags = Array(("https://example.com/a" + String(repeating: mark, count: 500)).utf16)
            let counter = URLDetector()
            #expect(counter.urls(in: tags, 0..<tags.count) == [0..<21], "\(mark)")
            #expect(counter.detections == 1, "\(mark)")
        }
    }

    /// Text after the URL a window holds does not widen it: neither brackets that close none
    /// the text from the scheme leaves open, nor other URLs.
    @Test func onlyTheURLAtTheSchemeWidensItsWindow() {
        let discussion = String(repeating: " the discussion", count: 10)
        for (text, expected) in [("see https://example.com/p(note a) and \(String(repeating: "x", count: 150)) (x) end", [4..<25]),
                                 ("https://example.com/a [\(String(repeating: "あ", count: 150))]", [0..<21]),
                                 ("Read https://example.com/Foo_(see\(discussion)) first.", [5..<29]),
                                 ("https://example.com/aを参照、\(String(repeating: "あ", count: 150))(x)", [0..<21]),
                                 ("https://example.com/aを参照、\(String(repeating: "あ", count: 150)))", [0..<21]),
                                 ("https://example.com/a_(b\(String(repeating: "あ", count: 150))(x)", []),
                                 ("xhttps://example.com/\(String(repeating: "a", count: 300))", []),
                                 ("本文 https://example.com/(\(String(repeating: "abcd/", count: 15))\(String(repeating: " word", count: 60))", [])] {
            let detector = URLDetector()
            let units = Array(text.utf16)
            #expect(detector.urls(in: units, 0..<units.count) == expected, "\(text)")
            #expect(detector.detections == 1, "\(text)")
        }
        // A closing bracket after 1,024 units does not widen the window either.
        let prose = String(repeating: "あ", count: 1100)
        for text in ["https://example.com/a (\(prose))", "https://example.com/aを参照(注1）\(prose))",
                     "https://example.com/a(注1）\(prose))"] {
            let detector = URLDetector()
            let units = Array(text.utf16)
            #expect(detector.urls(in: units, 0..<units.count) == [0..<21], "\(text)")
            #expect(detector.detections == 1, "\(text)")
        }
        let detector = URLDetector()
        let units = Array((0..<100).map { "https://example.com/\($0) " }.joined().utf16)
        #expect(detector.urls(in: units, 0..<units.count).count == 100)
        #expect(detector.detections == 100)
    }

    @Test func aURLDoesNotHideOtherURLs() throws {
        #expect(try urls("https://a.com https://b.com") == ["https://a.com", "https://b.com"])
        #expect(try urls("see x.com https://example.com/a") == ["https://example.com/a"])
        #expect(try urls("https://b.com x https://a.com@ y https://c.com") == ["https://b.com", "https://c.com"])
        #expect(try urls("https://example.com日本語の文章でhttp://example.org/a: https://example.com/docs/page")
                == ["http://example.org/a:", "https://example.com/docs/page"])
        let prose = String(repeating: "和文", count: 1000)
        #expect(try urls("https://a.com@ \(prose) https://c.com").last == "https://c.com")
    }

    @Test func linkDestinations() throws {
        #expect(try urls("[a](https://example.com/Foo_(bar))") == ["https://example.com/Foo_(bar)"])
        #expect(try urls("[a](https://example.com/?ids[]=1)") == ["https://example.com/?ids[]=1"])
        // Code or an autolink in the label leaves the rest of the link out of the text.
        let code = "[`f()`](https://docs.example/f)"
        #expect(try tokens(code) == [FlatToken(kind: .link, range: 0..<31), FlatToken(kind: .inlineCode, range: 1..<6),
                                     FlatToken(kind: .url, range: 8..<30)])
        #expect(try urls("[`x`](https://example.com/Foo_(bar))baz") == ["https://example.com/Foo_(bar)"])
        #expect(try urls("[`x`](relative \"https://title.example\")") == [])
        #expect(try urls("[<https://a.example>](https://b.example)") == ["https://b.example"])
        #expect(try urls("[<https://a.example>](relative) <https://c.example>") == ["https://c.example"])
        #expect(try urls("[a](b) [<https://x.example>](https://y.example)") == ["https://y.example"])
        #expect(try urls("[a](b) [<https://x.example>](relative)") == [])
        let link = "[label](https://example.com/x)"
        #expect(try tokens(link) == [FlatToken(kind: .link, range: 0..<30), FlatToken(kind: .url, range: 8..<29)])
        #expect(try urls("[https://a.example](https://b.example)") == ["https://b.example"])
        #expect(try urls("[a](<https://example.com/a b>)") == ["https://example.com/a b"])
        #expect(try urls("[a](https://example.com \"title\")") == ["https://example.com"])
        #expect(try urls("[a](HTTP://example.com)") == ["HTTP://example.com"])
        for text in ["[a](mailto:x@example.com)", "[a](example.com)", "[a](https://)", "[a](<https://>)", "[a](httpx://b)", "[a](/https://b)"] {
            #expect(try urls(text) == [], "\(text)")
        }
    }

    @Test func autolinks() throws {
        #expect(try tokens("<https://example.com/a>") == [FlatToken(kind: .url, range: 1..<22)])
        #expect(try urls("<http://example.com/*a*>") == ["http://example.com/*a*"])
        #expect(try urls("<mailto:x@example.com>") == [])
        #expect(try urls("<https://>") == [])
    }

    @Test func noURLsInCodeOrWithoutAScheme() throws {
        #expect(try urls("`https://example.com`") == [])
        #expect(try urls("```\nhttps://example.com\n```") == [])
        #expect(try urls("example.com と www.example.com と x@example.com と mailto:x@example.com") == [])
        #expect(try urls("https:// と http:") == [])
    }

    @Test func theDetectorRunsOncePerWindowText() {
        let detector = URLDetector()
        let units = Array("見て https://example.com/a と https://example.com/b".utf16)
        let found = detector.urls(in: units, 0..<units.count)
        #expect(found.count == 2)
        #expect(detector.detections == 2)
        #expect(detector.urls(in: units, 0..<units.count) == found)
        #expect(detector.detections == 2)
    }

    @Test func aLineHasItsWindowsDetectedInEitherState() {
        // A line in a code block, and the rest of a fence's line opening one, have no url
        // token, but turning to text when the state changes needs no detection. So do the
        // lines after the first within one document line.
        let cases: [(line: String, without: MarkdownTokenizer.State, with: MarkdownTokenizer.State)] = [
            ("> 見て https://example.com/a と https://example.com/b\n", .codeBlock, .text),
            ("```> https://example.com/a\n", .text, .codeBlock),
            ("x\u{2028}> 見て https://example.com/a\n", .codeBlock, .text),
            ("x\u{2028}```> https://example.com/a\n", .text, .codeBlock),
        ]
        for (line, without, with) in cases {
            let tokenizer = MarkdownTokenizer()
            let code = tokenizer.tokenize(line, startingIn: without).tokens
            #expect(!code.isEmpty && code.allSatisfy { $0.kind == "codeBlock" }, "\(line)")
            let detections = tokenizer.detector.detections
            #expect(detections > 0, "\(line)")
            let changed = tokenizer.tokenize(line, startingIn: with)
            #expect(tokenizer.detector.detections == detections, "\(line)")
            #expect(changed.tokens == MarkdownTokenizer().tokenize(line, startingIn: with).tokens, "\(line)")
            #expect(changed.tokens.contains { $0.kind == "url" }, "\(line)")
        }
    }

    @Test func theCacheKeepsTwoGenerations() {
        let lines = (0..<20).map { Array("https://example.com/\($0 + 10)".utf16) }
        // Four windows of 22 units fill a generation.
        let detector = URLDetector(generationCapacity: 88)
        for line in lines { _ = detector.urls(in: line, 0..<line.count) }
        #expect(detector.cachedUnits == 8 * 22)
        // The newest windows stay; an evicted one is detected again, with the same result.
        let detections = detector.detections
        #expect(detector.urls(in: lines[19], 0..<lines[19].count) == [0..<lines[19].count])
        #expect(detector.urls(in: lines[15], 0..<lines[15].count) == [0..<lines[15].count])
        #expect(detector.detections == detections)
        #expect(detector.urls(in: lines[0], 0..<lines[0].count) == [0..<lines[0].count])
        #expect(detector.detections == detections + 1)
    }

    @Test func aWindowMovesToTheNewerGeneration() {
        let lines = (0..<7).map { Array("https://example.com/\($0 + 10)".utf16) }
        let detector = URLDetector(generationCapacity: 5 * 22)
        for line in lines { _ = detector.urls(in: line, 0..<line.count) }
        #expect(detector.cachedUnits == 7 * 22)
        // A window found in the older generation is not kept twice.
        _ = detector.urls(in: lines[2], 0..<lines[2].count)
        #expect(detector.cachedUnits == 7 * 22)
        #expect(detector.detections == 7)
    }

    @Test func aWindowLargerThanAGenerationIsNotKept() {
        let line = Array(("https://example.com/" + String(repeating: "a", count: 200)).utf16)
        let detector = URLDetector(generationCapacity: 100)
        _ = detector.urls(in: line, 0..<line.count)
        #expect(detector.cachedUnits == 0)
    }

    @Test func aWindowInUseStaysCached() {
        let used = Array("https://example.com/u".utf16)
        let detector = URLDetector(generationCapacity: 4 * used.count)
        for index in 0..<20 {
            let line = Array("https://example.com/\(index + 10)".utf16)
            _ = detector.urls(in: line, 0..<line.count)
            #expect(detector.urls(in: used, 0..<used.count) == [0..<used.count])
        }
        #expect(detector.detections == 21)
    }
}

/// The address of each `url` token of a one-line `text`.
@MainActor func addresses(_ text: String) throws -> [String] {
    let all = try tokens(text)
    return all.filter { $0.kind == .url }.map { url in
        let inLink = all.contains { $0.kind == .link && $0.range.lowerBound <= url.range.lowerBound && url.range.upperBound <= $0.range.upperBound }
        return MarkdownTokenizer.address(ofURLTokenAt: url.range, in: text, inLinkDestination: inLink)
    }
}

@Suite @MainActor struct URLAddressTests {
    @Test func escapesAreResolvedInDestinationsAndPlainText() throws {
        #expect(try addresses(#"[a](https://example.com/a\_b\(c\))"#) == ["https://example.com/a_b(c)"])
        #expect(try addresses(#"[a](<https://example.com/a\>b>)"#) == ["https://example.com/a>b"])
        #expect(try addresses(#"https://example.com/M\*A\*S\*H"#) == ["https://example.com/M*A*S*H"])
        // A backslash before anything but ASCII punctuation, or escaped itself, stays.
        #expect(try addresses(#"[a](https://example.com/a\b\\c\あ)"#) == [#"https://example.com/a\b\c\あ"#])
    }

    @Test func aBackslashEndingATokenThatEscapesTheNextCharacterIsDropped() throws {
        #expect(try urls(#"https://example.com/foo\. x"#) == [#"https://example.com/foo\"#])
        #expect(try addresses(#"https://example.com/foo\. x"#) == ["https://example.com/foo"])
        #expect(try addresses(#"(https://example.com/a\)"#) == ["https://example.com/a"])
        // The character a dropped backslash escapes lies outside the token, even a backslash.
        #expect(MarkdownTokenizer.address(ofURLTokenAt: 0..<21, in: #"https://example.com/\\."#, inLinkDestination: false) == "https://example.com/")
        // One before no punctuation stays.
        #expect(MarkdownTokenizer.address(ofURLTokenAt: 0..<20, in: #"https://example.com\a"#, inLinkDestination: false) == #"https://example.com\"#)
        #expect(MarkdownTokenizer.address(ofURLTokenAt: 0..<20, in: #"https://example.com\"#, inLinkDestination: false) == #"https://example.com\"#)
    }

    @Test func backslashesInsideAnAutolinkAreLiteral() throws {
        #expect(try addresses(#"<https://example.com/a\_b>"#) == [#"https://example.com/a\_b"#])
        #expect(try addresses(#"\\<https://example.com/a\_b>"#) == [#"https://example.com/a\_b"#])
        #expect(try addresses(#"[x](https://a.example)<https://example.com/a\_b>"#) == ["https://a.example", #"https://example.com/a\_b"#])
        // An escaped `<` starts no autolink.
        #expect(try addresses(#"\<https://example.com/a\_b>"#) == ["https://example.com/a_b"])
        // Nor does one that does not make an autolink, as a space inside breaks it.
        #expect(try addresses(#"<https://example.com/a\_b c>"#) == [#"https://example.com/a_b c"#])
    }

    @Test func everyASCIIPunctuationCharacterAndNoOtherIsEscapable() {
        let text = (0x20...0x7F).map { #"\"# + String(UnicodeScalar(UInt8($0))) }.joined()
        let punctuation = Set(##"!"#$%&'()*+,-./:;<=>?@[\]^_`{|}~"##)
        let expected = (0x20...0x7F).map { code -> String in
            let character = Character(UnicodeScalar(UInt8(code)))
            return punctuation.contains(character) ? String(character) : #"\"# + String(character)
        }.joined()
        let line = "https://example.com/" + text
        let range = 0..<line.utf16.count
        #expect(MarkdownTokenizer.address(ofURLTokenAt: range, in: line, inLinkDestination: true) == "https://example.com/" + expected)
    }
}
