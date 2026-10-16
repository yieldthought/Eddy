import AppKit
import SwiftUI

extension NSColor {
    static func hex(_ value: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((value >> 16) & 0xff) / 255,
            green: CGFloat((value >> 8) & 0xff) / 255,
            blue: CGFloat(value & 0xff) / 255,
            alpha: alpha
        )
    }

    /// CSS-style HSL (hue in degrees, saturation and lightness in 0...1).
    static func hsl(_ hue: CGFloat, _ saturation: CGFloat, _ lightness: CGFloat) -> NSColor {
        let c = (1 - abs(2 * lightness - 1)) * saturation
        let h = hue / 60
        let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
        let (r, g, b): (CGFloat, CGFloat, CGFloat)
        switch h {
        case 0..<1: (r, g, b) = (c, x, 0)
        case 1..<2: (r, g, b) = (x, c, 0)
        case 2..<3: (r, g, b) = (0, c, x)
        case 3..<4: (r, g, b) = (0, x, c)
        case 4..<5: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        let m = lightness - c / 2
        return NSColor(srgbRed: r + m, green: g + m, blue: b + m, alpha: 1)
    }

    func blended(with other: NSColor, _ fraction: CGFloat) -> NSColor {
        let a = usingColorSpace(.sRGB) ?? self
        let b = other.usingColorSpace(.sRGB) ?? other
        return a.blended(withFraction: fraction, of: b) ?? self
    }
}

/// Same FNV-1a hash `flow chart` uses, so a state is the same colour in the
/// editor and in the rendered chart.
func flowStateHue(_ name: String) -> CGFloat {
    var hash: UInt32 = 2_166_136_261
    for unit in name.utf16 {
        hash ^= UInt32(unit)
        hash = hash &* 16_777_619
    }
    return CGFloat(hash % 360)
}

struct Theme: Identifiable, Equatable {
    static func == (lhs: Theme, rhs: Theme) -> Bool { lhs.id == rhs.id }

    let id: String
    let name: String
    let isDark: Bool

    var background = NSColor.white
    /// Optional vertical gradient drawn behind the page (top, bottom).
    var gradient: (NSColor, NSColor)?
    /// Optional soft horizon glow rising from the bottom of the window.
    var glow: NSColor?

    var text = NSColor.black
    var muted = NSColor.gray
    var key = NSColor.black
    var flowKey = NSColor.black
    var argKey = NSColor.black
    var value = NSColor.black
    var string = NSColor.black
    var number = NSColor.black
    var constant = NSColor.black
    var indicator = NSColor.gray
    var template = NSColor.black
    var templateFill: NSColor?
    var code = NSColor.black
    var codeFill: NSColor?
    var heading = NSColor.black
    var link = NSColor.blue
    var error = NSColor.red
    var condition = NSColor.black

    var selection = NSColor.selectedTextBackgroundColor
    var caret = NSColor.black
    var currentLine = NSColor.clear
    var guide = NSColor.clear
    /// Laid over the system sidebar glass, which otherwise picks up the desktop.
    var sidebarTint: NSColor?

    /// HSL saturation/lightness for per-state colours.
    var stateSaturation: CGFloat = 0.5
    var stateLightness: CGFloat = 0.44
    /// Neon glow on state headers.
    var neon = false
    var italicComments = true

    init(id: String, name: String, isDark: Bool) {
        self.id = id
        self.name = name
        self.isDark = isDark
        stateSaturation = isDark ? 0.58 : 0.50
        stateLightness = isDark ? 0.72 : 0.44
    }

    func stateColor(_ name: String) -> NSColor {
        .hsl(flowStateHue(name), stateSaturation, stateLightness)
    }

    /// Representative colour for the middle of the page; used when dimming.
    var midBackground: NSColor {
        guard let (top, bottom) = gradient else { return background }
        return top.blended(with: bottom, 0.5)
    }

    var swiftUIBackground: Color { Color(nsColor: background) }
}

extension Theme {
    static let all: [Theme] = [
        .paper, .solarizedLight, .githubLight, .catppuccinLatte,
        .synthwave, .ink, .nord, .dracula, .solarizedDark, .githubDark, .catppuccinMocha,
    ]

    static func named(_ id: String) -> Theme? { all.first { $0.id == id } }

    static var light: [Theme] { all.filter { !$0.isDark } }
    static var dark: [Theme] { all.filter { $0.isDark } }

    // MARK: Light

