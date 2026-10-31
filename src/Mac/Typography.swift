// Themes and typefaces: the same values the Windows reader keeps in style.css and fonts.css.
import AppKit
import CoreText

extension NSColor {
    convenience init(hex: String) {
        let value = Int(hex.trimmingCharacters(in: CharacterSet(charactersIn: "# ")), radix: 16) ?? 0xfaf8f4
        self.init(srgbRed: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255,
                  blue: CGFloat(value & 255) / 255, alpha: 1)
    }

    convenience init(_ red: Int, _ green: Int, _ blue: Int, _ alpha: CGFloat) {
        self.init(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: alpha)
    }

    func withOpacity(_ alpha: CGFloat) -> NSColor { withAlphaComponent(alpha) }
}

struct Theme {
    let id: String
    let isDark: Bool
    let bg, ink, inkSoft, muted, faint, rule, accent, codeBg, select, ink3, hover, edge, popBg: NSColor
    let bgHex: String
    let shadowOpacity: Float, shadowRadius: CGFloat, shadowOffset: CGFloat

    static let light = Theme(
        id: "light", isDark: false,
        bg: NSColor(hex: "#faf8f4"), ink: NSColor(hex: "#2c2b28"), inkSoft: NSColor(hex: "#4a4842"), muted: NSColor(hex: "#9a958b"),
        faint: NSColor(hex: "#c9c3b8"), rule: NSColor(hex: "#e9e4da"), accent: NSColor(hex: "#8a6a45"), codeBg: NSColor(hex: "#f2eee6"),
        select: NSColor(170, 140, 90, 0.22), ink3: NSColor(hex: "#6f6b62"), hover: NSColor(60, 50, 30, 0.07), edge: NSColor(60, 50, 30, 0.14),
        popBg: NSColor(hex: "#fdfcf9"), bgHex: "#faf8f4", shadowOpacity: 0.08, shadowRadius: 10, shadowOffset: 6)
    static let sepia = Theme(
        id: "sepia", isDark: false,
        bg: NSColor(hex: "#f4ecdf"), ink: NSColor(hex: "#3a3227"), inkSoft: NSColor(hex: "#54493a"), muted: NSColor(hex: "#9b8d77"),
        faint: NSColor(hex: "#cfc1a8"), rule: NSColor(hex: "#e5d9c4"), accent: NSColor(hex: "#91683a"), codeBg: NSColor(hex: "#ebe1cf"),
        select: NSColor(160, 120, 60, 0.22), ink3: NSColor(hex: "#74685a"), hover: NSColor(80, 55, 20, 0.08), edge: NSColor(80, 55, 20, 0.16),
        popBg: NSColor(hex: "#f8f1e6"), bgHex: "#f4ecdf", shadowOpacity: 0.1, shadowRadius: 10, shadowOffset: 6)
    static let dark = Theme(
        id: "dark", isDark: true,
        bg: NSColor(hex: "#1b1b1d"), ink: NSColor(hex: "#dcd8cf"), inkSoft: NSColor(hex: "#bdb9b0"), muted: NSColor(hex: "#7f7b74"),
        faint: NSColor(hex: "#4a4844"), rule: NSColor(hex: "#2d2c2b"), accent: NSColor(hex: "#cfae7e"), codeBg: NSColor(hex: "#232326"),
        select: NSColor(207, 174, 126, 0.22), ink3: NSColor(hex: "#a29e96"), hover: NSColor(255, 255, 255, 0.06), edge: NSColor(255, 255, 255, 0.1),
        popBg: NSColor(hex: "#242427"), bgHex: "#1b1b1d", shadowOpacity: 0.35, shadowRadius: 12, shadowOffset: 8)

    static func named(_ id: String) -> Theme { id == "sepia" ? .sepia : id == "dark" ? .dark : .light }
}

// One reading face, with its per-face tuning so every option reads at the same comfortable optical size.
struct Typeface {
    let id, name, kind, family: String
    var listSize: CGFloat = 16
    var listWeight: CGFloat = 400
    var scale: CGFloat = 1
    var lineHeight: CGFloat = 1.78
    var measure: CGFloat = 34
    var bodyWeight: CGFloat = 400
    var strongWeight: CGFloat = 620
    var h1Weight: CGFloat = 350
    var h2Weight: CGFloat = 450
    var hWeight: CGFloat = 500
    var numerals: String? = "onum"
    var ligatures = true

