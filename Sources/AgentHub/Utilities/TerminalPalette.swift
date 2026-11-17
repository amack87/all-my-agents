import AppKit
import SwiftTerm

/// The fixed colour palette every terminal in the app paints with.
///
/// Agents running inside a pane ask the terminal for its background colour over
/// OSC 11 and then pick a theme to match. When the terminal follows the macOS
/// appearance, a pane in a light-mode window answers "white", the agent paints
/// its light theme over the whole chat panel, and the terminal turns white. The
/// palette is therefore fixed and dark whatever the host appearance is.
enum TerminalPalette {
    /// #0A0A0A — the colour an agent reads over OSC 11, and the one its own
    /// dark theme paints over, so the two meet without a seam.
    static let background = NSColor(
        srgbRed: 10.0 / 255.0,
        green: 10.0 / 255.0,
        blue: 10.0 / 255.0,
        alpha: 1.0
    )

    /// #E6E6E6 — the default text colour.
    static let foreground = NSColor(
        srgbRed: 230.0 / 255.0,
        green: 230.0 / 255.0,
        blue: 230.0 / 255.0,
        alpha: 1.0
    )

    /// Paint a terminal view with the palette.
    ///
    /// Setting `nativeBackgroundColor` also sets the terminal's own background
    /// colour, and that is the colour SwiftTerm answers OSC 11 with. One call
    /// therefore fixes both what the user sees and what the agent believes.
    static func apply(to view: TerminalView) {
        view.nativeForegroundColor = foreground
        view.nativeBackgroundColor = background
    }
}