    static let paper: Theme = {
        var t = Theme(id: "paper", name: "Paper", isDark: false)
        t.background = .hex(0xF7F5EF)
        t.text = .hex(0x37352F)
        t.muted = .hex(0xA9A496)
        t.key = .hex(0x56677F)
        t.flowKey = .hex(0x37352F)
        t.argKey = .hex(0x2E8A87)
        t.value = .hex(0x4A4740)
        t.string = .hex(0x6F8443)
        t.number = .hex(0xB86F35)
        t.constant = .hex(0x96588A)
        t.indicator = .hex(0xBFA987)
        t.template = .hex(0x2E8A87)
        t.templateFill = .hex(0x2E8A87, 0.10)
        t.code = .hex(0xA4564A)
        t.codeFill = .hex(0xA4564A, 0.07)
        t.heading = .hex(0x2B2924)
        t.link = .hex(0x4A73A8)
        t.error = .hex(0xD14D41)
        t.condition = .hex(0x6B665B)
        t.selection = .hex(0x56677F, 0.20)
        t.caret = .hex(0xE07A5F)
        t.currentLine = .hex(0x000000, 0.025)
        t.guide = .hex(0x000000, 0.065)
        return t
    }()

    static let solarizedLight: Theme = {
        var t = Theme(id: "solarized-light", name: "Solarized Light", isDark: false)
        t.background = .hex(0xFDF6E3)
        t.text = .hex(0x586E75)
        t.muted = .hex(0x93A1A1)
        t.key = .hex(0x268BD2)
        t.flowKey = .hex(0x073642)
        t.argKey = .hex(0xCB4B16)
        t.value = .hex(0x586E75)
        t.string = .hex(0x2AA198)
        t.number = .hex(0xD33682)
        t.constant = .hex(0x6C71C4)
        t.indicator = .hex(0xB58900)
        t.template = .hex(0xCB4B16)
        t.templateFill = .hex(0xCB4B16, 0.09)
        t.code = .hex(0x859900)
        t.codeFill = .hex(0x859900, 0.08)
        t.heading = .hex(0x073642)
        t.link = .hex(0x268BD2)
        t.error = .hex(0xDC322F)
        t.condition = .hex(0x657B83)
        t.selection = .hex(0xEEE8D5)
        t.caret = .hex(0xD33682)
        t.currentLine = .hex(0xEEE8D5, 0.55)
        t.guide = .hex(0x586E75, 0.12)
        return t
    }()

    static let githubLight: Theme = {
        var t = Theme(id: "github-light", name: "GitHub Light", isDark: false)
        t.background = .hex(0xFFFFFF)
        t.text = .hex(0x1F2328)
        t.muted = .hex(0x6E7781)
        t.key = .hex(0x116329)
        t.flowKey = .hex(0x1F2328)
        t.argKey = .hex(0x8250DF)
        t.value = .hex(0x0A3069)
        t.string = .hex(0x0A3069)
        t.number = .hex(0x0550AE)
        t.constant = .hex(0x0550AE)
        t.indicator = .hex(0xCF222E)
        t.template = .hex(0x8250DF)
        t.templateFill = .hex(0x8250DF, 0.08)
        t.code = .hex(0x953800)
        t.codeFill = .hex(0x818B98, 0.12)
        t.heading = .hex(0x0550AE)
        t.link = .hex(0x0969DA)
        t.error = .hex(0xCF222E)
        t.condition = .hex(0x1F2328)
        t.selection = .hex(0x54AEFF, 0.28)
        t.caret = .hex(0x0969DA)
        t.currentLine = .hex(0xF6F8FA)
        t.guide = .hex(0xD0D7DE, 0.7)
        return t
    }()

    static let catppuccinLatte: Theme = {
        var t = Theme(id: "catppuccin-latte", name: "Catppuccin Latte", isDark: false)
        t.background = .hex(0xEFF1F5)
        t.text = .hex(0x4C4F69)
        t.muted = .hex(0x9CA0B0)
        t.key = .hex(0x1E66F5)
        t.flowKey = .hex(0x8839EF)
        t.argKey = .hex(0xEA76CB)
        t.value = .hex(0x4C4F69)
        t.string = .hex(0x40A02B)
        t.number = .hex(0xFE640B)
        t.constant = .hex(0x8839EF)
        t.indicator = .hex(0x179299)
        t.template = .hex(0xEA76CB)
        t.templateFill = .hex(0xEA76CB, 0.12)
        t.code = .hex(0xD20F39)
        t.codeFill = .hex(0xD20F39, 0.06)
        t.heading = .hex(0x8839EF)
        t.link = .hex(0x209FB5)
        t.error = .hex(0xD20F39)
        t.condition = .hex(0x5C5F77)
        t.selection = .hex(0x7C7F93, 0.22)
        t.caret = .hex(0xDC8A78)
        t.currentLine = .hex(0xCCD0DA, 0.40)
        t.guide = .hex(0x4C4F69, 0.08)
        return t
    }()

    // MARK: Dark

