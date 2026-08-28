// アプリアイコンを描いて PNG に書き出す。
//
//   swift Tools/icon.swift <出力先.png> [dev]
//
// 図柄はエディ太郎 (https://editaro.com) のアイコンに倣い、グラデーションの枠と
// 暗い画面にキャレットを置く。色は Ediro の既定テーマ dark-grad に合わせている。
import AppKit
import Foundation

let size = 1024.0

func rgb(_ hex: UInt32) -> NSColor {
  NSColor(
    srgbRed: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
    blue: Double(hex & 0xFF) / 255, alpha: 1)
}

// 開発用ビルドは色を変える。Dock や撮影結果で日常使いのものと取り違えないため。
let isDevelopment = CommandLine.arguments.count > 2 && CommandLine.arguments[2] == "dev"
let gradient =
  isDevelopment
  ? NSGradient(colors: [rgb(0xFF7A00), rgb(0xFFB020), rgb(0xFFD966)])!
  : NSGradient(colors: [rgb(0x5433FF), rgb(0x00ABFF), rgb(0x30D9EF)])!
let screenColor = rgb(0x1E1E1E)
let caretColor = NSColor.white
let lineColor = isDevelopment ? rgb(0xFFB020) : rgb(0x00ABFF)

let rep = NSBitmapImageRep(
  bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
  samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
  bytesPerRow: 0, bitsPerPixel: 0)!

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// グラデーションは全面に敷く。余白も角丸も持たせない。
// macOS は角丸マスクを自前でかけるため、内側に収めると背景タイルが足されて
// 四角が二重に見える。
let canvas = NSRect(x: 0, y: 0, width: size, height: size)
gradient.draw(in: NSBezierPath(rect: canvas), angle: 60)

// macOS がアートワークに被せるマスクの実測値。1024 のキャンバスに対し、
// 表示される形は一辺の 80.5%、その角丸半径は一辺の 37.1%、角では対角に
// 一辺の 10.8% が削られる。
let maskCornerRadius = size * 0.371
let maskCornerBite = size * 0.108

// 枠の太さは、角で削り取られる量に合わせる。
let inset = maskCornerBite
let screen = canvas.insetBy(dx: inset, dy: inset)
screenColor.setFill()
// 内側の角丸は外側と同心にする。こうすると枠の太さが辺でも角でも一定になる。
// 外側の半径は、角の削れ量から円弧相当に逆算した値を使う。実測した 37.1% は
// スクワークルの見かけの広がりで、円弧の半径として使うと丸くなりすぎる。
let outerRadius = maskCornerBite / (2.0.squareRoot() - 1)
let screenRadius = outerRadius - inset
NSBezierPath(roundedRect: screen, xRadius: screenRadius, yRadius: screenRadius).fill()

/// 画面の左上を原点とした割合で矩形を置く。
func place(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> NSRect {
  NSRect(
    x: screen.minX + screen.width * x, y: screen.maxY - screen.height * (y + height),
    width: screen.width * width, height: screen.height * height)
}

caretColor.setFill()
NSBezierPath(rect: place(0.14, 0.12, 0.085, 0.32)).fill()

lineColor.setFill()
let line = place(0.14, 0.62, 0.42, 0.055)
NSBezierPath(roundedRect: line, xRadius: line.height / 2, yRadius: line.height / 2).fill()

NSGraphicsContext.restoreGraphicsState()

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
guard let png = rep.representation(using: .png, properties: [:]) else {
  FileHandle.standardError.write("PNG に変換できませんでした\n".data(using: .utf8)!)
  exit(1)
}
try png.write(to: URL(filePath: output))
print("wrote \(output)")
