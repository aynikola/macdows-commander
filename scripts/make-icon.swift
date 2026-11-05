#!/usr/bin/env swift
// Draws the app icon: two panels with a transfer arrow between them.
//   swift scripts/make-icon.swift Resources/AppIcon.png
import AppKit

let side: CGFloat = 1024
let image = NSImage(size: NSSize(width: side, height: side))
image.lockFocus()

// Apple's icon grid: the shape fills 824 of 1024, leaving room for the shadow.
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
shadow.shadowBlurRadius = 28
shadow.shadowOffset = NSSize(width: 0, height: -12)
NSGraphicsContext.saveGraphicsState()
shadow.set()
NSColor(red: 0.09, green: 0.10, blue: 0.12, alpha: 1).setFill()
tilePath.fill()
NSGraphicsContext.restoreGraphicsState()

let blue = NSColor(red: 0.20, green: 0.43, blue: 0.96, alpha: 1)
let amber = NSColor(red: 1.00, green: 0.72, blue: 0.30, alpha: 1)
let idle = NSColor(red: 0.20, green: 0.22, blue: 0.26, alpha: 1)
let line = NSColor(red: 0.42, green: 0.46, blue: 0.52, alpha: 1)

func panel(x: CGFloat, active: Bool, markedRows: Set<Int>) {
    let frame = NSRect(x: x, y: 216, width: 276, height: 592)
    NSColor(red: 0.14, green: 0.155, blue: 0.18, alpha: 1).setFill()
    NSBezierPath(roundedRect: frame, xRadius: 30, yRadius: 30).fill()
    (active ? blue : idle).setFill()
    let head = NSBezierPath(roundedRect: NSRect(x: x, y: 718, width: 276, height: 90), xRadius: 30, yRadius: 30)
    head.append(NSBezierPath(rect: NSRect(x: x, y: 718, width: 276, height: 40)))
    head.fill()
    for row in 0..<6 {
        let y = 640 - CGFloat(row) * 76
        (markedRows.contains(row) ? amber : line).setFill()
        NSBezierPath(roundedRect: NSRect(x: x + 30, y: y, width: row % 2 == 0 ? 216 : 170, height: 30), xRadius: 15, yRadius: 15).fill()
    }
}

panel(x: 148, active: true, markedRows: [1, 2, 4])
panel(x: 600, active: false, markedRows: [])

// The arrow bridges the gap and overlaps both panels, which keeps it readable at small sizes.
let arrow = NSBezierPath()
let middle: CGFloat = 512
arrow.move(to: NSPoint(x: 366, y: middle + 52))
arrow.line(to: NSPoint(x: 510, y: middle + 52))
arrow.line(to: NSPoint(x: 510, y: middle + 128))
arrow.line(to: NSPoint(x: 668, y: middle))
arrow.line(to: NSPoint(x: 510, y: middle - 128))
arrow.line(to: NSPoint(x: 510, y: middle - 52))
arrow.line(to: NSPoint(x: 366, y: middle - 52))
arrow.close()
arrow.lineJoinStyle = .round
NSColor(red: 0.09, green: 0.10, blue: 0.12, alpha: 1).setStroke()
arrow.lineWidth = 36
arrow.stroke()
amber.setFill()
arrow.fill()

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Could not render the icon")
}
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