    static let synthwave: Theme = {
        var t = Theme(id: "synthwave-pastel", name: "Synthwave Pastel", isDark: true)
        t.background = .hex(0x211D2C)
        t.gradient = (.hex(0x1C1927), .hex(0x272033))
        t.glow = .hex(0xFF8FCF, 0.09)
        t.text = .hex(0xE9E2FF)
        t.muted = .hex(0x8178A0)
        t.key = .hex(0x9DE7FF)
        t.flowKey = .hex(0xFFB3E6)
        t.argKey = .hex(0x7DF9E9)
        t.value = .hex(0xE6DCFF)
        t.string = .hex(0xB8F5D0)
        t.number = .hex(0xFFD3A5)
        t.constant = .hex(0xFFA8D8)
        t.indicator = .hex(0xC5A8FF)
        t.template = .hex(0x7DF9E9)
        t.templateFill = .hex(0x7DF9E9, 0.11)
        t.code = .hex(0xFFC7A8)
        t.codeFill = .hex(0xFFC7A8, 0.08)
        t.heading = .hex(0xFF9EDB)
        t.link = .hex(0x9DE7FF)
        t.error = .hex(0xFF6B8B)
        t.condition = .hex(0xD7CCF5)
        t.selection = .hex(0xC5A8FF, 0.26)
        t.caret = .hex(0xFF8FD8)
        t.currentLine = .hex(0xFF8FD8, 0.05)
        t.guide = .hex(0xC5A8FF, 0.10)
        t.stateSaturation = 0.92
        t.stateLightness = 0.80
        t.neon = true
        return t
    }()

    static let ink: Theme = {
        var t = Theme(id: "ink", name: "Ink", isDark: true)
        t.background = .hex(0x1C1B19)
        t.text = .hex(0xDAD4C6)
        t.muted = .hex(0x6F6A5F)
        t.key = .hex(0x93A8C4)
        t.flowKey = .hex(0xEDE7D8)
        t.argKey = .hex(0x6CC4C0)
        t.value = .hex(0xCFC9BA)
        t.string = .hex(0xAABC7E)
        t.number = .hex(0xE2A26B)
        t.constant = .hex(0xCB97C2)
        t.indicator = .hex(0x8A7F69)
        t.template = .hex(0x6CC4C0)
        t.templateFill = .hex(0x6CC4C0, 0.11)
        t.code = .hex(0xE39C8E)
        t.codeFill = .hex(0xE39C8E, 0.08)
        t.heading = .hex(0xF2ECDD)
        t.link = .hex(0x93A8C4)
        t.error = .hex(0xEA6A5E)
        t.condition = .hex(0xBDB6A6)
        t.selection = .hex(0x93A8C4, 0.26)
        t.caret = .hex(0xF2A65A)
        t.currentLine = .hex(0xFFFFFF, 0.03)
        t.guide = .hex(0xFFFFFF, 0.06)
        t.sidebarTint = .hex(0x161513, 0.92)
        return t
    }()

    static let nord: Theme = {
        var t = Theme(id: "nord", name: "Nord", isDark: true)
        t.background = .hex(0x2E3440)
        t.text = .hex(0xD8DEE9)
        t.muted = .hex(0x616E88)
        t.key = .hex(0x88C0D0)
        t.flowKey = .hex(0xECEFF4)
        t.argKey = .hex(0xEBCB8B)
        t.value = .hex(0xE5E9F0)
        t.string = .hex(0xA3BE8C)
        t.number = .hex(0xB48EAD)
        t.constant = .hex(0x81A1C1)
        t.indicator = .hex(0x81A1C1)
        t.template = .hex(0xEBCB8B)
        t.templateFill = .hex(0xEBCB8B, 0.10)
        t.code = .hex(0xD08770)
        t.codeFill = .hex(0xD08770, 0.09)
        t.heading = .hex(0x8FBCBB)
        t.link = .hex(0x88C0D0)
        t.error = .hex(0xBF616A)
        t.condition = .hex(0xD8DEE9)
        t.selection = .hex(0x434C5E)
        t.caret = .hex(0xD8DEE9)
        t.currentLine = .hex(0x3B4252, 0.55)
        t.guide = .hex(0xD8DEE9, 0.07)
        t.stateSaturation = 0.45
        t.stateLightness = 0.72
        return t
    }()

