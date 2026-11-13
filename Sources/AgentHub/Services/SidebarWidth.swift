import Foundation

/// The width of the session sidebar, in points.
///
/// The width is a per-machine preference: the web app keeps its own in
/// `localStorage`, so the two surfaces do not share one. It is never synced.
///
/// The web app clamps its sidebar against the width its content needs, which
/// does not transfer — the macOS panel is a fixed floating window, so the
/// width is clamped to a fixed range instead.
enum SidebarWidth {
    /// UserDefaults key holding the saved width.
    static let defaultsKey = "allmyagents-sidebar-width"

    /// The width the sidebar starts at, and the one a reset returns to.
    static let defaultWidth: CGFloat = 200

    /// Narrowest the sidebar may be dragged.
    static let minimumWidth: CGFloat = 160

    /// Widest the sidebar may be dragged.
    static let maximumWidth: CGFloat = 420

    /// The narrowest the main content area is allowed to become.
    static let contentMinimumWidth: CGFloat = 360

    /// The narrowest the panel may be while the sidebar is visible.
    static var panelMinimumWidth: CGFloat { minimumWidth + contentMinimumWidth }

    /// The width the panel needs to be to hold a sidebar of the given width
    /// beside a content area that is still usable.
    static func panelWidth(forSidebarWidth width: CGFloat) -> CGFloat {
        clamp(width) + contentMinimumWidth
    }

    /// Constrains a width to the allowed range.
    static func clamp(_ width: CGFloat) -> CGFloat {
        min(max(width, minimumWidth), maximumWidth)
    }

    /// The saved width, or the default when nothing is saved or the saved
    /// value is out of range.
    static func load(from defaults: UserDefaults = .standard) -> CGFloat {
        guard let saved = defaults.object(forKey: defaultsKey) as? Double else {
            return defaultWidth
        }
        return clamp(CGFloat(saved))
    }

    /// Saves a width, clamped to the allowed range.
    static func save(_ width: CGFloat, to defaults: UserDefaults = .standard) {
        defaults.set(Double(clamp(width)), forKey: defaultsKey)
    }

    /// Returns the sidebar to its default width.
    static func reset(in defaults: UserDefaults = .standard) {
        save(defaultWidth, to: defaults)
    }
}
