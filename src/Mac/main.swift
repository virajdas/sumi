// Sumi for macOS: a native window around the system's WebKit, running the same reader UI as Windows.
import Cocoa
import UniformTypeIdentifiers
import WebKit

let dataDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Sumi", isDirectory: true)
let settingsFile = dataDir.appendingPathComponent("settings.ini")
let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn", "mdx"]

func jsonLiteral(_ value: Any) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: value) else { return "null" }
    return String(decoding: data, as: UTF8.self)
}

// ---------- Reading preferences ----------
// key=value lines, the same format as on Windows. Handed to the page before its scripts run.
enum Prefs {
    static var values: [String: String] = load()

    static func load() -> [String: String] {
        guard let text = try? String(contentsOf: settingsFile, encoding: .utf8) else { return [:] }
        var result: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2 { result[String(parts[0])] = String(parts[1]) }
        }
        return result
    }

    static func set(_ key: String, _ value: String) {
        guard !key.isEmpty, key.count <= 24, key.allSatisfy({ $0.isLowercase }), value.count <= 64 else { return }
        values[key] = value
        try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        let text = values.keys.sorted().map { "\($0)=\(values[$0]!)" }.joined(separator: "\n") + "\n"
        try? text.write(to: settingsFile, atomically: true, encoding: .utf8)
    }
}

// ---------- Serving the UI and the document's images ----------
// sumi://app/... is the bundled UI, sumi://doc/... is the folder of the open document.
final class SchemeHandler: NSObject, WKURLSchemeHandler {
    weak var reader: Reader?

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, let root = rootFolder(url.host) else { return fail(task) }
        let file = root.appendingPathComponent(url.path).standardizedFileURL
        guard file.path.hasPrefix(root.standardizedFileURL.path + "/"),
              let data = try? Data(contentsOf: file) else { return fail(task) }
        let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let headers = ["Content-Type": mime, "Cache-Control": "no-cache", "Access-Control-Allow-Origin": "*"]
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    private func rootFolder(_ host: String?) -> URL? {
        if host == "app" { return Bundle.main.resourceURL?.appendingPathComponent("web", isDirectory: true) }
        if host == "doc" { return reader?.fileURL?.deletingLastPathComponent() }
        return nil
    }

    private func fail(_ task: WKURLSchemeTask) { task.didFailWithError(URLError(.fileDoesNotExist)) }
}

// A web view that takes dropped files itself, because the page can't see their paths.
final class ReaderWebView: WKWebView {
    var onDrop: ((URL) -> Void)?

    private func showDrop(_ on: Bool) {
        evaluateJavaScript("document.getElementById('drop').classList.toggle('show', \(on))", completionHandler: nil)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        showDrop(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func draggingExited(_ sender: NSDraggingInfo?) { showDrop(false) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        showDrop(false)
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]
        guard let url = urls?.first else { return false }
        onDrop?(url)
        return true
    }
}

// ---------- One window ----------
final class Reader: NSObject, NSWindowDelegate, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate, NSSearchFieldDelegate {
    let window: NSWindow
    let web: ReaderWebView
    let schemes = SchemeHandler()
    var fileURL: URL?
    var onClose: ((Reader) -> Void)?

    private var pageReady = false
    private var watcher: DispatchSourceFileSystemObject?
    private var reloadWork: DispatchWorkItem?
    private var appearanceWatch: NSKeyValueObservation?
    private var findBar: NSTitlebarAccessoryViewController?
    private var findField: NSSearchField?

