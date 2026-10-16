import AppKit
import Foundation
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1280, pixelsHigh: 640, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
let context = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
NSGradient(starting: NSColor(calibratedRed: 0.08, green: 0.06, blue: 0.14, alpha: 1), ending: NSColor(calibratedRed: 0.18, green: 0.11, blue: 0.27, alpha: 1))!.draw(in: NSRect(x: 0, y: 0, width: 1280, height: 640), angle: 20)
let logo = NSImage(contentsOf: root.appendingPathComponent("Resources/Mufus.png"))!
logo.draw(in: NSRect(x: 80, y: 120, width: 390, height: 390))
func text(_ value: String, at point: NSPoint, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
    (value as NSString).draw(at: point, withAttributes: [.font:NSFont.systemFont(ofSize:size,weight:weight), .foregroundColor:color])
}
text("Mufus", at: NSPoint(x: 530, y: 355), size: 94, weight: .bold, color: .white)
text("Native USB creation", at: NSPoint(x: 536, y: 285), size: 38, weight: .medium, color: .white)
text("for macOS", at: NSPoint(x: 536, y: 230), size: 38, weight: .medium, color: .white)
text("APPLE SILICON + INTEL", at: NSPoint(x: 538, y: 160), size: 22, weight: .semibold, color: NSColor(calibratedRed: 0.75, green: 0.62, blue: 0.94, alpha: 1))
text("Linux images  /  Windows UEFI  /  USB formatting", at: NSPoint(x: 85, y: 48), size: 24, weight: .regular, color: NSColor.white.withAlphaComponent(0.65))
NSGraphicsContext.restoreGraphicsState()
try rep.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("docs/social-preview.png"))
