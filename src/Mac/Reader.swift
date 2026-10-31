// One reading window: holds the document and its text view, and runs the behaviour app.js runs on Windows.
import AppKit
import UniformTypeIdentifiers

let dataDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Sumi", isDirectory: true)
let settingsFile = dataDir.appendingPathComponent("settings.ini")
let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn", "mdx"]

// key=value lines, the same format as on Windows.
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

// The window's content: takes dropped files, and hands every layout pass to the reader.
final class RootView: NSView {
    weak var reader: Reader?
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        reader?.layoutChrome()
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        reader?.drop.setShown(true)
        return .copy
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func draggingExited(_ sender: NSDraggingInfo?) { reader?.drop.setShown(false) }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        reader?.drop.setShown(false)
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]
        guard let url = urls?.first else { return false }
        reader?.open(url)
        return true
    }
    override func mouseExited(with event: NSEvent) { reader?.pointerLeft() }
    override func mouseDown(with event: NSEvent) {}
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { reader?.escape() } else { super.keyDown(with: event) }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // ⇧⌘= types a plus sign, which the menu's plain ⌘= doesn't catch.
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "+" {
            reader?.stepSize(1)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

// A slim scroller in the theme's faint colour, floating over the page.
final class ThinScroller: NSScroller {
    var knobColor = NSColor.clear
    override class var isCompatibleWithOverlayScrollers: Bool { true }
    override func drawKnob() {
        let rect = self.rect(for: .knob).insetBy(dx: 3, dy: 3)
        guard rect.height > 0 else { return }
        knobColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: rect.width / 2, yRadius: rect.width / 2).fill()
    }
    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}
}

final class Reader: NSObject, NSWindowDelegate, NSSearchFieldDelegate {
    let window: NSWindow
    var fileURL: URL?
    var onClose: ((Reader) -> Void)?

    private let root = RootView()
    private let scrollView = NSScrollView()
    private let scroller = ThinScroller()
    private let manager = ReaderLayoutManager()
    private let storage = NSTextStorage()
    private let container = NSTextContainer()
    private let textView: ReaderTextView
    private let welcome = WelcomeView()
    private let bar = BarView()
    private let outline = OutlineView()
    private let toast = ToastView()
    let drop = DropView()
    private let pointer = PointerLayer()
    private lazy var typo: TypoPanel = makeTypoPanel()
    private var typoBuilt = false

    private let images = ImageStore()
    private var blocks: [Block]?
    private var built: BuiltDocument?
    private var outlineRows: [OutlineRow] = []
    private var openDetails = Set<Int>()

    private var themeChoice: String
    private var face: Typeface
    private var size: CGFloat
    private var customPointer: Bool
    private var theme = Theme.light

    private var watcher: DispatchSourceFileSystemObject?
    private var reloadWork: DispatchWorkItem?
    private var reloadRetries = 0
    private var appearanceWatch: NSKeyValueObservation?
    private var monitor: Any?
    private var findBar: NSTitlebarAccessoryViewController?
    private var findField: NSSearchField?
    private var lastY: CGFloat = 0
    private var barTimer: Timer?
    private var hotControl: ChromeControl?
    private var lastPoint: NSPoint?
    private var hoveredLink: NSRange?
    private var linkAnimation: Timer?
    private var tocOpen = false
    private var tocShift = false
    private var tocOverlay = false
    private var columnKey: CGFloat = -1
    private var headingTops: [CGFloat]?

    private static let sizes: [CGFloat] = [15, 16, 17, 18, 19, 20, 21, 22, 24, 26, 28]
    private static let themes = ["auto", "light", "sepia", "dark"]

    init(fileURL: URL?) {
        self.fileURL = fileURL
        themeChoice = Reader.themes.contains(Prefs.values["theme"] ?? "") ? Prefs.values["theme"]! : "auto"
        face = Typeface.named(Prefs.values["font"] ?? "literata")
        size = min(max(CGFloat(Int(Prefs.values["size"] ?? "") ?? 19), 15), 28)
        customPointer = Prefs.values["pointer"] != "system"

        storage.addLayoutManager(manager)
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        manager.addTextContainer(container)
        textView = ReaderTextView(frame: NSRect(x: 0, y: 0, width: 760, height: 860), textContainer: container)

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 860), styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        super.init()

