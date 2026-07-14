#!/usr/bin/env swift
// Regenerates every PNG in AppIcon.appiconset from the 1024x1024 master.
//
// Usage:
//   swift scripts/generate_app_icons.swift [master.png] [appiconset-dir]
//
// Defaults (run from the repo root):
//   master        = PixelCurator/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png
//   appiconset    = PixelCurator/Assets.xcassets/AppIcon.appiconset
//
// iOS uses the square full-bleed master as-is (must be 1024x1024, no alpha).
// macOS gets the HIG icon treatment: artwork scaled into an 824x824 rounded
// rect centered on a transparent 1024 canvas with a soft drop shadow, then
// rendered at 16/32/64/128/256/512/1024.

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("error: " + message + "\n").utf8))
    exit(1)
}

func loadImage(_ url: URL) -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        fail("cannot read image at \(url.path)")
    }
    return image
}

func savePNG(_ image: CGImage, to url: URL) {
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fail("cannot create PNG destination at \(url.path)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        fail("cannot write PNG at \(url.path)")
    }
}

func makeContext(size: Int) -> CGContext {
    guard let context = CGContext(
        data: nil, width: size, height: size,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fail("cannot create \(size)x\(size) context")
    }
    context.interpolationQuality = .high
    return context
}

// macOS HIG icon grid: 824x824 icon body centered on a 1024 canvas,
// corner radius ~185, soft downward shadow.
func composeMacMaster(from master: CGImage) -> CGImage {
    let canvas = 1024
    let context = makeContext(size: canvas)
    let iconRect = CGRect(x: 100, y: 100, width: 824, height: 824)
    let path = CGPath(roundedRect: iconRect, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // Shadow pass: fill the silhouette so the shadow is cast once.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 24,
                      color: CGColor(gray: 0, alpha: 0.3))
    context.addPath(path)
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    context.fillPath()
    context.restoreGState()

    // Artwork pass: clip to the same rounded rect and draw the master.
    context.saveGState()
    context.addPath(path)
    context.clip()
    context.draw(master, in: iconRect)
    context.restoreGState()

    guard let image = context.makeImage() else { fail("cannot render mac master") }
    return image
}

func resized(_ image: CGImage, to size: Int) -> CGImage {
    let context = makeContext(size: size)
    context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    guard let result = context.makeImage() else { fail("cannot resize to \(size)") }
    return result
}

let arguments = CommandLine.arguments
let masterPath = arguments.count > 1 ? arguments[1]
    : "PixelCurator/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"
let appIconSetPath = arguments.count > 2 ? arguments[2]
    : "PixelCurator/Assets.xcassets/AppIcon.appiconset"

let masterURL = URL(fileURLWithPath: masterPath)
let appIconSetURL = URL(fileURLWithPath: appIconSetPath, isDirectory: true)

let master = loadImage(masterURL)
guard master.width == 1024, master.height == 1024 else {
    fail("master must be 1024x1024, got \(master.width)x\(master.height)")
}
guard master.alphaInfo == .none || master.alphaInfo == .noneSkipLast
        || master.alphaInfo == .noneSkipFirst else {
    fail("master must not have an alpha channel (App Store requirement for the iOS icon)")
}

// iOS: square full-bleed master.
let iosURL = appIconSetURL.appendingPathComponent("AppIcon-1024.png")
if masterURL.standardizedFileURL != iosURL.standardizedFileURL {
    savePNG(master, to: iosURL)
}

// macOS: rounded-rect treatment, then the full size ladder.
let macMaster = composeMacMaster(from: master)
for size in [16, 32, 64, 128, 256, 512, 1024] {
    let url = appIconSetURL.appendingPathComponent("AppIcon-mac-\(size).png")
    savePNG(size == 1024 ? macMaster : resized(macMaster, to: size), to: url)
    print("wrote \(url.lastPathComponent)")
}
print("done")
