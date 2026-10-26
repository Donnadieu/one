import AppKit
import SwiftUI

// MARK: - The map itself: a canvas redrawn every frame, plus the mouse and trackpad handling.

extension RoomGraph {
    /// Called once per drawn frame with the frame's time.
    func advance(_ date: Date) {
        let now = date.timeIntervalSinceReferenceDate
        let dt = last.map { now - $0 } ?? 1.0 / 60
        last = now
        step(dt)
    }
}

struct RoomGraphView: View {
    @ObservedObject var g: RoomGraph
    /// Renders: draw one still frame with no clock.
    var still = false
    @State private var press: Press?
    @State private var lastMag: CGFloat = 1
    @State private var monitor: Any?
    struct Press {
        let start: CGPoint
        let node: Int?
        var moved = false
        let w: CGPoint
    }
    var body: some View {
        GeometryReader { geo in
            Group {
                if still {
                    Canvas { ctx, size in
                        g.setSize(size)
                        RoomGraphDraw.draw(&ctx, g)
                    }
                } else {
                    TimelineView(.animation) { tl in
                        Canvas { ctx, size in
                            g.setSize(size)
                            g.advance(tl.date)
                            RoomGraphDraw.draw(&ctx, g)
                        }
                    }
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { ph in
                switch ph {
                case .active(let p):
                    g.ptr = p
                    g.ptrInside = true
                    g.cursorWants.set()
                case .ended:
                    g.ptrInside = false
                    g.ptr = CGPoint(x: -1e4, y: -1e4)
                    NSCursor.arrow.set()
                }
            }
            .gesture(pointer)
            .simultaneousGesture(magnify)
            .onAppear {
                g.frameInWindow = geo.frame(in: .global)
                if !still { watchScroll() }
            }
            .onChange(of: geo.size) { _, _ in g.frameInWindow = geo.frame(in: .global) }
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }
        }
    }
    /// Press on a note and move = drag the note; press on empty space and move = look around;
    /// press and let go without moving = click.
    var pointer: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                if press == nil {
                    g.ptr = v.startLocation
                    g.ptrInside = true
                    press = Press(start: v.startLocation, node: g.hoverNode, w: g.cam.w)
                }
                guard var p = press else { return }
                if !p.moved && hypot(v.translation.width, v.translation.height) > 4 { p.moved = true }
                press = p
                guard p.moved else { return }
                g.ptr = v.location
                if let n = p.node {
                    g.dragNode = n
                    g.dragNote(n, to: v.location)
                } else {
                    g.panning = true
                    g.cam.w = CGPoint(x: p.w.x - v.translation.width / g.cam.k, y: p.w.y - v.translation.height / g.cam.k)
                    g.tgt = g.cam
                    g.flying = false
                }
                g.cursorWants.set()
            }
            .onEnded { v in
                if let p = press, !p.moved { g.click(at: v.location) }
                press = nil
                g.dragNode = nil
                g.panning = false
            }
    }
    var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { v in
                g.zoomAt(v.startLocation, v.magnification / lastMag)
                lastMag = v.magnification
            }
            .onEnded { _ in lastMag = 1 }
    }
    /// A mouse wheel zooms; a trackpad's two-finger scroll looks around (pinch zooms).
    func watchScroll() {
        guard monitor == nil else { return }
        let g = self.g
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { e in
            guard let w = e.window, w.identifier?.rawValue == RoomsWindow.id, let cv = w.contentView else { return e }
            let lp = e.locationInWindow
            let pt = CGPoint(x: lp.x - g.frameInWindow.minX, y: cv.bounds.height - lp.y - g.frameInWindow.minY)
            guard CGRect(origin: .zero, size: g.size).contains(pt) else { return e }
            if g.readerOpen && pt.x > g.size.width - 400 { return e }
            if e.hasPreciseScrollingDeltas {
                g.pan(by: CGSize(width: e.scrollingDeltaX, height: e.scrollingDeltaY))
            } else {
                g.zoomAt(pt, pow(1.12, max(-5, min(5, e.scrollingDeltaY))))
            }
            return nil
        }
    }
}

// MARK: - Its own window, so you can make it as big as you like

@MainActor
enum RoomsWindow {
    static let id = "one.rooms"
    static var panel: NSPanel?
    private static var closing: Any?
    static var isOpen: Bool { panel.map { $0.isVisible && !$0.isMiniaturized } ?? false }
    static func show(_ m: Model) {
        if let p = panel {
            p.makeKeyAndOrderFront(nil)
            return
        }
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820), styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        p.title = "Your rooms"
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.identifier = NSUserInterfaceItemIdentifier(id)
        p.hidesOnDeactivate = false
        p.isFloatingPanel = false
        p.isReleasedWhenClosed = false
        p.minSize = NSSize(width: 900, height: 600)
        p.appearance = NSAppearance(named: .darkAqua)
        p.backgroundColor = NSColor(red: 0x14 / 255, green: 0x14 / 255, blue: 0x16 / 255, alpha: 1)
        p.contentView = NSHostingView(rootView: RoomsView(m: m) { RoomsWindow.panel?.close() })
        if !p.setFrameUsingName("OneRooms") {
            let v = (NSApp.keyWindow?.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            p.setFrame(
                NSRect(x: v.minX + v.width * 0.07, y: v.minY + v.height * 0.06, width: v.width * 0.86, height: v.height * 0.88), display: false)
        }
        p.setFrameAutosaveName("OneRooms")
        closing = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: p, queue: .main) { _ in
            MainActor.assumeIsolated {
                if let c = closing { NotificationCenter.default.removeObserver(c) }
                closing = nil
                panel = nil
                Floater.shared.syncOrb()
            }
        }
        panel = p
        p.makeKeyAndOrderFront(nil)
    }
}