    static let dracula: Theme = {
        var t = Theme(id: "dracula", name: "Dracula", isDark: true)
        t.background = .hex(0x282A36)
        t.text = .hex(0xF8F8F2)
        t.muted = .hex(0x6272A4)
        t.key = .hex(0x8BE9FD)
        t.flowKey = .hex(0xFF79C6)
        t.argKey = .hex(0x50FA7B)
        t.value = .hex(0xF8F8F2)
        t.string = .hex(0xF1FA8C)
        t.number = .hex(0xBD93F9)
        t.constant = .hex(0xBD93F9)
        t.indicator = .hex(0xFF79C6)
        t.template = .hex(0x50FA7B)
        t.templateFill = .hex(0x50FA7B, 0.10)
        t.code = .hex(0xFFB86C)
        t.codeFill = .hex(0xFFB86C, 0.08)
        t.heading = .hex(0xFF79C6)
        t.link = .hex(0x8BE9FD)
        t.error = .hex(0xFF5555)
        t.condition = .hex(0xF8F8F2)
        t.selection = .hex(0x44475A)
        t.caret = .hex(0xF8F8F2)
        t.currentLine = .hex(0x44475A, 0.40)
        t.guide = .hex(0xF8F8F2, 0.07)
        t.stateSaturation = 0.75
        t.stateLightness = 0.75
        return t
    }()

    static let solarizedDark: Theme = {
        var t = Theme(id: "solarized-dark", name: "Solarized Dark", isDark: true)
        t.background = .hex(0x002B36)
        t.text = .hex(0x93A1A1)
        t.muted = .hex(0x586E75)
        t.key = .hex(0x268BD2)
        t.flowKey = .hex(0xEEE8D5)
        t.argKey = .hex(0xCB4B16)
        t.value = .hex(0x93A1A1)
        t.string = .hex(0x2AA198)
        t.number = .hex(0xD33682)
        t.constant = .hex(0x6C71C4)
        t.indicator = .hex(0xB58900)
        t.template = .hex(0xCB4B16)
        t.templateFill = .hex(0xCB4B16, 0.12)
        t.code = .hex(0x859900)
        t.codeFill = .hex(0x859900, 0.10)
        t.heading = .hex(0xEEE8D5)
        t.link = .hex(0x268BD2)
        t.error = .hex(0xDC322F)
        t.condition = .hex(0x93A1A1)
        t.selection = .hex(0x073642)
        t.caret = .hex(0x93A1A1)
        t.currentLine = .hex(0x073642, 0.6)
        t.guide = .hex(0x93A1A1, 0.10)
        return t
    }()

    static let githubDark: Theme = {
        var t = Theme(id: "github-dark", name: "GitHub Dark", isDark: true)
        t.background = .hex(0x0D1117)
        t.text = .hex(0xE6EDF3)
        t.muted = .hex(0x8B949E)
        t.key = .hex(0x7EE787)
        t.flowKey = .hex(0xE6EDF3)
        t.argKey = .hex(0xD2A8FF)
        t.value = .hex(0xA5D6FF)
        t.string = .hex(0xA5D6FF)
        t.number = .hex(0x79C0FF)
        t.constant = .hex(0x79C0FF)
        t.indicator = .hex(0xFF7B72)
        t.template = .hex(0xD2A8FF)
        t.templateFill = .hex(0xD2A8FF, 0.10)
        t.code = .hex(0xFFA657)
        t.codeFill = .hex(0x6E7681, 0.25)
        t.heading = .hex(0x79C0FF)
        t.link = .hex(0x58A6FF)
        t.error = .hex(0xF85149)
        t.condition = .hex(0xE6EDF3)
        t.selection = .hex(0x388BFD, 0.30)
        t.caret = .hex(0x58A6FF)
        t.currentLine = .hex(0x6E7681, 0.10)
        t.guide = .hex(0xF0F6FC, 0.06)
        return t
    }()

    static let catppuccinMocha: Theme = {
        var t = Theme(id: "catppuccin-mocha", name: "Catppuccin Mocha", isDark: true)
        t.background = .hex(0x1E1E2E)
        t.text = .hex(0xCDD6F4)
        t.muted = .hex(0x6C7086)
        t.key = .hex(0x89B4FA)
        t.flowKey = .hex(0xCBA6F7)
        t.argKey = .hex(0xF5C2E7)
        t.value = .hex(0xCDD6F4)
        t.string = .hex(0xA6E3A1)
        t.number = .hex(0xFAB387)
        t.constant = .hex(0xCBA6F7)
        t.indicator = .hex(0x94E2D5)
        t.template = .hex(0xF5C2E7)
        t.templateFill = .hex(0xF5C2E7, 0.10)
        t.code = .hex(0xEBA0AC)
        t.codeFill = .hex(0xEBA0AC, 0.08)
        t.heading = .hex(0xF5C2E7)
        t.link = .hex(0x74C7EC)
        t.error = .hex(0xF38BA8)
        t.condition = .hex(0xBAC2DE)
        t.selection = .hex(0x9399B2, 0.25)
        t.caret = .hex(0xF5E0DC)
        t.currentLine = .hex(0x313244, 0.5)
        t.guide = .hex(0xCDD6F4, 0.06)
        t.stateSaturation = 0.70
        t.stateLightness = 0.78
        return t
    }()
}
