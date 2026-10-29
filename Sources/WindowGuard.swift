import AppKit

/// A window frame can be restored (macOS's own window-state restore across a quit, or just the AppKit default
/// of keeping a window wherever it last was) with its titlebar above the top of the current screen — after a
/// display change, a different monitor arrangement, or a restart that landed the window taller than before.
/// The titlebar is where the whole top row lives (see `HomeChrome.HomeTitleRow`: the name pill and Voice,
/// Rooms, Connections, Routines, Push to talk, Folders, Switch AI, Stop); when it's off-screen none of that
/// shows, even though the body (orb, greeting, chat) renders fine lower in the window and looks complete on
/// its own. Clamp any window to the screen it's (mostly) on the first time it appears, so the titlebar strip
/// is always reachable; leave an already-fine frame exactly as the person left it.
enum WindowGuard {
    /// How much of the top strip (titlebar + toolbar row) must sit inside the screen's `visibleFrame` to call
    /// the window "on screen". Big enough to catch a titlebar that's only a few points off, not just a whole
    /// window gone.
    static let titlebarStrip: CGFloat = 40

    @MainActor static func ensureOnScreen(_ window: NSWindow) {
        guard let screen = window.screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        var f = window.frame
        // A frame bigger than the whole screen would pass every on-screen check below trivially; shrink it first.
        f.size.width = min(f.size.width, visible.width)
        f.size.height = min(f.size.height, visible.height)
        // AppKit's y grows upward: the titlebar sits at the frame's top edge (maxY). Off the top of the
        // screen (maxY beyond visible.maxY) or scrolled off the bottom (maxY below visible.minY) both hide it.
        let titlebarOnScreen = f.maxY <= visible.maxY && f.maxY >= visible.minY + titlebarStrip
        let sideOnScreen = f.maxX > visible.minX + titlebarStrip && f.minX < visible.maxX - titlebarStrip
        if titlebarOnScreen && sideOnScreen {
            if f.size != window.frame.size { window.setFrame(f, display: true) }  // only the shrink above, if any
            return
        }
        f.origin.x = visible.midX - f.width / 2
        f.origin.y = visible.midY - f.height / 2
        window.setFrame(f, display: true)
    }
}