        window.title = "Sumi"
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 420, height: 360)
        window.titlebarAppearsTransparent = true
        window.tabbingMode = .disallowed
        window.acceptsMouseMovedEvents = true
        window.contentView = root
        root.reader = self
        root.wantsLayer = true
        root.registerForDraggedTypes([.fileURL])

        textView.reader = self
        textView.configure()
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.hasVerticalScroller = true
        scrollView.verticalScroller = scroller
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.horizontalScrollElasticity = .none
        scrollView.wantsLayer = true
        scrollView.documentView = textView
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(appResigned), name: NSApplication.didResignActiveNotification, object: nil)

        root.addSubview(scrollView)
        root.addSubview(welcome)
        root.addSubview(outline)
        root.addSubview(bar)
        root.addSubview(toast)
        root.addSubview(drop)
        root.layer?.addSublayer(pointer.ink)

        bar.contents.onClick = { [weak self] in self?.toggleOutline() }
        bar.type.onClick = { [weak self] in self?.toggleTypo() }
        bar.open.onClick = { [weak self] in self?.showOpenPanel() }
        welcome.button.onClick = { [weak self] in self?.showOpenPanel() }
        outline.list.onChoose = { [weak self] row in self?.chooseOutline(row) }
        images.onLoad = { [weak self] in self?.imagesArrived() }

        appearanceWatch = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { if self?.themeChoice == "auto" { self?.applyTheme() } }
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .leftMouseDown, .leftMouseUp, .rightMouseDown]) { [weak self] event in
            self?.pointerEvent(event)
            return event
        }

        applyTheme(animated: false)
        window.center()
        window.setFrameAutosaveName("Sumi")
        layoutChrome()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
        sendDocument(reload: false)
    }

    // ---------- Appearance ----------

    private var resolvedTheme: Theme {
        if themeChoice != "auto" { return Theme.named(themeChoice) }
        return NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
    }

    func applyTheme(animated: Bool = true) {
        let next = resolvedTheme
        let changed = next.id != theme.id
        theme = next
        window.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        window.backgroundColor = theme.bg
        animate(root.layer, "backgroundColor", to: theme.bg.cgColor, duration: animated ? 0.5 : 0)
        animate(bar.layer, "backgroundColor", to: theme.bg.cgColor, duration: animated ? 0.5 : 0)
        [bar.contents, bar.type, bar.open].forEach { $0.apply(theme) }
        welcome.theme = theme
        outline.apply(theme)
        toast.apply(theme)
        drop.apply(theme)
        scroller.knobColor = theme.faint
        if typoBuilt { typo.apply(theme) }
        manager.theme = theme
        textView.selectedTextAttributes = [.backgroundColor: theme.select]
        if changed, blocks != nil { rebuild() }
        welcome.needsLayout = true
        renderSwatches()
    }

    private func setTheme(_ id: String) {
        themeChoice = id
        Prefs.set("theme", id)
        applyTheme()
    }

    func cycleTheme() {
        let i = Reader.themes.firstIndex(of: themeChoice) ?? 0
        setTheme(Reader.themes[(i + 1) % Reader.themes.count])
    }

    private func renderSwatches() {
        guard typoBuilt else { return }
        typo.swatches.forEach { $0.isChosen = $0.id == themeChoice }
    }

    // ---------- Typefaces and size ----------

    private func setFont(_ id: String) {
        face = Typeface.named(id)
        Prefs.set("font", face.id)
        if typoBuilt { typo.fontRows.forEach { $0.isChosen = $0.face.id == face.id } }
        columnKey = -1
        rebuild()
        layoutChrome()
    }

    func cycleFont() {
        let all = Typeface.all
        let i = all.firstIndex { $0.id == face.id } ?? 0
        setFont(all[(i + 1) % all.count].id)
    }

    func stepSize(_ dir: Int) {
        var i = Reader.sizes.firstIndex(of: size) ?? ((Reader.sizes.firstIndex { $0 > size } ?? Reader.sizes.count) - 1)
        i = min(max(i + dir, 0), Reader.sizes.count - 1)
        guard Reader.sizes[i] != size else { return }
        size = Reader.sizes[i]
        Prefs.set("size", String(Int(size)))
        columnKey = -1
        rebuild()
        layoutChrome()
    }

    func resetSize() {
        size = 19
        Prefs.set("size", "19")
        columnKey = -1
        rebuild()
        layoutChrome()
    }

    // ---------- Aa panel ----------

    private func makeTypoPanel() -> TypoPanel {
        let panel = TypoPanel(frame: .zero)
        root.addSubview(panel, positioned: .below, relativeTo: toast)
        typoBuilt = true
        panel.smaller.onClick = { [weak self] in self?.stepSize(-1) }
        panel.larger.onClick = { [weak self] in self?.stepSize(1) }
        panel.swatches.forEach { swatch in
            swatch.onClick = { [weak self] in self?.setTheme(swatch.id) }
            swatch.isChosen = swatch.id == themeChoice
        }
        panel.fontRows.forEach { row in
            row.onClick = { [weak self] in self?.setFont(row.face.id) }
            row.isChosen = row.face.id == face.id
            row.onArrow = { [weak panel, weak row] delta in
                if let row = row { panel?.moveFocus(from: row, by: delta) }
            }
        }
        panel.toggle.isOn = customPointer
        panel.toggle.onClick = { [weak self, weak panel] in
            guard let self = self else { return }
            self.customPointer.toggle()
            Prefs.set("pointer", self.customPointer ? "sumi" : "system")
            panel?.toggle.isOn = self.customPointer
        }
        panel.apply(theme)
        panel.fit(in: root.bounds)
        panel.layer?.sublayerTransform = CATransform3DMakeTranslation(0, -4, 0)
        return panel
    }

    private var typoOpen: Bool { typoBuilt && typo.isOpen }

    func toggleTypo(_ force: Bool? = nil) {
        let open = force ?? !typoOpen
        if !open, !typoBuilt { return }
        typo.setOpen(open)
        bar.type.isExpanded = open
        if open { showBar() }
    }

    func dismissPanels(at event: NSEvent) {
        let point = root.convert(event.locationInWindow, from: nil)
        if typoOpen, !typo.frame.contains(point), !bar.type.frame.offsetBy(dx: bar.frame.minX, dy: bar.frame.minY).contains(point) {
            toggleTypo(false)
        }
        if tocOpen, isNarrow, !outline.frame.contains(point), !bar.contents.frame.offsetBy(dx: bar.frame.minX, dy: bar.frame.minY).contains(point) {
            toggleOutline(false, remember: false)
        }
    }

    func escape() {
        if typoOpen { toggleTypo(false) } else if tocOpen, isNarrow { toggleOutline(false, remember: false) }
    }

    // ---------- Layout ----------

    private var isNarrow: Bool { root.bounds.width < 760 }
    private var scrollerLeft: CGFloat { tocOpen && tocShift ? 28 + 200 + 16 : 0 }

    private var columnMax: CGFloat { (size * face.scale * face.measure + 64).rounded(.down) }

    func layoutChrome() {
        let bounds = root.bounds
        guard bounds.width > 0 else { return }
        layoutOutline()
        scrollView.frame = NSRect(x: scrollerLeft, y: 0, width: bounds.width - scrollerLeft, height: bounds.height)
        welcome.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height)
        bar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 44)
        drop.frame = bounds
        outline.place(in: bounds, overlay: tocOverlay)
        if typoBuilt { typo.fit(in: bounds) }
        layoutColumn()
    }

    // The outline sits flush left. The column stays centred unless the outline would crowd it, when the page steps aside just enough.
    private func layoutOutline() {
        let width = root.bounds.width
        let overlay = width < 760
        let column = min(width, columnMax)
        let textLeft = (width - column) / 2 + 32
        let fits = !overlay && textLeft >= 28 + 200 + 48
        tocOverlay = overlay
        tocShift = !overlay && !fits
    }

    private var currentTextWidth: CGFloat {
        let padding: CGFloat = root.bounds.width <= 720 ? 22 : 32
        return max(min(scrollView.contentSize.width, columnMax) - 2 * padding, 40)
    }

    private func layoutColumn() {
        let viewWidth = scrollView.contentSize.width
        let padding: CGFloat = root.bounds.width <= 720 ? 22 : 32
        let column = min(viewWidth, columnMax)
        let textWidth = currentTextWidth
        // Tables are measured for the width they're given, so a table that's short of room is rebuilt when that changes.
        let tablesNeedRebuild = textWidth != columnKey && columnKey > 0 && (built?.widestTable ?? 0) > min(textWidth, columnKey)
        textView.columnLeft = ((viewWidth - column) / 2 + padding).rounded()
        textView.topInset = root.bounds.width <= 720 ? 76 : 92
        let bottom: CGFloat = root.bounds.width <= 720 ? 120 : 160
        if textWidth != columnKey {
            columnKey = textWidth
            manager.columnWidth = textWidth
            container.size = NSSize(width: textWidth, height: .greatestFiniteMagnitude)
            headingTops = nil
            for box in manager.boxes where box.kind == .code {
                box.contentWidth = 0
                manager.measure(box)
                box.scrollX = min(box.scrollX, max(0, box.contentWidth - textWidth + box.left + box.right))
            }
        }
        if tablesNeedRebuild {
            rebuild()
            return
        }
        resizeDocument(bottom: bottom)
        textView.needsDisplay = true
    }

    private func resizeDocument(bottom: CGFloat? = nil) {
        let extra = bottom ?? (root.bounds.width <= 720 ? 120 : 160)
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container).height
        let height = max(textView.topInset + used + (built?.trailingMargin ?? 0) + extra, scrollView.contentSize.height)
        textView.frame = NSRect(x: 0, y: 0, width: scrollView.contentSize.width, height: height)
    }

    // ---------- Rendering ----------

    private func buildStyle(theme: Theme, size: CGFloat, face: Typeface) -> BuildStyle {
        BuildStyle(theme: theme, face: face, size: size, openDetails: openDetails, images: images, columnWidth: columnKey > 0 ? columnKey : currentTextWidth)
    }

    // Lays the text out again with the current settings, keeping the reader's place on the page.
    private func rebuild(keepingScroll fixedY: CGFloat? = nil, keepingPlace: Bool = true) {
        guard let blocks = blocks else { return }
        let anchor = keepingPlace && fixedY == nil ? topCharacter() : nil
        let selected = textView.selectedRange()
        let offsets = manager.boxes.filter { $0.kind == .code }.map { $0.scrollX }

        let doc = DocumentBuilder.build(blocks, style: buildStyle(theme: theme, size: size, face: face))
        built = doc
        storage.setAttributedString(doc.text)
        manager.boxes = doc.boxes
        for (box, offset) in zip(doc.boxes.filter { $0.kind == .code }, offsets) { box.scrollX = offset }
        columnKey = -1
        headingTops = nil
        refreshOutlineRows()
        layoutColumn()
        for box in doc.boxes where box.kind == .code { manager.measure(box) }
        if NSMaxRange(selected) <= storage.length { textView.setSelectedRange(selected) }
        if let y = fixedY {
            setScrollY(y)
        } else if let anchor = anchor {
            setScrollY(y(ofCharacter: anchor.index) - anchor.offset)
        }
        textView.needsDisplay = true
        textView.updateHover(at: nil)
    }

    private func topCharacter() -> (index: Int, offset: CGFloat)? {
        guard storage.length > 0, scrollY > 0 else { return nil }
        let point = NSPoint(x: 0, y: scrollY - textView.topInset + 1)
        let glyph = manager.glyphIndex(for: point, in: container)
        let index = manager.characterIndexForGlyph(at: glyph)
        return (index, y(ofCharacter: index) - scrollY)
    }

    private func y(ofCharacter index: Int) -> CGFloat {
        guard storage.length > 0 else { return 0 }
        let glyph = manager.glyphIndexForCharacter(at: min(index, storage.length - 1))
        return manager.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil).minY + textView.topInset
    }

    private func imagesArrived() {
        storage.edited(.editedAttributes, range: NSRange(location: 0, length: storage.length), changeInLength: 0)
        manager.invalidateLayout(forCharacterRange: NSRange(location: 0, length: storage.length), actualCharacterRange: nil)
        resizeDocument()
        headingTops = nil
        textView.needsDisplay = true
    }

    private func render(name: String, markdown: String, reload: Bool) {
        let keep = reload ? scrollY : 0
        let first = blocks == nil
        openDetails = []
        images.reset()
        images.folder = fileURL?.deletingLastPathComponent()
        blocks = Markdown.parse(markdown)
        manager.boxes = []
        rebuild(keepingScroll: keep, keepingPlace: false)
        if !reload { textView.setSelectedRange(NSRange(location: 0, length: 0)) }

        welcome.isHidden = true
        window.title = name
        if first, Prefs.values["toc"] == "1", !isNarrow { toggleOutline(true, remember: false) }
        if !reload {
            animate(scrollView.layer, "opacity", to: Float(1), duration: 0)
            if !Motion.reduced {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0
                fade.toValue = 1
                fade.duration = 0.35
                fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
                scrollView.layer?.add(fade, forKey: "appear")
            }
            showBar()
        }
        onScroll()
    }

    func toggleDetails(_ index: Int) {
        if openDetails.contains(index) { openDetails.remove(index) } else { openDetails.insert(index) }
        rebuild(keepingScroll: scrollY)
    }

    // ---------- Scrolling ----------

    private var scrollY: CGFloat { scrollView.contentView.bounds.minY }

    private func setScrollY(_ y: CGFloat) {
        let limit = max(0, textView.frame.height - scrollView.contentSize.height)
        scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: min(max(y, 0), limit)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func smoothScroll(to y: CGFloat) {
        let limit = max(0, textView.frame.height - scrollView.contentSize.height)
        let target = NSPoint(x: 0, y: min(max(y, 0), limit))
        if Motion.reduced {
            setScrollY(target.y)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.32
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            scrollView.contentView.animator().setBoundsOrigin(target)
        }
    }

    func scrollPage(_ dir: CGFloat) { smoothScroll(to: scrollY + dir * scrollView.contentSize.height * 0.85) }
    func scrollBy(_ delta: CGFloat) { smoothScroll(to: scrollY + delta) }
    func scrollToEnd(top: Bool) { smoothScroll(to: top ? 0 : textView.frame.height) }

    @objc private func appResigned() { pointerLeft() }

    @objc private func scrolled() {
        onScroll()
        if let point = lastPoint { updatePointer(at: point) }
    }

    private func onScroll() {
        let y = scrollY
        if y < 40 || y < lastY - 6 { showBar() } else if y > lastY + 4 { hideBar() }
        lastY = y
        markActiveHeading()
    }

    private func showBar() {
        guard bar.isDimmed else { return }
        bar.isDimmed = false
        animate(bar.layer, "opacity", to: Float(1), duration: 0.3)
    }

    private func hideBar() {
        guard !tocOpen, !typoOpen, blocks != nil, !bar.isDimmed else { return }
        bar.isDimmed = true
        animate(bar.layer, "opacity", to: Float(0), duration: 0.3)
    }

    // ---------- Outline ----------

    private func refreshOutlineRows() {
        guard let doc = built else { return }
        var heads = doc.headings.filter { $0.level <= 4 }
        if doc.firstIsSoleH1, let first = heads.first, first.level == 1 { heads.removeFirst() }
        let top = heads.map { $0.level }.min() ?? 1
        outlineRows = heads.map { OutlineRow(title: $0.title, depth: min($0.level - top + 1, 3), location: $0.location) }
        outline.list.emptyText = heads.isEmpty ? "This document has no headings." : nil
        outline.list.rows = outlineRows
        outline.place(in: root.bounds, overlay: tocOverlay)
    }

    func toggleOutline(_ force: Bool? = nil, remember: Bool = true) {
        let open = force ?? !tocOpen
        if open, blocks == nil { return }
        guard open != tocOpen else { return }
        tocOpen = open
        layoutOutline()
        outline.place(in: root.bounds, overlay: tocOverlay)
        outline.setOpen(open)
        bar.contents.isExpanded = open
        if remember, !isNarrow { Prefs.set("toc", open ? "1" : "0") }
        if open {
            showBar()
            markActiveHeading()
        }
        slideScroller()
    }

    // The page settles in its new place at once, then glides there on the compositor, so nothing is laid out while it moves.
    private func slideScroller() {
        let bounds = root.bounds
        let target = NSRect(x: scrollerLeft, y: 0, width: bounds.width - scrollerLeft, height: bounds.height)
        guard scrollView.frame != target else { return }
        let before = scrollView.frame.minX + textView.columnLeft
        scrollView.frame = target
        layoutColumn()
        let shift = before - (scrollView.frame.minX + textView.columnLeft)
        guard !Motion.reduced, shift != 0, let layer = scrollView.layer else { return }
        let glide = CABasicAnimation(keyPath: "transform.translation.x")
        glide.fromValue = shift
        glide.toValue = 0
        glide.duration = 0.25
        glide.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 0.7, 0.2, 1)
        layer.add(glide, forKey: "glide")
    }

    private func chooseOutline(_ row: OutlineRow) {
        smoothScroll(to: y(ofCharacter: row.location) - 80)
        if isNarrow {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.toggleOutline(false, remember: false) }
        }
    }

    private func markActiveHeading() {
        guard tocOpen, !outlineRows.isEmpty else { return }
        if headingTops == nil { headingTops = outlineRows.map { y(ofCharacter: $0.location) } }
        guard let tops = headingTops else { return }
        var current: Int?
        for (index, top) in tops.enumerated() where top - scrollY < 100 { current = index }
        if outline.list.active != current {
            outline.list.active = current
            if let current = current { outline.reveal(row: current) }
        }
    }

    // ---------- Pointer ----------

    private func pointerEvent(_ event: NSEvent) {
        guard event.window === window else {
            if lastPoint != nil, event.type == .mouseMoved { pointerLeft() }
            return
        }
        let point = root.convert(event.locationInWindow, from: nil)
        switch event.type {
        case .leftMouseDown:
            dismissPanels(at: event)
            if case .bar = pointer.shape { selectingWithBar = true }
            pointer.setDown(true)
        case .leftMouseUp:
            selectingWithBar = false
            pointer.setDown(false)
        default: break
        }
        // Around the window's edge the system shows its own resize cursors.
        guard root.bounds.insetBy(dx: 3, dy: 0).contains(point), point.y >= 0, point.y < root.bounds.height - 3 else {
            pointerLeft()
            return
        }
        lastPoint = point
        pointer.move(to: point)
        updatePointer(at: point)
        if event.type == .mouseMoved || event.type == .leftMouseDragged { barFollowsMouse(point) }
    }

    private var selectingWithBar = false

    private func barFollowsMouse(_ point: NSPoint) {
        if point.y < 64 {
            showBar()
            barTimer?.invalidate()
        } else if scrollY > 40, !bar.frame.contains(point) {
            barTimer?.invalidate()
            barTimer = Timer.scheduledTimer(withTimeInterval: 1.4, repeats: false) { [weak self] _ in self?.hideBar() }
        }
    }

    // hide() and unhide() have to balance, so only this touches them.
    private var systemCursorHidden = false
    private func setSystemCursorHidden(_ hidden: Bool) {
        guard hidden != systemCursorHidden else { return }
        systemCursorHidden = hidden
        if hidden { NSCursor.hide() } else { NSCursor.unhide() }
    }

    func pointerLeft() {
        setSystemCursorHidden(false)
        lastPoint = nil
        pointer.setAway(true)
        setHot(nil)
        setHoveredLink(nil)
        textView.updateHover(at: nil)
    }

    private func setHot(_ control: ChromeControl?) {
        guard hotControl !== control else { return }
        hotControl?.isHot = false
        hotControl = control
        control?.isHot = true
    }

    private func updatePointer(at point: NSPoint) {
        let hit = root.hitTest(root.convert(point, to: root.superview)) // hitTest takes its superview's coordinates
        var control: ChromeControl?
        var view = hit
        while let current = view, current !== root {
            if let found = current as? ChromeControl { control = found; break }
            view = current.superview
        }
        setHot(control)

        var shape = PointerLayer.Shape.dot
        var snapY: CGFloat?
        var isLink = false
        let selecting = textView.isSelecting || selectingWithBar

        if control === outline.list {
            let local = outline.list.convert(point, from: root)
            outline.list.hovered = outline.list.row(at: local)
        }
        if let control = control, !selecting {
            if control === outline.list, outline.list.hovered == nil, !outlineRows.isEmpty { setHot(nil) } else { shape = .hover }
            setHoveredLink(nil)
            textView.updateHover(at: control is CopyButton ? textView.convert(point, from: root) : nil)
        } else if hit === textView || hit?.isDescendant(of: scrollView) == true {
            let local = textView.convert(point, from: root)
            textView.updateHover(at: local)
            setHoveredLink(selecting ? nil : textView.link(at: local)?.range)
            switch textView.pointerShape(at: local, selecting: selecting) {
            case .clickable:
                shape = .hover
                isLink = textView.link(at: local) != nil
            case .text(let center, let height):
                let value = min(max(height, 14), 72).rounded()
                shape = .bar(value)
                snapY = (root.convert(NSPoint(x: 0, y: center), from: textView).y).rounded()
            case .plain: break
            }
        } else if !welcome.isHidden, welcome.textRects.contains(where: { $0.contains(welcome.convert(point, from: root)) }) {
            let rect = welcome.textRects.first { $0.contains(welcome.convert(point, from: root)) }!
            shape = .bar(max(rect.height, 14).rounded())
            snapY = rect.midY.rounded()
        }

        // Dragging a selection keeps the bar, and it follows the mouse when past the end of a line.
        if selecting, case .bar = pointer.shape {
            if case .bar = shape {} else { shape = pointer.shape }
        }
        let onScroller = customPointer && scroller.isEnabled && scroller.frame.width > 0 && !scroller.isHidden
            && point.x > scrollView.frame.maxX - 2 && hit?.isDescendant(of: scrollView) == true

        pointer.ink.isHidden = !customPointer
        if customPointer {
            pointer.set(shape)
            pointer.setAway(onScroller)
            if let y = snapY { pointer.move(to: CGPoint(x: point.x, y: y)) }
            setSystemCursorHidden(!onScroller)
            if !onScroller { blankCursor.set() } else { NSCursor.arrow.set() }
        } else {
            setSystemCursorHidden(false)
            (isLink ? NSCursor.pointingHand : NSCursor.arrow).set()
        }
    }

    // The link under the pointer deepens its underline over a fifth of a second.
    private func setHoveredLink(_ range: NSRange?) {
        guard range != hoveredLink else { return }
        let old = hoveredLink
        hoveredLink = range
        linkAnimation?.invalidate()
        if let old = old { redraw(characters: old) }
        manager.hoveredLink = range
        manager.linkFade = 0
        guard let range = range else { return }
        if Motion.reduced {
            manager.linkFade = 1
            redraw(characters: range)
            return
        }
        let start = CACurrentMediaTime()
        linkAnimation = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self = self else { return timer.invalidate() }
            let t = min((CACurrentMediaTime() - start) / 0.2, 1)
            self.manager.linkFade = CGFloat(t)
            self.redraw(characters: range)
            if t >= 1 { timer.invalidate() }
        }
    }

    private func redraw(characters range: NSRange) {
        guard NSMaxRange(range) <= storage.length else { return }
        let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let rect = manager.boundingRect(forGlyphRange: glyphs, in: container)
        textView.setNeedsDisplay(rect.offsetBy(dx: textView.columnLeft, dy: textView.topInset).insetBy(dx: -2, dy: -4))
    }

    // ---------- Documents ----------

    func open(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        fileURL = url
        sendDocument(reload: false)
    }

    private func sendDocument(reload: Bool) {
        guard let url = fileURL else { return }
        guard let data = try? Data(contentsOf: url) else {
            if !reload {
                toast.show("Couldn’t open that file.", in: root.bounds)
            } else if reloadRetries < 10 {
                // An editor may be halfway through replacing the file.
                reloadRetries += 1
                scheduleReload(after: 0.2)
            }
            return
        }
        reloadRetries = 0
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        window.title = url.lastPathComponent
        window.representedURL = url
        render(name: url.lastPathComponent, markdown: text, reload: reload)
        watch(url)
    }

    private func scheduleReload(after delay: TimeInterval) {
        reloadWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.sendDocument(reload: true) }
        reloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // Editors often replace a file when saving, so the watch is re-made after every change.
    private func watch(_ url: URL) {
        watcher?.cancel()
        let fd = Darwin.open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self] in self?.scheduleReload(after: 0.18) }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = (Array(markdownExtensions) + ["txt"]).compactMap { UTType(filenameExtension: $0) }
        panel.directoryURL = fileURL?.deletingLastPathComponent()
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK, let url = panel.url { self?.open(url) }
        }
    }

    func follow(_ href: String) {
        if href.hasPrefix("#") {
            let wanted = (String(href.dropFirst()).removingPercentEncoding ?? String(href.dropFirst()))
            if let heading = built?.headings.first(where: { $0.id == wanted }) {
                smoothScroll(to: y(ofCharacter: heading.location) - 80)
            }
            return
        }
        if isRelativeReference(href) {
            guard let target = resolveInFolder(href, folder: fileURL?.deletingLastPathComponent()),
                  FileManager.default.fileExists(atPath: target.path) else {
                toast.show("File not found", in: root.bounds)
                return
            }
            if markdownExtensions.contains(target.pathExtension.lowercased()) { open(target) } else { NSWorkspace.shared.open(target) }
            return
        }
        if let url = URL(string: href), ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
            NSWorkspace.shared.open(url)
        }
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
        let string = storage.string as NSString
        let selected = textView.selectedRange()
        let options: NSString.CompareOptions = backwards ? [.caseInsensitive, .backwards] : [.caseInsensitive]
        let after = NSMaxRange(selected)
        let first = backwards
            ? NSRange(location: 0, length: selected.location)
            : NSRange(location: after, length: string.length - after)
        var found = string.range(of: text, options: options, range: first)
        if found.location == NSNotFound {
            found = string.range(of: text, options: options, range: NSRange(location: 0, length: string.length)) // wraps around
        }
        guard found.location != NSNotFound else { return }
        textView.setSelectedRange(found)
        textView.reveal(found)
    }

    @objc private func findChanged() {
        // Typing refines the same match rather than running on to the next one.
        let selected = textView.selectedRange()
        textView.setSelectedRange(NSRange(location: selected.location, length: 0))
        find(backwards: false)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            find(backwards: NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false)
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            findBar?.isHidden = true
            window.makeFirstResponder(self.textView)
            return true
        }
        return false
    }

    // ---------- Printing ----------

    // Print is laid out afresh on white paper, with no chrome, using the full width of the page.
    func print() {
        printOperation()?.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    func printOperation() -> NSPrintOperation? {
        guard let blocks = blocks else { return nil }
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.horizontalPagination = .fit
        info.isHorizontallyCentered = false
        let width = info.paperSize.width - info.leftMargin - info.rightMargin

        let doc = DocumentBuilder.build(blocks, style: BuildStyle(theme: .light, face: face, size: size, openDetails: openDetails, images: images, columnWidth: width))
        let printStorage = NSTextStorage(attributedString: doc.text)
        let layout = ReaderLayoutManager()
        layout.theme = .light
        layout.boxes = doc.boxes
        layout.columnWidth = width
        layout.allowsNonContiguousLayout = false
        printStorage.addLayoutManager(layout)
        let printContainer = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        printContainer.lineFragmentPadding = 0
        layout.addTextContainer(printContainer)
        let view = ReaderTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100), textContainer: printContainer)
        view.configure()
        view.topInset = 0
        layout.ensureLayout(for: printContainer)
        view.frame.size.height = layout.usedRect(for: printContainer).height
        return NSPrintOperation(view: view, printInfo: info)
    }

    func windowWillClose(_ notification: Notification) {
        setSystemCursorHidden(false)
        watcher?.cancel()
        if let monitor = monitor { NSEvent.removeMonitor(monitor) }
        NotificationCenter.default.removeObserver(self)
        onClose?(self)
    }
}
