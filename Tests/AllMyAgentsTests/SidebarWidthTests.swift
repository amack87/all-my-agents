import Foundation
import Testing
@testable import AllMyAgents

@Suite("Sidebar width")
struct SidebarWidthTests {
    /// A private suite so the tests never touch the real defaults. Each test
    /// gets its own — swift-testing runs them in parallel, and a shared suite
    /// would have them clobbering each other's saved width.
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "SidebarWidthTests.\(UUID().uuidString)")!
    }

    @Test("a width below the minimum is pulled up to it")
    func clampsBelowMinimum() {
        #expect(SidebarWidth.clamp(40) == SidebarWidth.minimumWidth)
    }

    @Test("a width above the maximum is pulled down to it")
    func clampsAboveMaximum() {
        #expect(SidebarWidth.clamp(5_000) == SidebarWidth.maximumWidth)
    }

    @Test("a width inside the range is left alone")
    func keepsWidthInsideRange() {
        #expect(SidebarWidth.clamp(250) == 250)
    }

    @Test("with nothing saved the sidebar starts at its default width")
    func loadsDefaultWhenNothingSaved() {
        let defaults = makeDefaults()
        #expect(SidebarWidth.load(from: defaults) == SidebarWidth.defaultWidth)
    }

    @Test("a saved width is read back")
    func loadsSavedWidth() {
        let defaults = makeDefaults()
        SidebarWidth.save(300, to: defaults)
        #expect(SidebarWidth.load(from: defaults) == 300)
    }

    @Test("a saved width outside the range is clamped on load")
    func clampsSavedWidthOnLoad() {
        let defaults = makeDefaults()
        defaults.set(Double(SidebarWidth.maximumWidth + 100), forKey: SidebarWidth.defaultsKey)
        #expect(SidebarWidth.load(from: defaults) == SidebarWidth.maximumWidth)
    }

    @Test("saving an out-of-range width clamps it on the way in")
    func clampsOnSave() {
        let defaults = makeDefaults()
        SidebarWidth.save(-10, to: defaults)
        #expect(SidebarWidth.load(from: defaults) == SidebarWidth.minimumWidth)
    }

    @Test("a reset returns the sidebar to its default width")
    func resetReturnsToDefault() {
        let defaults = makeDefaults()
        SidebarWidth.save(320, to: defaults)
        SidebarWidth.reset(in: defaults)
        #expect(SidebarWidth.load(from: defaults) == SidebarWidth.defaultWidth)
    }

    @Test("the panel can always hold the narrowest sidebar beside some content")
    func panelMinimumLeavesRoomForContent() {
        #expect(SidebarWidth.panelMinimumWidth == SidebarWidth.minimumWidth + SidebarWidth.contentMinimumWidth)
        #expect(SidebarWidth.panelMinimumWidth == 520)
    }

    @Test("the panel is wide enough for the sidebar it is showing")
    func panelWidthFollowsTheSidebar() {
        #expect(SidebarWidth.panelWidth(forSidebarWidth: 200) == 560)
        #expect(SidebarWidth.panelWidth(forSidebarWidth: 300) == 660)
        #expect(SidebarWidth.panelWidth(forSidebarWidth: SidebarWidth.maximumWidth) == 780)
    }

    @Test("a sidebar wider than the range asks for no more panel than the widest one")
    func panelWidthClampsTheSidebarFirst() {
        #expect(SidebarWidth.panelWidth(forSidebarWidth: 5_000) == 780)
    }
}
