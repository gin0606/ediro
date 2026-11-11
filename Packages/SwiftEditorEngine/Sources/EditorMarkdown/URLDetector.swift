import Foundation

/// The length of `http://` or `https://`, in any case, at `index`, or nil when neither
/// starts there.
func httpSchemeLength(_ units: [UInt16], at index: Int, before end: Int) -> Int? {
    /// Whether the unit at `offset` is the ASCII letter `lower` in either case.
    func letter(_ offset: Int, _ lower: UInt16) -> Bool {
        index + offset < end && units[index + offset] | 0x20 == lower
    }
    guard letter(0, 0x68), letter(1, 0x74), letter(2, 0x74), letter(3, 0x70) else { return nil }
    let colon = letter(4, 0x73) ? index + 5 : index + 4
    guard colon + 3 <= end, units[colon] == 0x3A, units[colon + 1] == 0x2F, units[colon + 2] == 0x2F else { return nil }
    return colon + 3 - index
}

/// Whether `unit` is whitespace.
func isWhitespace(_ unit: UInt16) -> Bool {
    Unicode.Scalar(unit)?.properties.isWhitespace ?? false
}

/// Whether `unit` is printable ASCII other than a space.
private func isVisibleASCII(_ unit: UInt16) -> Bool {
    (0x21...0x7E).contains(unit)
}

/// Whether `unit` is printable ASCII a URL may hold: not a space, `"`, `<` or `>`.
private func mayContinueURL(_ unit: UInt16) -> Bool {
    isVisibleASCII(unit) && unit != 0x22 && unit != 0x3C && unit != 0x3E
}

private let linkDetector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

/// The opening brackets that keep the detector from ending a link inside them, and their
/// closing ones.
private let brackets: [(open: UInt16, close: UInt16)] = [(0x28, 0x29), (0x5B, 0x5D), (0x7B, 0x7D)]

/// Finds the http and https URLs in a span of plain text with `NSDataDetector`.
///
/// The detector's results depend on text far from them: in the whole of
/// `https://b.com x https://a.com@ y https://c.com` it finds `https://b.com` only, and a long
/// line takes longer than a keystroke may. So the detector sees a window of the span around
/// each `http://` or `https://`, and its results there are the URLs:
///
/// - The window starts before the scheme by the printable ASCII characters other than a
///   space that run up to it, at most 64, and then by up to 8 more characters, so the
///   characters just before decide as they would in the whole span: `xhttps://…` and
///   `1https://…` have no URL, but `あ1https://…` does. Past a run of more than 64 such
///   characters, the window may decide otherwise.
/// - It ends 128 UTF-16 units after the scheme's start, and the distance doubles while the
///   URL may go on past the window, so a long URL is not cut short:
///   - The link the detector found at the scheme ends within 16 units of the window's end,
///     with no whitespace between.
///   - The text from the end of that link, or of the scheme when there is none, to the
///     window's end is printable ASCII a URL may hold: no space, `"`, `<` or `>`. Where a
///     window cuts a URL, the detector may end it tens of units before the cut, at a `.`
///     for example.
///   - Up to 1,024 units after the scheme: the text from the scheme to the window's end has
///     no whitespace and leaves a `(`, `[` or `{` open whose closing bracket comes later.
///     The detector ends a link before, or finds none around, an opening bracket it cannot
///     see closed, as in `https://en.wikipedia.org/wiki/Foo_(bar)` cut inside the
///     parentheses.
/// - It stops growing at 2,048 units, or once it holds two more `http://` or `https://`
///   after that link, so few windows that grow overlap. This bounds the text a keystroke
///   gives the detector, not its time: after an open bracket, the detector takes about
///   15 ms on a 2,048-unit window of Japanese, so such a line may take longer than 16 ms.
/// - It stays within the span, and never ends or starts inside a surrogate pair.
///
/// The link found at the scheme is the one in the last window covering it, or else one
/// starting within or right after `http://` or `https://`. It is a URL when it starts at the
/// scheme, outside the links found at the schemes before, and the last window leaves it
/// whole. It is left cut when it ends within 16 units of the window's end with no whitespace
/// between, or when the window has grown to 2,048 units and ends in printable ASCII a URL may
/// hold that runs from the link's end. A cut link is no URL, so a URL longer than 2,048 units
/// has no token, and it covers the printable ASCII a URL may hold right after it. Where the
/// detector ends a URL tens of units before the window's end, with text other than ASCII
/// after it, the token holds only that part, as in `…/abc.日本語/…` past the first window. One
/// that starts earlier and covers the scheme is not a URL either, and its window does not
/// grow. Every scheme has a window, which depends only on the text around it, so an edit
/// changes only the windows that hold it.
///
/// Results are cached by window text, so after a keystroke the detector runs only for the
/// windows around it. The cache holds two generations of windows of at most
/// `generationCapacity` UTF-16 units in all each; when the newer one fills, the older is
/// dropped and a new one starts. A window larger than a generation is not cached.
final class URLDetector: @unchecked Sendable {
    let generationCapacity: Int
    private let lock = NSLock()
    /// Windows by their UTF-16 units, which hash faster than strings.
    private var current: [[UInt16]: [Range<Int>]] = [:]
    private var previous: [[UInt16]: [Range<Int>]] = [:]
    private var currentUnits = 0
    private var previousUnits = 0
    private var detectionCount = 0

