#!/usr/bin/env swift
// Generates AppIcon.icns for AgentHub
// Design: Central hub node with radiating agent connections on a gradient background

import AppKit
import Foundation

func renderIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    guard let ctx = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus()
        return image
    }

    let s = size  // shorthand
    let center = CGPoint(x: s / 2, y: s / 2)

    // --- Background: rounded rect with gradient ---
    let cornerRadius = s * 0.22
    let bgRect = CGRect(x: 0, y: 0, width: s, height: s)
    let bgPath = CGPath(roundedRect: bgRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    ctx.addPath(bgPath)
    ctx.clip()

    // Dark gradient: deep navy to dark purple
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let gradientColors = [
        CGColor(red: 0.08, green: 0.08, blue: 0.18, alpha: 1.0),
        CGColor(red: 0.15, green: 0.08, blue: 0.28, alpha: 1.0),
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: colorSpace, colors: gradientColors, locations: [0.0, 1.0]) {
        ctx.drawLinearGradient(gradient,
                               start: CGPoint(x: 0, y: s),
                               end: CGPoint(x: s, y: 0),
                               options: [])
    }

    // --- Subtle grid pattern ---
    ctx.setStrokeColor(CGColor(red: 0.3, green: 0.3, blue: 0.5, alpha: 0.08))
    ctx.setLineWidth(s * 0.002)
    let gridSpacing = s / 12
    for i in 1..<12 {
        let pos = CGFloat(i) * gridSpacing
        ctx.move(to: CGPoint(x: pos, y: 0))
        ctx.addLine(to: CGPoint(x: pos, y: s))
        ctx.move(to: CGPoint(x: 0, y: pos))
        ctx.addLine(to: CGPoint(x: s, y: pos))
    }
    ctx.strokePath()

    // --- Agent nodes (outer ring) ---
    let agentCount = 6
    let orbitRadius = s * 0.30
    let nodeRadius = s * 0.065
    let hubRadius = s * 0.13

    // Colors for agent nodes
    let nodeColors: [(r: CGFloat, g: CGFloat, b: CGFloat)] = [
        (0.25, 0.80, 0.95),  // cyan
        (0.55, 0.80, 0.30),  // green
        (0.95, 0.65, 0.20),  // orange
        (0.90, 0.35, 0.55),  // pink
        (0.60, 0.50, 0.95),  // purple
        (0.95, 0.85, 0.25),  // yellow
    ]

    // Draw connections first (behind nodes)
    for i in 0..<agentCount {
        let angle = (CGFloat(i) / CGFloat(agentCount)) * .pi * 2 - .pi / 2
        let nodeCenter = CGPoint(
            x: center.x + cos(angle) * orbitRadius,
            y: center.y + sin(angle) * orbitRadius
        )

        let nc = nodeColors[i]

        // Glowing connection line
        for w in stride(from: s * 0.025, through: s * 0.004, by: -s * 0.005) {
            let alpha: CGFloat = w > s * 0.01 ? 0.08 : 0.35
            ctx.setStrokeColor(CGColor(red: nc.r, green: nc.g, blue: nc.b, alpha: alpha))
            ctx.setLineWidth(w)
            ctx.move(to: center)
            ctx.addLine(to: nodeCenter)
            ctx.strokePath()
        }
    }

    // Draw agent nodes
    for i in 0..<agentCount {
        let angle = (CGFloat(i) / CGFloat(agentCount)) * .pi * 2 - .pi / 2
        let nodeCenter = CGPoint(
            x: center.x + cos(angle) * orbitRadius,
            y: center.y + sin(angle) * orbitRadius
        )

        let nc = nodeColors[i]

        // Outer glow
        let glowRect = CGRect(
            x: nodeCenter.x - nodeRadius * 2,
            y: nodeCenter.y - nodeRadius * 2,
            width: nodeRadius * 4,
            height: nodeRadius * 4
        )
        if let glowGradient = CGGradient(
            colorsSpace: colorSpace,
            colors: [
                CGColor(red: nc.r, green: nc.g, blue: nc.b, alpha: 0.3),
                CGColor(red: nc.r, green: nc.g, blue: nc.b, alpha: 0.0),
            ] as CFArray,
            locations: [0.0, 1.0]
        ) {
            ctx.saveGState()
            ctx.addEllipse(in: glowRect)
            ctx.clip()
            ctx.drawRadialGradient(glowGradient,
                                    startCenter: nodeCenter, startRadius: 0,
                                    endCenter: nodeCenter, endRadius: nodeRadius * 2,
                                    options: [])
            ctx.restoreGState()
        }

        // Node circle
        let nodeRect = CGRect(
            x: nodeCenter.x - nodeRadius,
            y: nodeCenter.y - nodeRadius,
            width: nodeRadius * 2,
            height: nodeRadius * 2
        )
        ctx.setFillColor(CGColor(red: nc.r, green: nc.g, blue: nc.b, alpha: 0.9))
        ctx.fillEllipse(in: nodeRect)

        // Inner highlight
        let innerRect = CGRect(
            x: nodeCenter.x - nodeRadius * 0.55,
            y: nodeCenter.y - nodeRadius * 0.55,
            width: nodeRadius * 1.1,
            height: nodeRadius * 1.1
        )
        ctx.setFillColor(CGColor(red: min(nc.r + 0.2, 1), green: min(nc.g + 0.2, 1), blue: min(nc.b + 0.2, 1), alpha: 0.5))
        ctx.fillEllipse(in: innerRect)
    }

    // --- Central hub ---
    // Hub glow
    let hubGlowRect = CGRect(
        x: center.x - hubRadius * 2.5,
        y: center.y - hubRadius * 2.5,
        width: hubRadius * 5,
        height: hubRadius * 5
    )
    if let hubGlow = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            CGColor(red: 0.4, green: 0.6, blue: 1.0, alpha: 0.4),
            CGColor(red: 0.4, green: 0.6, blue: 1.0, alpha: 0.0),
        ] as CFArray,
        locations: [0.0, 1.0]
    ) {
        ctx.saveGState()
        ctx.addEllipse(in: hubGlowRect)
        ctx.clip()
        ctx.drawRadialGradient(hubGlow,
                                startCenter: center, startRadius: 0,
                                endCenter: center, endRadius: hubRadius * 2.5,
                                options: [])
        ctx.restoreGState()
    }

    // Hub circle with gradient
    let hubRect = CGRect(
        x: center.x - hubRadius,
        y: center.y - hubRadius,
        width: hubRadius * 2,
        height: hubRadius * 2
    )
    if let hubFill = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            CGColor(red: 0.45, green: 0.65, blue: 1.0, alpha: 1.0),
            CGColor(red: 0.30, green: 0.45, blue: 0.90, alpha: 1.0),
        ] as CFArray,
        locations: [0.0, 1.0]
    ) {
        ctx.saveGState()
        ctx.addEllipse(in: hubRect)
        ctx.clip()
        ctx.drawLinearGradient(hubFill,
                               start: CGPoint(x: center.x, y: center.y + hubRadius),
                               end: CGPoint(x: center.x, y: center.y - hubRadius),
                               options: [])
        ctx.restoreGState()
    }

    // Hub border ring
    ctx.setStrokeColor(CGColor(red: 0.6, green: 0.8, blue: 1.0, alpha: 0.6))
    ctx.setLineWidth(s * 0.008)
    ctx.strokeEllipse(in: hubRect)

    // "A" letter in the hub
    let fontSize = hubRadius * 1.1
    let font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor.white,
    ]
    let text = "A" as NSString
    let textSize = text.size(withAttributes: attributes)
    let textPoint = NSPoint(
        x: center.x - textSize.width / 2,
        y: center.y - textSize.height / 2
    )
    text.draw(at: textPoint, withAttributes: attributes)

    image.unlockFocus()
    return image
}

