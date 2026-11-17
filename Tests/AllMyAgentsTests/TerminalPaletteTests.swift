import AppKit
import SwiftTerm
import Testing
@testable import AllMyAgents

/// The palette must not follow the macOS appearance. An agent reads the
/// terminal's background colour over OSC 11 and picks a theme to match, so a
/// light-mode window that answers "white" makes the agent paint its light
/// theme over the whole pane.
@Suite("Terminal palette")
struct TerminalPaletteTests {
    /// Half a step of an 8-bit colour — enough to absorb rounding, small
    /// enough to catch a genuinely different colour.
    private static let tolerance = 1.0 / 255.0

    private func components(of color: NSColor, under appearance: NSAppearance) -> (CGFloat, CGFloat, CGFloat) {
        var resolved: (CGFloat, CGFloat, CGFloat) = (0, 0, 0)
        appearance.performAsCurrentDrawingAppearance {
            guard let rgb = color.usingColorSpace(.sRGB) else { return }
            resolved = (rgb.redComponent, rgb.greenComponent, rgb.blueComponent)
        }
        return resolved
    }

    private func same(_ a: (CGFloat, CGFloat, CGFloat), _ b: (CGFloat, CGFloat, CGFloat)) -> Bool {
        abs(a.0 - b.0) < Self.tolerance
            && abs(a.1 - b.1) < Self.tolerance
            && abs(a.2 - b.2) < Self.tolerance
    }

    /// Perceived lightness, good enough to say "dark" and "light".
    private func lightness(_ c: (CGFloat, CGFloat, CGFloat)) -> CGFloat {
        0.2126 * c.0 + 0.7152 * c.1 + 0.0722 * c.2
    }

    @Test("the background is the same colour in a light and a dark window")
    func backgroundIgnoresAppearance() {
        let light = components(of: TerminalPalette.background, under: NSAppearance(named: .aqua)!)
        let dark = components(of: TerminalPalette.background, under: NSAppearance(named: .darkAqua)!)
        #expect(same(light, dark))
    }

    @Test("the foreground is the same colour in a light and a dark window")
    func foregroundIgnoresAppearance() {
        let light = components(of: TerminalPalette.foreground, under: NSAppearance(named: .aqua)!)
        let dark = components(of: TerminalPalette.foreground, under: NSAppearance(named: .darkAqua)!)
        #expect(same(light, dark))
    }

    @Test("the background is #0A0A0A")
    func backgroundIsPinned() {
        let (r, g, b) = components(of: TerminalPalette.background, under: NSAppearance(named: .aqua)!)
        #expect(abs(r - 10.0 / 255.0) < Self.tolerance)
        #expect(abs(g - 10.0 / 255.0) < Self.tolerance)
        #expect(abs(b - 10.0 / 255.0) < Self.tolerance)
    }

    @Test("the foreground is #E6E6E6")
    func foregroundIsPinned() {
        let (r, g, b) = components(of: TerminalPalette.foreground, under: NSAppearance(named: .aqua)!)
        #expect(abs(r - 230.0 / 255.0) < Self.tolerance)
        #expect(abs(g - 230.0 / 255.0) < Self.tolerance)
        #expect(abs(b - 230.0 / 255.0) < Self.tolerance)
    }

    @Test("an agent reading the background sees a dark colour")
    func backgroundIsDark() {
        let rgb = components(of: TerminalPalette.background, under: NSAppearance(named: .aqua)!)
        #expect(lightness(rgb) < 0.2)
    }

    @Test("the text is light enough to read against the background")
    func foregroundIsLight() {
        let rgb = components(of: TerminalPalette.foreground, under: NSAppearance(named: .aqua)!)
        #expect(lightness(rgb) > 0.6)
    }

    @Test("the terminal reports the palette background to an agent asking for it")
    func terminalReportsThePaletteBackground() {
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        TerminalPalette.apply(to: view)

        // SwiftTerm answers OSC 11 with the terminal's own background colour,
        // so these are the bytes an agent reads before picking its theme.
        #expect(view.terminal.backgroundColor.red == UInt16(10.0 / 255.0 * 65535))
        #expect(view.terminal.backgroundColor.green == UInt16(10.0 / 255.0 * 65535))
        #expect(view.terminal.backgroundColor.blue == UInt16(10.0 / 255.0 * 65535))
        #expect(view.terminal.foregroundColor.red == UInt16(230.0 / 255.0 * 65535))
    }
}
