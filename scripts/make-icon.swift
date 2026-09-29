#!/usr/bin/env swift
// 앱 아이콘 (믹서 페이더 3개) 을 그려서 Tapmix/Assets.xcassets/AppIcon.appiconset 에 PNG 로 쓴다.
//
//   swift scripts/make-icon.swift
//
// macOS 아이콘 그리드: 1024 캔버스 안에 824x824 둥근 사각형, 모서리 반경 ~185.
import AppKit

let outputDir = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "Tapmix/Assets.xcassets/AppIcon.appiconset")

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

func drawIcon(in ctx: CGContext) {
    let canvas: CGFloat = 1024
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // 그림자
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
    ctx.addPath(tilePath)
    ctx.setFillColor(color(0x1B1F3B))
    ctx.fillPath()
    ctx.restoreGState()

    // 배경 그라데이션 (위: 남보라, 아래: 짙은 남색)
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let background = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: [color(0x3A3F8F), color(0x151833)] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(background, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])

    // 위쪽 은은한 하이라이트
    let shine = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: [color(0xFFFFFF, 0.14), color(0xFFFFFF, 0)] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(shine, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.midY), options: [])
    ctx.restoreGState()

    // 페이더 3개: 트랙 + 채워진 부분 + 노브
    let trackTop: CGFloat = 770
    let trackBottom: CGFloat = 254
    let trackWidth: CGFloat = 34
    let knobSize = CGSize(width: 150, height: 74)
    let faders: [(x: CGFloat, level: CGFloat, fill: UInt32)] = [
        (canvas / 2 - 210, 0.62, 0x5AC8FA),
        (canvas / 2,       0.30, 0x30D5C8),
        (canvas / 2 + 210, 0.82, 0x7D7AFF),
    ]

    for fader in faders {
        let track = CGRect(x: fader.x - trackWidth / 2, y: trackBottom, width: trackWidth, height: trackTop - trackBottom)
        ctx.addPath(CGPath(roundedRect: track, cornerWidth: trackWidth / 2, cornerHeight: trackWidth / 2, transform: nil))
        ctx.setFillColor(color(0x000000, 0.35))
        ctx.fillPath()

        let knobY = trackBottom + (trackTop - trackBottom) * fader.level
        let filled = CGRect(x: track.minX, y: trackBottom, width: trackWidth, height: knobY - trackBottom)
        ctx.addPath(CGPath(roundedRect: filled, cornerWidth: trackWidth / 2, cornerHeight: trackWidth / 2, transform: nil))
        ctx.setFillColor(color(fader.fill))
        ctx.fillPath()

        let knob = CGRect(
            x: fader.x - knobSize.width / 2, y: knobY - knobSize.height / 2,
            width: knobSize.width, height: knobSize.height
        )
        let knobPath = CGPath(roundedRect: knob, cornerWidth: 22, cornerHeight: 22, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: color(0x000000, 0.45))
        ctx.addPath(knobPath)
        ctx.setFillColor(color(0xF4F5FA))
        ctx.fillPath()
        ctx.restoreGState()

        // 노브 가운데 홈
        let groove = CGRect(x: knob.minX + 26, y: knob.midY - 5, width: knob.width - 52, height: 10)
        ctx.addPath(CGPath(roundedRect: groove, cornerWidth: 5, cornerHeight: 5, transform: nil))
        ctx.setFillColor(color(0x9AA0B8))
        ctx.fillPath()
    }
}

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    ctx.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    ctx.interpolationQuality = .high
    drawIcon(in: ctx)
    return rep.representation(using: .png, properties: [:])!
}

try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let filename = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try render(pixels: pixels).write(to: outputDir.appendingPathComponent(filename))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": filename])
    }
}

let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: outputDir.appendingPathComponent("Contents.json"))

let catalog = outputDir.deletingLastPathComponent().appendingPathComponent("Contents.json")
if !FileManager.default.fileExists(atPath: catalog.path) {
    try #"{"info":{"author":"xcode","version":1}}"#.data(using: .utf8)!.write(to: catalog)
}
print("wrote \(images.count) icons to \(outputDir.path)")