// Generate all required sizes
let sizes: [(CGFloat, String)] = [
    (16, "icon_16x16"),
    (32, "icon_16x16@2x"),
    (32, "icon_32x32"),
    (64, "icon_32x32@2x"),
    (128, "icon_128x128"),
    (256, "icon_128x128@2x"),
    (256, "icon_256x256"),
    (512, "icon_256x256@2x"),
    (512, "icon_512x512"),
    (1024, "icon_512x512@2x"),
]

// Create iconset directory
let iconsetPath = "AppIcon.iconset"
let fm = FileManager.default
try? fm.removeItem(atPath: iconsetPath)
try! fm.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)

for (size, name) in sizes {
    let image = renderIcon(size: size)
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        print("Failed to render \(name)")
        continue
    }
    let path = "\(iconsetPath)/\(name).png"
    try! png.write(to: URL(fileURLWithPath: path))
    print("Generated \(name).png (\(Int(size))x\(Int(size)))")
}

print("\nConverting to .icns...")
// iconutil converts the iconset to icns
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconsetPath]
try! process.run()
process.waitUntilExit()

if process.terminationStatus == 0 {
    print("Created AppIcon.icns")
    // Clean up iconset
    try? fm.removeItem(atPath: iconsetPath)
} else {
    print("iconutil failed with status \(process.terminationStatus)")
}
