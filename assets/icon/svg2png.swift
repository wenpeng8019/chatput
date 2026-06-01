#!/usr/bin/env swift
//
// svg2png.swift — 用 AppKit 把 SVG 栅格化为带透明通道的 PNG（macOS 13+）。
// 用法： swift svg2png.swift <input.svg> <size> <output.png>
//
import AppKit
import Foundation

let args = CommandLine.arguments
guard args.count == 4, let size = Int(args[2]) else {
    FileHandle.standardError.write("用法: svg2png.swift <input.svg> <size> <output.png>\n".data(using: .utf8)!)
    exit(2)
}
let inPath = args[1]
let outPath = args[3]

guard let img = NSImage(contentsOfFile: inPath) else {
    FileHandle.standardError.write("✗ 无法加载 SVG: \(inPath)\n".data(using: .utf8)!)
    exit(1)
}

let px = size
guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: px, pixelsHigh: px,
    bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0
) else {
    FileHandle.standardError.write("✗ 无法创建位图\n".data(using: .utf8)!)
    exit(1)
}
rep.size = NSSize(width: px, height: px)

NSGraphicsContext.saveGraphicsState()
let ctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = ctx
ctx.imageInterpolation = .high
// 透明背景
NSColor.clear.set()
NSRect(x: 0, y: 0, width: px, height: px).fill()
img.draw(in: NSRect(x: 0, y: 0, width: px, height: px),
         from: .zero, operation: .sourceOver, fraction: 1.0)
ctx.flushGraphics()
NSGraphicsContext.restoreGraphicsState()

guard let data = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("✗ 无法编码 PNG\n".data(using: .utf8)!)
    exit(1)
}
try data.write(to: URL(fileURLWithPath: outPath))