    init(fileURL: URL?) {
        self.fileURL = fileURL
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(schemes, forURLScheme: "sumi")
        web = ReaderWebView(frame: NSRect(x: 0, y: 0, width: 760, height: 860), configuration: config)
        window = NSWindow(contentRect: web.frame, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        super.init()
        schemes.reader = self

        // Lets the page speak to the app through the same little interface it uses on Windows.
        let bridge = """
        window.chrome = { webview: {
          _listeners: [],
          postMessage(m) { webkit.messageHandlers.sumi.postMessage(m); },
          addEventListener(type, fn) { this._listeners.push(fn); },
          _deliver(data) { this._listeners.forEach((fn) => fn({ data })); },
        } };
        window.__sumiDocBase = "sumi://doc/";
        """
        let controller = config.userContentController
        controller.addUserScript(WKUserScript(source: bridge, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        controller.addUserScript(WKUserScript(source: "window.__sumiPrefs = \(jsonLiteral(Prefs.values));",
                                              injectionTime: .atDocumentStart, forMainFrameOnly: true))
        controller.add(self, name: "sumi")

        web.navigationDelegate = self
        web.uiDelegate = self
        web.setValue(false, forKey: "drawsBackground") // no white flash while loading
        web.onDrop = { [weak self] url in self?.open(url) }
        web.registerForDraggedTypes([.fileURL])

        // The window follows the page's theme, but the page's "Automatic" must keep following the system.
        web.appearance = NSApp.effectiveAppearance
        appearanceWatch = NSApp.observe(\.effectiveAppearance) { [weak self] app, _ in
            DispatchQueue.main.async { self?.web.appearance = app.effectiveAppearance }
        }

        window.title = "Sumi"
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.contentView = web
        window.minSize = NSSize(width: 420, height: 360)
        window.titlebarAppearsTransparent = true
        window.tabbingMode = .disallowed
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        window.backgroundColor = dark ? NSColor(hex: "#1b1b1d") : NSColor(hex: "#faf8f4")
        window.center()
        window.setFrameAutosaveName("Sumi")
        window.makeKeyAndOrderFront(nil)

        web.load(URLRequest(url: URL(string: "sumi://app/index.html")!))
    }

    func js(_ source: String) { web.evaluateJavaScript(source, completionHandler: nil) }

    func deliver(_ payload: [String: Any]) { js("chrome.webview._deliver(\(jsonLiteral(payload)))") }

    // ---------- Documents ----------

    func open(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        fileURL = url
        sendDocument(reload: false)
    }

    private func sendDocument(reload: Bool) {
        guard pageReady, let url = fileURL else { return }
        guard let data = try? Data(contentsOf: url) else {
            if !reload { deliver(["type": "toast", "text": "Couldn’t open that file."]) }
            return
        }
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        window.title = url.lastPathComponent
        window.representedURL = url
        deliver(["type": "doc", "name": url.lastPathComponent, "md": text, "reload": reload])
        watch(url)
    }

    // Editors often replace a file when saving, so the watch is re-made after every change.
    private func watch(_ url: URL) {
        watcher?.cancel()
        let fd = Darwin.open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.reloadWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.sendDocument(reload: true) }
            self.reloadWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.allowedFileTypes = Array(markdownExtensions) + ["txt"]
        panel.directoryURL = fileURL?.deletingLastPathComponent()
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK, let url = panel.url { self?.open(url) }
        }
    }

    // ---------- Messages from the page ----------

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let text = message.body as? String else { return }
        if text == "ready" {
            pageReady = true
            sendDocument(reload: false)
        } else if text == "open" {
            showOpenPanel()
        } else if text.hasPrefix("chrome:") {
            let parts = text.split(separator: ":")
            if parts.count == 3 {
                window.appearance = NSAppearance(named: parts[1] == "1" ? .darkAqua : .aqua)
                window.backgroundColor = NSColor(hex: String(parts[2]))
            }
        } else if text.hasPrefix("link:") {
            follow(String(text.dropFirst(5)))
        } else if text.hasPrefix("copy:") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(String(text.dropFirst(5)), forType: .string)
        } else if text.hasPrefix("pref:"), let eq = text.firstIndex(of: "=") {
            let start = text.index(text.startIndex, offsetBy: 5)
            Prefs.set(String(text[start..<eq]), String(text[text.index(after: eq)...]))
        }
    }

    private func follow(_ href: String) {
        guard let url = URL(string: href) else { return }
        if url.scheme == "sumi", url.host == "doc", let folder = fileURL?.deletingLastPathComponent() {
            let target = folder.appendingPathComponent(url.path).standardizedFileURL
            guard FileManager.default.fileExists(atPath: target.path) else {
                deliver(["type": "toast", "text": "File not found"])
                return
            }
            if markdownExtensions.contains(target.pathExtension.lowercased()) { open(target) } else { NSWorkspace.shared.open(target) }
        } else if ["http", "https", "mailto"].contains(url.scheme ?? "") {
            NSWorkspace.shared.open(url)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let url = action.request.url
        if url?.scheme == "sumi", url?.host == "app" {
            pageReady = false // a reload says "ready" again
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
            if let href = url?.absoluteString { follow(href) }
        }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let href = action.request.url?.absoluteString { follow(href) }
        return nil
    }

    // ---------- Find ----------

    func showFind() {
        if findBar == nil {
            let field = NSSearchField(frame: NSRect(x: 0, y: 4, width: 220, height: 22))
            field.placeholderString = "Find"
            field.delegate = self
            field.target = self
            field.action = #selector(findChanged)
            field.sendsWholeSearchString = false
            let holder = NSView(frame: NSRect(x: 0, y: 0, width: 232, height: 30))
            holder.addSubview(field)
            let bar = NSTitlebarAccessoryViewController()
            bar.view = holder
            bar.layoutAttribute = .right
            window.addTitlebarAccessoryViewController(bar)
            findBar = bar
            findField = field
        }
        findBar?.isHidden = false
        window.makeFirstResponder(findField)
    }

    func find(backwards: Bool) {
        guard let text = findField?.stringValue, !text.isEmpty else { return }
        let config = WKFindConfiguration()
        config.backwards = backwards
        config.wraps = true
        web.find(text, configuration: config) { _ in }
    }

    @objc private func findChanged() { find(backwards: false) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            find(backwards: NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false)
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            findBar?.isHidden = true
            window.makeFirstResponder(web)
            return true
        }
        return false
    }

    func print() {
        let operation = web.printOperation(with: NSPrintInfo.shared)
        operation.view?.frame = NSPrintInfo.shared.imageablePageBounds
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    func windowWillClose(_ notification: Notification) {
        watcher?.cancel()
        web.configuration.userContentController.removeScriptMessageHandler(forName: "sumi")
        onClose?(self)
    }
}

extension NSColor {
    convenience init(hex: String) {
        let value = Int(hex.trimmingCharacters(in: CharacterSet(charactersIn: "# ")), radix: 16) ?? 0xfaf8f4
        self.init(srgbRed: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255,
                  blue: CGFloat(value & 255) / 255, alpha: 1)
    }
}

// ---------- The app ----------
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
    @objc func larger(_ sender: Any?) { current?.js("__sumi.stepSize(1)") }
    @objc func smaller(_ sender: Any?) { current?.js("__sumi.stepSize(-1)") }
    @objc func actualSize(_ sender: Any?) { current?.js("__sumi.resetSize()") }
    @objc func nextTheme(_ sender: Any?) { current?.js("__sumi.cycleTheme()") }
    @objc func nextFont(_ sender: Any?) { current?.js("__sumi.cycleFont(1)") }
    @objc func contents(_ sender: Any?) { current?.js("__sumi.toggleToc()") }
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
