#!/usr/bin/env swift
// Renders the Co/Pad Server macOS app icon: the light Co/Pad mark inside a
// macOS-style squircle (824pt on a 1024 canvas, transparent margins, soft
// drop shadow). Then build the .icns with:
//   swift make-icon.swift && iconutil -c icns AppIcon.iconset -o AppIcon.icns

import AppKit

let S: CGFloat = 1024

func c(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

// light palette, matching CoPad/Assets AppIcon icon-1024.png
let bgTop = c(0xF5B57E), bgBottom = c(0xE58A47)
let keyTop = c(0xF3EFE6), keyBottom = c(0xEDE7DA)
let keyBorder = c(0xC9C0AE)
let chipBg = c(0xE3DCCB), ink = c(0x6E6455)
let slashTop = c(0xF08A4B), slashBottom = c(0xE06A2F)
let slashShadow = c(0x8F3D12)

func renderMaster() -> NSImage {
    let img = NSImage(size: NSSize(width: S, height: S))
    img.lockFocusFlipped(true)
    let ctx = NSGraphicsContext.current!.cgContext

    // macOS squircle plate, 824pt centered, with drop shadow
    let plateRect = NSRect(x: 100, y: 100, width: 824, height: 824)
    let plateR: CGFloat = 824 * 0.225
    let plate = NSBezierPath(roundedRect: plateRect, xRadius: plateR, yRadius: plateR)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12),
                  blur: 24, color: NSColor.black.withAlphaComponent(0.30).cgColor)
    bgBottom.setFill(); plate.fill()
    ctx.restoreGState()

    // clip everything that follows to the plate
    plate.addClip()
    NSGradient(colors: [bgTop, bgBottom])!.draw(in: plateRect, angle: -60)

    // embossed cream key (scaled from the 1024 full-bleed design into the plate)
    let k = plateRect.width / S
    let keyRect = NSRect(x: plateRect.minX + 165 * k, y: plateRect.minY + 165 * k,
                         width: 694 * k, height: 694 * k)
    let keyR = keyRect.width * 0.27
    let key = NSBezierPath(roundedRect: keyRect, xRadius: keyR, yRadius: keyR)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -17 * k),
                  blur: 28 * k, color: NSColor.black.withAlphaComponent(0.28).cgColor)
    keyBottom.setFill(); key.fill()
    ctx.restoreGState()

    ctx.saveGState()
    key.addClip()
    NSGradient(colors: [keyTop, keyBottom])!.draw(in: keyRect, angle: -90)
    let sheen = NSGradient(colors: [.clear, NSColor.white.withAlphaComponent(0.35)])!
    sheen.draw(in: NSRect(x: keyRect.minX, y: keyRect.minY,
                          width: keyRect.width, height: 320 * k), angle: -90)
    ctx.restoreGState()

    keyBorder.withAlphaComponent(0.6).setStroke()
    key.lineWidth = 1.5; key.stroke()

    // chip "co/"
    let chipRect = NSRect(x: keyRect.minX + 76 * k, y: keyRect.minY + 67 * k,
                          width: 190 * k, height: 105 * k)
    let chip = NSBezierPath(roundedRect: chipRect, xRadius: 35 * k, yRadius: 35 * k)
    chipBg.setFill(); chip.fill()
    let font = NSFont.monospacedSystemFont(ofSize: 59 * k, weight: .bold)
    NSAttributedString(string: "co/", attributes: [
        .font: font, .foregroundColor: ink, .kern: 5.5 * k,
    ]).draw(at: NSPoint(x: chipRect.minX + 33 * k, y: chipRect.minY + 20 * k))

    // active dot
    let dotPath = NSBezierPath(ovalIn: NSRect(x: keyRect.minX + 583 * k,
                                              y: keyRect.minY + 67 * k,
                                              width: 48 * k, height: 48 * k))
    NSGradient(colors: [slashTop, slashBottom])!.draw(in: dotPath, angle: -90)

    // orange slash
    ctx.saveGState()
    ctx.translateBy(x: plateRect.midX, y: plateRect.midY)
    ctx.rotate(by: 22 * .pi / 180)
    let slashRect = NSRect(x: -55.5 * k, y: -208 * k, width: 111 * k, height: 416 * k)
    let slash = NSBezierPath(roundedRect: slashRect, xRadius: 35 * k, yRadius: 35 * k)
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * k),
                  blur: 21 * k, color: slashShadow.withAlphaComponent(0.4).cgColor)
    slashBottom.setFill(); slash.fill()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    NSGradient(colors: [slashTop, slashBottom])!.draw(in: slash, angle: -90)
    ctx.restoreGState()

    img.unlockFocus()
    return img
}

func write(_ img: NSImage, size: Int, to path: String) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .calibratedRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    img.draw(in: NSRect(x: 0, y: 0, width: size, height: size),
             from: NSRect(x: 0, y: 0, width: S, height: S),
             operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
}

let master = renderMaster()
let dir = "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
for (name, px) in [("icon_16x16", 16), ("icon_16x16@2x", 32),
                   ("icon_32x32", 32), ("icon_32x32@2x", 64),
                   ("icon_128x128", 128), ("icon_128x128@2x", 256),
                   ("icon_256x256", 256), ("icon_256x256@2x", 512),
                   ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
    write(master, size: px, to: "\(dir)/\(name).png")
}
