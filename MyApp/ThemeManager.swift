import AppKit
import Combine

struct Theme {
    var primaryColor: NSColor
    var accentColor: NSColor
    var backgroundColor: NSColor
    var textColor: NSColor
    var secondaryTextColor: NSColor
    var borderColor: NSColor
    var cornerRadius: CGFloat = 12
}

/// Holds the active theme and persists the chosen preset in UserDefaults.
class ThemeManager: ObservableObject {
    enum ThemePreset: String, CaseIterable {
        case standard = "Default"
        case dark = "Dark"
        case vibrant = "Vibrant"
        case minimal = "Minimal"
        case ocean = "Ocean"
        case sunset = "Sunset"
        case forest = "Forest"

        var theme: Theme {
            switch self {
            case .standard:
                // System colors follow the macOS light/dark appearance.
                return Theme(
                    primaryColor: .controlAccentColor,
                    accentColor: .controlAccentColor,
                    backgroundColor: .windowBackgroundColor,
                    textColor: .labelColor,
                    secondaryTextColor: .secondaryLabelColor,
                    borderColor: .separatorColor
                )
            case .dark:
                return Theme(
                    primaryColor: NSColor(hex: "#FFFFFF"),
                    accentColor: NSColor(hex: "#0A84FF"),
                    backgroundColor: NSColor(hex: "#1C1C1E"),
                    textColor: NSColor(hex: "#FFFFFF"),
                    secondaryTextColor: NSColor(hex: "#8E8E93"),
                    borderColor: NSColor(hex: "#3A3A3C")
                )
            case .vibrant:
                return Theme(
                    primaryColor: NSColor(hex: "#FF2D55"),
                    accentColor: NSColor(hex: "#AF52DE"),
                    backgroundColor: NSColor(hex: "#1A0B2E"),
                    textColor: NSColor(hex: "#FFFFFF"),
                    secondaryTextColor: NSColor(hex: "#C7A6FF"),
                    borderColor: NSColor(hex: "#3D2263"),
                    cornerRadius: 16
                )
            case .minimal:
                return Theme(
                    primaryColor: NSColor(hex: "#000000"),
                    accentColor: NSColor(hex: "#555555"),
                    backgroundColor: NSColor(hex: "#FAFAFA"),
                    textColor: NSColor(hex: "#111111"),
                    secondaryTextColor: NSColor(hex: "#888888"),
                    borderColor: NSColor(hex: "#E0E0E0"),
                    cornerRadius: 6
                )
            case .ocean:
                return Theme(
                    primaryColor: NSColor(hex: "#64D2FF"),
                    accentColor: NSColor(hex: "#30B0C7"),
                    backgroundColor: NSColor(hex: "#0B2239"),
                    textColor: NSColor(hex: "#E6F4FF"),
                    secondaryTextColor: NSColor(hex: "#8FB8D8"),
                    borderColor: NSColor(hex: "#1E4466")
                )
            case .sunset:
                return Theme(
                    primaryColor: NSColor(hex: "#FF9F0A"),
                    accentColor: NSColor(hex: "#FF6B35"),
                    backgroundColor: NSColor(hex: "#2B1510"),
                    textColor: NSColor(hex: "#FFF1E6"),
                    secondaryTextColor: NSColor(hex: "#E0A98A"),
                    borderColor: NSColor(hex: "#5A2E20")
                )
            case .forest:
                return Theme(
                    primaryColor: NSColor(hex: "#30D158"),
                    accentColor: NSColor(hex: "#34C759"),
                    backgroundColor: NSColor(hex: "#0F2016"),
                    textColor: NSColor(hex: "#E8F5EC"),
                    secondaryTextColor: NSColor(hex: "#8DB89A"),
                    borderColor: NSColor(hex: "#244A30")
                )
            }
        }
    }

    @Published var currentTheme: Theme = ThemePreset.standard.theme
    @Published private(set) var currentPreset: ThemePreset = .standard

    private let preferenceKey = "selectedThemePreset"

    func setTheme(_ preset: ThemePreset) {
        currentPreset = preset
        currentTheme = preset.theme
        UserDefaults.standard.set(preset.rawValue, forKey: preferenceKey)
    }

    func loadPreference() {
        guard let saved = UserDefaults.standard.string(forKey: preferenceKey),
              let preset = ThemePreset(rawValue: saved) else { return }
        currentPreset = preset
        currentTheme = preset.theme
    }

    /// Overrides individual colors on top of the current preset.
    func setCustomColor(_ keyPath: WritableKeyPath<Theme, NSColor>, hex: String) {
        currentTheme[keyPath: keyPath] = NSColor(hex: hex)
    }
}

extension NSColor {
    /// Accepts "#RRGGBB", "RRGGBB" or "#RRGGBBAA".
    convenience init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)

        let hasAlpha = cleaned.count == 8
        let red = CGFloat((value >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let green = CGFloat((value >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let blue = CGFloat((value >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let alpha = hasAlpha ? CGFloat(value & 0xFF) / 255 : 1
        self.init(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    var hexString: String {
        guard let rgb = usingColorSpace(.sRGB) else { return "#000000" }
        return String(format: "#%02X%02X%02X", Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255), Int(rgb.blueComponent * 255))
    }
}
