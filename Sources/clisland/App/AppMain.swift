import AppKit
import CLIslandCore
import Foundation

enum AppMain {
    static func run() -> Never {
        Paths.ensureRoot()
        if SocketServer.isRunning(path: Paths.socket.path) {
            FileHandle.standardError.write(Data("CLIsland is already running.\n".utf8))
            exit(0)
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
        exit(0)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let store = Store()
    var server: SocketServer!
    var codex = CodexWatcher()
    var notch: NotchController!
    var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGPIPE, SIG_IGN)
        server = SocketServer(path: Paths.socket.path)
        server.onEvent = { [weak self] e in self?.store.handle(e) }
        server.onAbandon = { [weak self] id in self?.store.permissionAbandoned(id) }
        server.onQuery = { [weak self] q in self?.query(q) ?? .object([]) }
        store.replyHandler = { [weak self] id, reply in self?.server.finish(id, reply: reply) }
        do { try server.start() } catch {
            FileHandle.standardError.write(Data("clisland: cannot open socket at \(Paths.socket.path): \(error)\n".utf8))
            exit(1)
        }
        codex.onEvent = { [weak self] e, replay in self?.store.handle(e, replay: replay) }
        codex.start()
        notch = NotchController(store: store)
        setupStatusItem()
    }

    func applicationWillTerminate(_ notification: Notification) { server?.stop() }

    private func query(_ q: JSON) -> JSON {
        switch q["data"]?["cmd"]?.string ?? "" {
        case "quit":
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return .obj([("ok", .bool(true))])
        case "reload":
            store.config = Config.load()
            return .obj([("ok", .bool(true))])
        case "peek":
            store.peek()
            return .obj([("ok", .bool(true))])
        case "ping":
            return .obj([("ok", .bool(true)), ("pid", .number(Double(getpid())))])
        default:
            return store.statusJSON()
        }
    }

    // MARK: Menu bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = statusItem.button {
            b.image = NSImage(systemSymbolName: "capsule.tophalf.filled", accessibilityDescription: "CLIsland")
                ?? NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "CLIsland")
            b.image?.isTemplate = true
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let n = store.sessions.count
        let header = NSMenuItem(title: "CLIsland · \(n) session\(n == 1 ? "" : "s")", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for s in store.sessions.prefix(8) {
            let item = NSMenuItem(title: "\(Theme.glyph(s.agent))  \(s.project) — \(s.status.label)", action: #selector(focusSession(_:)), keyEquivalent: "")
            item.representedObject = s.id
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        addToggle(menu, "Sounds", store.config.sounds) { $0.sounds.toggle() }
        addToggle(menu, "Live activity line", store.config.activityLine) { $0.activityLine.toggle() }
        addToggle(menu, "Approve permissions from notch", store.config.approveFromNotch) { $0.approveFromNotch.toggle() }
        menu.addItem(.separator())
        let demo = NSMenuItem(title: "Play demo", action: #selector(playDemo), keyEquivalent: "")
        demo.target = self
        menu.addItem(demo)
        let folder = NSMenuItem(title: "Open settings folder", action: #selector(openFolder), keyEquivalent: "")
        folder.target = self
        menu.addItem(folder)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit CLIsland", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private var toggles: [Int: (inout Config) -> Void] = [:]

    private func addToggle(_ menu: NSMenu, _ title: String, _ on: Bool, _ change: @escaping (inout Config) -> Void) {
        let item = NSMenuItem(title: title, action: #selector(toggle(_:)), keyEquivalent: "")
        item.state = on ? .on : .off
        item.target = self
        item.tag = toggles.count + 1
        toggles[item.tag] = change
        menu.addItem(item)
    }

    @objc private func toggle(_ sender: NSMenuItem) {
        guard let change = toggles[sender.tag] else { return }
        var c = Config.load()
        change(&c)
        try? c.save()
        store.config = c
    }

    @objc private func focusSession(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { store.open(id) }
    }

    @objc private func playDemo() {
        let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = ["demo"]
        p.standardOutput = FileHandle.nullDevice
        try? p.run()
    }

    @objc private func openFolder() { NSWorkspace.shared.open(Paths.root) }

    @objc private func quit() { NSApp.terminate(nil) }
}
