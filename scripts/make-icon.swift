// 从 logo 源图生成 macOS 应用图标：
//   swift scripts/make-icon.swift Resources/AppIcon-source.png Resources/AppIcon.icns [预览.png]
//
// 源图是白底上的圆角方块（没有透明通道）。脚本会自动找到方块的边界和圆角半径，
// 裁出来后按 macOS 图标规格重新绘制：1024 画布、824 主体、透明四角、底部投影。
import AppKit

let arguments = CommandLine.arguments.dropFirst()
guard arguments.count >= 2 else {
    print("用法：swift scripts/make-icon.swift <源图.png> <输出.icns> [预览.png]")
    exit(1)
}
let sourceURL = URL(fileURLWithPath: arguments[arguments.startIndex])
let outputPath = arguments[arguments.startIndex + 1]
let previewPath = arguments.count >= 3 ? arguments[arguments.startIndex + 2] : nil

guard let sourceData = try? Data(contentsOf: sourceURL),
      let source = NSBitmapImageRep(data: sourceData),
      let sourceImage = source.cgImage
else {
    print("读不了源图：\(sourceURL.path)")
    exit(1)
}

// MARK: - 找圆角方块

let width = source.pixelsWide
let height = source.pixelsHigh

func luminance(_ x: Int, _ y: Int) -> Double {
    guard let color = source.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return 1 }
    return color.redComponent * 0.299 + color.greenComponent * 0.587 + color.blueComponent * 0.114
}

/// 背景是接近纯白的，方块内部和阴影略灰
let background = luminance(2, 2)
func isBackground(_ x: Int, _ y: Int) -> Bool { luminance(x, y) > background - 0.012 }

func firstEdge(_ positions: StrideTo<Int>, _ point: (Int) -> (Int, Int)) -> Int {
    for position in positions {
        let (x, y) = point(position)
        if !isBackground(x, y) { return position }
    }
    return positions.first { _ in true } ?? 0
}

let left = firstEdge(stride(from: 0, to: width / 2, by: 1)) { ($0, height / 2) }
let right = firstEdge(stride(from: width - 1, to: width / 2, by: -1)) { ($0, height / 2) }
let top = firstEdge(stride(from: 0, to: height / 2, by: 1)) { (width / 2, $0) }
let bottom = firstEdge(stride(from: height - 1, to: height / 2, by: -1)) { (width / 2, $0) }

// 沿左上角对角线找圆角弧线，反推圆角半径：弧线在对角线上的点距角点 r·(1 − 1/√2)
let diagonal = firstEdge(stride(from: 0, to: min(width, height) / 2, by: 1)) { (left + $0, top + $0) }
let measuredRadius = Double(diagonal) / (1 - 1 / 2.0.squareRoot())

// 方块可能不是严格正方形：取居中的正方形，内缩几个像素避开边缘的阴影
let side = min(right - left, bottom - top)
let inset = Int(Double(side) * 0.006)
let cropSide = side - inset * 2
let cropX = (left + right) / 2 - cropSide / 2
let cropY = (top + bottom) / 2 - cropSide / 2
let radiusRatio = max(0.225, (measuredRadius - Double(inset)) / Double(cropSide))
print("方块：x \(left)–\(right)，y \(top)–\(bottom)；圆角半径约 \(Int(measuredRadius))px（\(Int(radiusRatio * 100))%）")

guard let cropped = sourceImage.cropping(to: CGRect(x: cropX, y: cropY, width: cropSide, height: cropSide)) else {
    print("裁剪失败")
    exit(1)
}

// MARK: - 绘制

func render(_ size: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    let cg = context.cgContext

    let scale = CGFloat(size) / 1024
    // macOS 图标网格：主体 824×824，居中略偏上，下方留投影空间
    let body = CGRect(x: 100 * scale, y: 112 * scale, width: 824 * scale, height: 824 * scale)
    let radius = body.width * radiusRatio
    let path = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -10 * scale), blur: 20 * scale, color: NSColor.black.withAlphaComponent(0.28).cgColor)
    cg.addPath(path)
    cg.setFillColor(NSColor.white.cgColor)
    cg.fillPath()
    cg.restoreGState()

    cg.saveGState()
    cg.addPath(path)
    cg.clip()
    cg.draw(cropped, in: body)
    cg.restoreGState()

    // 细描边让白色图标在浅色背景上也有轮廓
    cg.addPath(path)
    cg.setStrokeColor(NSColor.black.withAlphaComponent(0.08).cgColor)
    cg.setLineWidth(max(1, 2 * scale))
    cg.strokePath()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }
for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
if let previewPath {
    try render(1024).write(to: URL(fileURLWithPath: previewPath))
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", outputPath]
try process.run()
process.waitUntilExit()
print(process.terminationStatus == 0 ? "已生成 \(outputPath)" : "iconutil 失败")
exit(process.terminationStatus)