    static let all: [Typeface] = [
        Typeface(id: "literata", name: "Literata", kind: "Book serif", family: "literata"),
        Typeface(id: "newsreader", name: "Newsreader", kind: "Editorial", family: "newsreader", listWeight: 420, scale: 1.07, lineHeight: 1.7,
                 bodyWeight: 420, h1Weight: 400, h2Weight: 500, hWeight: 550),
        Typeface(id: "source-serif", name: "Source Serif", kind: "Crisp serif", family: "source-serif-4", scale: 1.02, lineHeight: 1.72,
                 h1Weight: 400, h2Weight: 500, hWeight: 560),
        Typeface(id: "garamond", name: "EB Garamond", kind: "Classic", family: "eb-garamond", listSize: 19, listWeight: 450, scale: 1.16, lineHeight: 1.66,
                 measure: 32, bodyWeight: 450, strongWeight: 640, h1Weight: 450, h2Weight: 500, hWeight: 560),
        Typeface(id: "lora", name: "Lora", kind: "Soft serif", family: "lora", lineHeight: 1.76, strongWeight: 640,
                 h1Weight: 450, h2Weight: 500, hWeight: 560, numerals: "lnum"),
        Typeface(id: "bitter", name: "Bitter", kind: "Slab", family: "bitter", lineHeight: 1.76, bodyWeight: 430, strongWeight: 650,
                 h1Weight: 400, h2Weight: 500, hWeight: 560, numerals: "lnum"),
        Typeface(id: "atkinson", name: "Atkinson Hyperlegible", kind: "Clearest", family: "atkinson-hyperlegible", listSize: 16, lineHeight: 1.72,
                 strongWeight: 700, h1Weight: 400, h2Weight: 400, hWeight: 700, numerals: nil),
        Typeface(id: "nunito", name: "Nunito", kind: "Rounded", family: "nunito", listWeight: 420, scale: 1.01, lineHeight: 1.74, bodyWeight: 420,
                 strongWeight: 700, h1Weight: 350, h2Weight: 600, hWeight: 650, numerals: nil),
        Typeface(id: "figtree", name: "Figtree", kind: "Clean sans", family: "figtree", lineHeight: 1.72, strongWeight: 640,
                 h1Weight: 400, h2Weight: 550, hWeight: 600, numerals: nil),
        Typeface(id: "plex-mono", name: "Plex Mono", kind: "Typewriter", family: "ibm-plex-mono", listSize: 15, scale: 0.9, lineHeight: 1.8, measure: 36,
                 strongWeight: 600, h1Weight: 400, h2Weight: 600, hWeight: 600, numerals: nil, ligatures: false),
    ]

    static func named(_ id: String) -> Typeface { all.first { $0.id == id } ?? all[0] }
}

// Fonts come straight from the bundled files, so nothing is installed and only the faces in use are ever read.
enum Fonts {
    private struct Key: Hashable {
        let family: String, weight: CGFloat, italic: Bool, size: CGFloat, features: [String]
    }
    private static var loaded: [String: CTFontDescriptor] = [:]
    private static var cache: [Key: NSFont] = [:]

    private static var folder: URL { Bundle.main.resourceURL!.appendingPathComponent("fonts", isDirectory: true) }

    private static func descriptor(_ file: String) -> CTFontDescriptor? {
        if let known = loaded[file] { return known }
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(file + ".woff2")) as CFData,
              let all = CTFontManagerCreateFontDescriptorsFromData(data) as? [CTFontDescriptor], let first = all.first else { return nil }
        // Files holding several named instances list the lightest first; the wght axis below sets the real weight.
        loaded[file] = first
        return first
    }

    // Which file holds this family, weight and style. Static families pick their nearest weight, as a browser would.
    private static func file(_ family: String, weight: CGFloat, italic: Bool) -> (name: String, variable: Bool) {
        let style = italic ? "italic" : "normal"
        switch family {
        case "atkinson-hyperlegible":
            return ("atkinson-hyperlegible-latin-\(weight >= 550 ? 700 : 400)-\(style)", false)
        case "ibm-plex-mono":
            if italic { return ("ibm-plex-mono-latin-400-italic", false) }
            return ("ibm-plex-mono-latin-\(weight >= 500 ? 600 : 400)-normal", false)
        default:
            return ("\(family)-latin-wght-\(style)", true)
        }
    }

    static func font(_ family: String, weight: CGFloat = 400, italic: Bool = false, size: CGFloat, features: [String] = []) -> NSFont {
        let key = Key(family: family, weight: weight, italic: italic, size: size, features: features)
        if let known = cache[key] { return known }
        let (name, variable) = file(family, weight: weight, italic: italic)
        guard var base = descriptor(name) else { return .systemFont(ofSize: size) }
        if variable {
            base = CTFontDescriptorCreateCopyWithVariation(base, NSNumber(value: 0x77676874 /* wght */), weight)
        }
        var attributes: [CFString: Any] = [:]
        if !features.isEmpty {
            attributes[kCTFontFeatureSettingsAttribute] = features.map {
                [kCTFontOpenTypeFeatureTag: String($0.prefix(4)), kCTFontOpenTypeFeatureValue: $0.hasSuffix("=0") ? 0 : 1] as [CFString: Any]
            }
        }
        // Latin subsets only: anything outside falls back to Literata, which carries Latin Extended.
        var cascade: [CTFontDescriptor] = []
        let style = italic ? "italic" : "normal"
        if let ext = descriptor("literata-latin-ext-wght-\(style)") {
            cascade.append(CTFontDescriptorCreateCopyWithVariation(ext, NSNumber(value: 0x77676874), min(max(weight, 200), 900)))
        }
        if family != "literata", ["newsreader", "source-serif-4", "eb-garamond", "lora", "bitter"].contains(family),
           let main = descriptor("literata-latin-wght-\(style)") {
            cascade.insert(CTFontDescriptorCreateCopyWithVariation(main, NSNumber(value: 0x77676874), min(max(weight, 200), 900)), at: 0)
        }
        if !cascade.isEmpty { attributes[kCTFontCascadeListAttribute] = cascade }
        let described = CTFontDescriptorCreateCopyWithAttributes(base, attributes as CFDictionary)
        let font = CTFontCreateWithFontDescriptor(described, size, nil) as NSFont
        cache[key] = font
        return font
    }

    static func mono(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        .monospacedSystemFont(ofSize: size, weight: weight)
    }

    static func ui(_ size: CGFloat) -> NSFont { .systemFont(ofSize: size) }
}

// Durations in one place, so Reduce Motion can switch them all off.
enum Motion {
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static func duration(_ seconds: TimeInterval) -> TimeInterval { reduced ? 0 : seconds }
}
