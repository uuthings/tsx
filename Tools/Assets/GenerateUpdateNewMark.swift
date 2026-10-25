#!/usr/bin/env -S swift -swift-version 6
import AppKit
import CoreText
import CryptoKit
import Foundation

// Rebuild the three-letter outline without bundling or registering a runtime font.
// The fixed upstream font is cached only under the ignored .build directory.
let root = URL(fileURLWithPath: #filePath).standardizedFileURL
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.isEmpty || (arguments.count == 2 && arguments[0] == "--preview") else {
    fatalError("Usage: GenerateUpdateNewMark.swift [--preview PATH]")
}
let revision = "aeb9574d3cb4ab2ac5de70a8c730b11662281803"
let fontSHA256 = "0f173b3e6cb6d1af25babf7f0057c5ac4ee11f9992b0469bb817e967ef4ad0fc"
let source = "https://raw.githubusercontent.com/google/fonts/\(revision)/ofl/patrickhand/PatrickHand-Regular.ttf"
let cache = root.appending(path: ".build/AssetSources/PatrickHand")
try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
let fontURL = cache.appending(path: "PatrickHand-Regular.ttf")
if !FileManager.default.fileExists(atPath: fontURL.path) {
    let download = Process()
    download.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    download.arguments = ["--fail", "--location", "--silent", "--show-error", source, "--output", fontURL.path]
    try download.run()
    download.waitUntilExit()
    guard download.terminationStatus == 0 else { fatalError("Font download failed") }
}
let data = try Data(contentsOf: fontURL)
guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == fontSHA256 else {
    fatalError("Patrick Hand source checksum mismatch")
}
guard let provider = CGDataProvider(data: data as CFData), let cgFont = CGFont(provider) else {
    fatalError("Cannot load Patrick Hand source")
}
let font = CTFontCreateWithGraphicsFont(cgFont, 12.5, nil, nil)
let text = NSAttributedString(string: "New", attributes: [
    NSAttributedString.Key(kCTFontAttributeName as String): font,
    NSAttributedString.Key(kCTKernAttributeName as String): -0.1
])
let line = CTLineCreateWithAttributedString(text)
let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
let originX = (28 - width) / 2
// Match a centered 12.5 pt line box with a half-point optical lift.
let baseline = 7 + (CTFontGetAscent(font) - CTFontGetDescent(font)) / 2
let outline = CGMutablePath()
for run in CTLineGetGlyphRuns(line) as! [CTRun] {
    let count = CTRunGetGlyphCount(run)
    var glyphs = [CGGlyph](repeating: 0, count: count)
    var positions = [CGPoint](repeating: .zero, count: count)
    CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
    CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
    for index in 0..<count {
        guard let path = CTFontCreatePathForGlyph(font, glyphs[index], nil) else {
            fatalError("Missing New letter outline")
        }
        let transform = CGAffineTransform(a: 1, b: 0, c: 0, d: -1,
                                          tx: originX + positions[index].x, ty: baseline - positions[index].y)
        outline.addPath(path, transform: transform)
    }
}
func number(_ value: CGFloat) -> String {
    String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), Double(value))
}
func point(_ value: CGPoint) -> String { "\(number(value.x)) \(number(value.y))" }
var commands: [String] = []
outline.applyWithBlock { pointer in
    let element = pointer.pointee
    switch element.type {
    case .moveToPoint: commands.append("M\(point(element.points[0]))")
    case .addLineToPoint: commands.append("L\(point(element.points[0]))")
    case .addQuadCurveToPoint: commands.append("Q\(point(element.points[0])) \(point(element.points[1]))")
    case .addCurveToPoint: commands.append("C\(point(element.points[0])) \(point(element.points[1])) \(point(element.points[2]))")
    case .closeSubpath: commands.append("Z")
    @unknown default: fatalError("Unsupported outline element")
    }
}
let output = root.appending(path: "TranslateX/Resources/Assets.xcassets/UpdateNewMark.imageset")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let svg = """
<svg xmlns="http://www.w3.org/2000/svg" width="28" height="15" viewBox="0 0 28 15">
  <!-- Patrick Hand Regular; fixed source and SIL OFL 1.1 in UpdateNewMarkNotices.txt. -->
  <path fill="#000000" d="\(commands.joined(separator: " "))"/>
</svg>

"""
try svg.write(to: output.appending(path: "UpdateNewMark.svg"), atomically: true, encoding: .utf8)
if !arguments.isEmpty {
    let scale: CGFloat = 8
    guard let context = CGContext(data: nil, width: 224, height: 120, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fatalError("Cannot create outline preview")
    }
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 224, height: 120))
    context.translateBy(x: 0, y: 120)
    context.scaleBy(x: scale, y: -scale)
    context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    context.addPath(outline)
    context.fillPath()
    guard let image = context.makeImage(),
          let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
        fatalError("Cannot encode outline preview")
    }
    let preview = URL(fileURLWithPath: arguments[1])
    try FileManager.default.createDirectory(at: preview.deletingLastPathComponent(), withIntermediateDirectories: true)
    try png.write(to: preview, options: .atomic)
}
print("Exported New outlines on a 28 × 15 pt template canvas")