    /// 524,288 units, 1 MB, hold about 3,500 windows of a URL in Japanese text each.
    init(generationCapacity: Int = 524_288) {
        self.generationCapacity = generationCapacity
    }

    /// How many times the detector ran, for tests.
    var detections: Int {
        lock.lock(); defer { lock.unlock() }
        return detectionCount
    }

    /// The UTF-16 units of the windows cached, for tests.
    var cachedUnits: Int {
        lock.lock(); defer { lock.unlock() }
        return currentUnits + previousUnits
    }

    /// The URLs in `span` of `units`, a span of plain text within one line, in order.
    func urls(in units: [UInt16], _ span: Range<Int>) -> [Range<Int>] {
        var urls: [Range<Int>] = []
        // The end of the links found so far that cover their scheme.
        var covered = span.lowerBound
        for index in span {
            guard let scheme = httpSchemeLength(units, at: index, before: span.upperBound) else { continue }
            let (found, cut) = link(at: index, scheme: scheme, in: units, span)
            guard let found, found.lowerBound <= index, index >= covered else { continue }
            // A link its window may still cut is no URL, and also covers the printable ASCII a
            // URL may hold right after it.
            if found.lowerBound == index, !cut { urls.append(found) }
            covered = cut
                ? units[found.upperBound..<span.upperBound].firstIndex { !mayContinueURL($0) } ?? span.upperBound
                : found.upperBound
        }
        return urls
    }

    /// The link the detector finds at the scheme starting at `start`, `scheme` units long, in
    /// its window, and whether the window may cut it.
    private func link(at start: Int, scheme: Int, in units: [UInt16], _ span: Range<Int>) -> (Range<Int>?, cut: Bool) {
        var lower = start
        while lower > span.lowerBound, start - lower < 64, isVisibleASCII(units[lower - 1]) { lower -= 1 }
        lower = max(span.lowerBound, lower - 8)
        if lower > span.lowerBound, UTF16.isTrailSurrogate(units[lower]) { lower -= 1 }
        var distance = 128
        while true {
            var end = min(span.upperBound, start + distance)
            if end < span.upperBound, UTF16.isTrailSurrogate(units[end]) { end += 1 }
            let links = detect(units, lower..<end)
            let found = links.first { $0.contains(start) }
                ?? links.first { (start...(start + scheme)).contains($0.lowerBound) }
            let cut = found.map { cuts($0, at: end, in: units, span) } ?? false
            // A link starting before the scheme is no URL however far it goes.
            if let found, found.lowerBound < start { return (found, cut) }
            let tail = found?.upperBound ?? start + scheme
            let goesOn = end < span.upperBound
                && (cut || continuesInASCII(units, tail..<end)
                    || closesAfter(units, from: start + scheme, window: end, before: min(span.upperBound, start + 1024)))
            // A window holding two more schemes after the link stops growing, so few windows
            // that grow overlap.
            if goesOn, end - start < 2048, schemes(in: units, tail..<end) < 2 {
                distance *= 2
                continue
            }
            // A URL that may go on past the largest window is not seen whole.
            return (found, cut || goesOn && end - start >= 2048)
        }
    }

