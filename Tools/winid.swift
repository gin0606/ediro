// 指定したアプリのウィンドウ ID を出力する。
//
//   swift Tools/winid.swift Ediro
//
// アプリはメニューバーや画面外の内部ウィンドウも所有しているため、
// 表示中 (onscreen) のレイヤ 0 に限ったうえで最大面積のものを選ぶ。
import CoreGraphics
import Foundation

guard CommandLine.arguments.count > 1 else {
  FileHandle.standardError.write("usage: winid.swift <アプリ名>\n".data(using: .utf8)!)
  exit(2)
}
let wanted = CommandLine.arguments[1]

guard let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]
else {
  FileHandle.standardError.write("ウィンドウ一覧を取得できませんでした\n".data(using: .utf8)!)
  exit(1)
}

struct Candidate {
  let id: Int
  let area: CGFloat
}

var best: Candidate?
for window in windows {
  guard let owner = window[kCGWindowOwnerName as String] as? String, owner == wanted,
    let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
    let onscreen = window[kCGWindowIsOnscreen as String] as? Bool, onscreen,
    let id = window[kCGWindowNumber as String] as? Int,
    let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
    let width = bounds["Width"], let height = bounds["Height"]
  else { continue }

  let area = width * height
  if area > (best?.area ?? 0) {
    best = Candidate(id: id, area: area)
  }
}

guard let best else {
  FileHandle.standardError.write("\(wanted) のウィンドウが見つかりません\n".data(using: .utf8)!)
  exit(1)
}
print(best.id)
