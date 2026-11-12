import AppKit
import Observation
import SwiftUI

@Observable
final class NotchGeometry {
    var notchWidth: CGFloat = 0
    var notchHeight: CGFloat = 32
    var hasNotch = false
}

final class NotchPanel: NSPanel {
    init(rect: NSRect) {
        super.init(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        ignoresMouseEvents = true
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Owns the notch panel, keeps it on the notched screen and toggles mouse pass-through.
final class NotchController {
    let store: Store
    let geometry = NotchGeometry()
    private var panel: NotchPanel!
    private var hitRect: CGRect = .zero
    private var monitors: [Any] = []
    private var enterWork: DispatchWorkItem?
    private var exitWork: DispatchWorkItem?
    private var pollTimer: Timer?
    private var lastInside = false
    private let debug = ProcessInfo.processInfo.environment["CLISLAND_DEBUG"] != nil
    static let size = NSSize(width: 760, height: 560)

    init(store: Store) {
        self.store = store
        panel = NotchPanel(rect: NSRect(origin: .zero, size: Self.size))
        let root = NotchRoot(store: store, geo: geometry) { [weak self] rect in
            self?.hitRect = rect
            if self?.debug == true { self?.log("island frame \(rect)") }
        }
        let host = ClickThroughHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: Self.size)
        panel.contentView = host
        place()
        panel.orderFrontRegardless()

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.place()
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.panel.orderFrontRegardless()
        }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseDown]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in self?.track() }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in self?.track(); return e }) { monitors.append(l) }
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.track() }
        t.tolerance = 0.02
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
    }

    static func targetScreen() -> NSScreen? {
        NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main ?? NSScreen.screens.first
    }

    func place() {
        guard let screen = Self.targetScreen() else { return }
        if screen.safeAreaInsets.top > 0, let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            geometry.hasNotch = true
            geometry.notchWidth = screen.frame.width - l.width - r.width
            geometry.notchHeight = screen.safeAreaInsets.top
        } else {
            geometry.hasNotch = false
            geometry.notchWidth = 0
            geometry.notchHeight = max(24, screen.frame.maxY - screen.visibleFrame.maxY)
        }
        let s = Self.size
        panel.setFrame(NSRect(x: screen.frame.midX - s.width / 2, y: screen.frame.maxY - s.height, width: s.width, height: s.height), display: true)
    }

    /// Screen rect that counts as "on the island": the drawn island, or the hardware notch when nothing is drawn.
    private func hoverZone() -> NSRect? {
        let f = panel.frame
        if hitRect.width > 1 {
            return NSRect(x: f.minX + hitRect.minX, y: f.maxY - hitRect.maxY, width: hitRect.width, height: hitRect.height)
        }
        guard geometry.hasNotch else { return nil }
        let w = geometry.notchWidth, h = geometry.notchHeight
        return NSRect(x: f.midX - w / 2, y: f.maxY - h, width: w, height: h)
    }

    private func track() {
        let p = NSEvent.mouseLocation
        let inside = hoverZone().map { $0.insetBy(dx: -6, dy: -6).contains(p) } ?? false
        if debug, inside != lastInside { log("inside=\(inside) mouse=\(p) zone=\(String(describing: hoverZone())) hit=\(hitRect) panel=\(panel.frame)") }
        lastInside = inside
        panel.ignoresMouseEvents = !inside
        if inside {
            exitWork?.cancel(); exitWork = nil
            if !store.hovering, enterWork == nil {
                let w = DispatchWorkItem { [weak self] in self?.store.setHovering(true); self?.enterWork = nil }
                enterWork = w
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: w)
            }
        } else {
            enterWork?.cancel(); enterWork = nil
            if store.hovering, exitWork == nil {
                let w = DispatchWorkItem { [weak self] in self?.store.setHovering(false); self?.exitWork = nil }
                exitWork = w
                DispatchQueue.main.asyncAfter(deadline: .now() + store.config.hoverLingerSeconds, execute: w)
            }
        }
    }

    private func log(_ s: String) { FileHandle.standardError.write(Data("[hover] \(s)\n".utf8)) }
}