    /// Whether a window ending at `end` may cut `link`: the link ends within 16 units of the
    /// window's end, with no whitespace between.
    private func cuts(_ link: Range<Int>, at end: Int, in units: [UInt16], _ span: Range<Int>) -> Bool {
        end < span.upperBound && link.upperBound + 16 > end
            && !units[link.upperBound..<end].contains(where: isWhitespace)
    }

    /// Whether `range` is printable ASCII a URL may hold, so a URL cut before it may go on.
    private func continuesInASCII(_ units: [UInt16], _ range: Range<Int>) -> Bool {
        range.allSatisfy { mayContinueURL(units[$0]) }
    }

    /// How many `http://` or `https://` start in `range`.
    private func schemes(in units: [UInt16], _ range: Range<Int>) -> Int {
        range.count { httpSchemeLength(units, at: $0, before: range.upperBound) != nil }
    }

    /// Whether the text from `start` to `window` has no whitespace and leaves a bracket open
    /// that a closing bracket at or after `window` and before `limit` closes.
    private func closesAfter(_ units: [UInt16], from start: Int, window: Int, before limit: Int) -> Bool {
        guard window < limit else { return false }
        var depths = Array(repeating: 0, count: brackets.count)
        for index in start..<window {
            let unit = units[index]
            if isWhitespace(unit) { return false }
            for (kind, bracket) in brackets.enumerated() {
                if unit == bracket.open { depths[kind] += 1 } else if unit == bracket.close, depths[kind] > 0 { depths[kind] -= 1 }
            }
        }
        for (kind, bracket) in brackets.enumerated() where depths[kind] > 0 {
            // The depth of the brackets opened after `window`.
            var depth = 0
            for index in window..<limit {
                if units[index] == bracket.open { depth += 1 } else if units[index] == bracket.close {
                    if depth == 0 { return true }
                    depth -= 1
                }
            }
        }
        return false
    }

    /// The links the detector finds in `window`, from the cache when it has them.
    private func detect(_ units: [UInt16], _ window: Range<Int>) -> [Range<Int>] {
        let key = Array(units[window])
        let offset = window.lowerBound
        if let links = cached(key) { return links.map { ($0.lowerBound + offset)..<($0.upperBound + offset) } }
        let text = String(decoding: key, as: UTF16.self)
        let links = linkDetector.matches(in: text, range: NSRange(location: 0, length: window.count)).map {
            $0.range.location..<($0.range.location + $0.range.length)
        }
        store(key, links)
        return links.map { ($0.lowerBound + offset)..<($0.upperBound + offset) }
    }

    private func cached(_ key: [UInt16]) -> [Range<Int>]? {
        lock.lock(); defer { lock.unlock() }
        if let links = current[key] { return links }
        guard let links = previous.removeValue(forKey: key) else { return nil }
        previousUnits -= key.count
        insert(key, links)
        return links
    }

    private func store(_ key: [UInt16], _ links: [Range<Int>]) {
        lock.lock(); defer { lock.unlock() }
        detectionCount += 1
        insert(key, links)
    }

    /// Call with the lock held. A window larger than a generation is not kept.
    private func insert(_ key: [UInt16], _ links: [Range<Int>]) {
        guard key.count <= generationCapacity else { return }
        if currentUnits + key.count > generationCapacity, !current.isEmpty {
            previous = current
            previousUnits = currentUnits
            current = [:]
            currentUnits = 0
        }
        // Two callers may detect the same window at once.
        if current.updateValue(links, forKey: key) == nil { currentUnits += key.count }
    }
}
