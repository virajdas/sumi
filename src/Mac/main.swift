// Sumi for macOS: a native AppKit and TextKit reader, with the same look and behaviour as the Windows version.
import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var readers: [Reader] = []
    private var launched = false

    private var current: Reader? { readers.first { $0.window.isKeyWindow } ?? readers.last }

    @discardableResult private func newReader(_ url: URL?) -> Reader {
        let reader = Reader(fileURL: url)
        reader.onClose = { [weak self] closed in self?.readers.removeAll { $0 === closed } }
        readers.append(reader)
        return reader
    }

    // Files opened from Finder arrive here, before or after launch.
    func application(_ application: NSApplication, open urls: [URL]) {
        launched = true
        for url in urls {
            if let empty = readers.first(where: { $0.fileURL == nil }) { empty.open(url) } else { newReader(url) }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = buildMenu()
        let args = CommandLine.arguments.dropFirst().filter { FileManager.default.fileExists(atPath: $0) }
        if !args.isEmpty {
            application(NSApp, open: args.map { URL(fileURLWithPath: $0) })
        } else if !launched {
            newReader(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    @objc func openDocument(_ sender: Any?) { current?.showOpenPanel() }
    @objc func printDocument(_ sender: Any?) { current?.print() }
    @objc func larger(_ sender: Any?) { current?.stepSize(1) }
    @objc func smaller(_ sender: Any?) { current?.stepSize(-1) }
    @objc func actualSize(_ sender: Any?) { current?.resetSize() }
    @objc func nextTheme(_ sender: Any?) { current?.cycleTheme() }
    @objc func nextFont(_ sender: Any?) { current?.cycleFont() }
    @objc func contents(_ sender: Any?) { current?.toggleOutline() }
    @objc func showFind(_ sender: Any?) { current?.showFind() }
    @objc func findNext(_ sender: Any?) { current?.find(backwards: false) }
    @objc func findPrevious(_ sender: Any?) { current?.find(backwards: true) }

    private func buildMenu() -> NSMenu {
        func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
            entry.keyEquivalentModifierMask = mods
            return entry
        }
        func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let top = NSMenuItem()
            top.submenu = NSMenu(title: title)
            items.forEach { top.submenu?.addItem($0) }
            return top
        }
        let windowMenu = menu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
        ])
        NSApp.windowsMenu = windowMenu.submenu

        let bar = NSMenu()
        [
            menu("Sumi", [
                item("About Sumi", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
                .separator(),
                item("Hide Sumi", #selector(NSApplication.hide(_:)), "h"),
                item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
                item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
                .separator(),
                item("Quit Sumi", #selector(NSApplication.terminate(_:)), "q"),
            ]),
            menu("File", [
                item("Open…", #selector(openDocument(_:)), "o"),
                item("Close", #selector(NSWindow.performClose(_:)), "w"),
                .separator(),
                item("Print…", #selector(printDocument(_:)), "p"),
            ]),
            menu("Edit", [
                item("Copy", #selector(NSText.copy(_:)), "c"),
                item("Select All", #selector(NSText.selectAll(_:)), "a"),
                .separator(),
                item("Find…", #selector(showFind(_:)), "f"),
                item("Find Next", #selector(findNext(_:)), "g"),
                item("Find Previous", #selector(findPrevious(_:)), "g", [.command, .shift]),
            ]),
            menu("View", [
                item("Contents", #selector(contents(_:)), "\\"),
                .separator(),
                item("Larger Text", #selector(larger(_:)), "="),
                item("Smaller Text", #selector(smaller(_:)), "-"),
                item("Default Text Size", #selector(actualSize(_:)), "0"),
                .separator(),
                item("Next Appearance", #selector(nextTheme(_:)), "t"),
                item("Next Typeface", #selector(nextFont(_:)), "f", [.command, .shift]),
            ]),
            windowMenu,
        ].forEach { bar.addItem($0) }
        return bar
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
