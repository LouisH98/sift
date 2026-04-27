import AppKit
import Combine
import SwiftUI

@MainActor
final class NotchAppearanceSettings: ObservableObject {
    static let shared = NotchAppearanceSettings()

    private enum Keys {
        static let glowColorHex = "notch.glowColorHex"
        static let isGlowEnabled = "notch.isGlowEnabled"
    }

    static let defaultGlowColorHex = "#38BDF8"

    @Published var isGlowEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isGlowEnabled, forKey: Keys.isGlowEnabled)
        }
    }

    @Published var glowColorHex: String {
        didSet {
            UserDefaults.standard.set(glowColorHex, forKey: Keys.glowColorHex)
        }
    }

    var glowColor: Color {
        Color(nsColor: nsGlowColor)
    }

    var nsGlowColor: NSColor {
        NSColor(hex: glowColorHex) ?? NSColor(hex: Self.defaultGlowColorHex) ?? .systemCyan
    }

    func setGlowColor(_ color: Color) {
        glowColorHex = color.nsColor.hexString
    }

    func resetGlowColor() {
        glowColorHex = Self.defaultGlowColorHex
    }

    private init() {
        glowColorHex = UserDefaults.standard.string(forKey: Keys.glowColorHex) ?? Self.defaultGlowColorHex
        isGlowEnabled = UserDefaults.standard.object(forKey: Keys.isGlowEnabled) as? Bool ?? true
    }
}

private extension Color {
    var nsColor: NSColor {
        NSColor(self).usingColorSpace(.deviceRGB) ?? .systemCyan
    }
}

private extension NSColor {
    convenience init?(hex: String) {
        let trimmed = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard trimmed.count == 6, let value = Int(trimmed, radix: 16) else {
            return nil
        }

        let red = CGFloat((value >> 16) & 0xFF) / 255
        let green = CGFloat((value >> 8) & 0xFF) / 255
        let blue = CGFloat(value & 0xFF) / 255

        self.init(red: red, green: green, blue: blue, alpha: 1)
    }

    var hexString: String {
        guard let color = usingColorSpace(.deviceRGB) else {
            return NotchAppearanceSettings.defaultGlowColorHex
        }

        let red = Int(round(max(0, min(1, color.redComponent)) * 255))
        let green = Int(round(max(0, min(1, color.greenComponent)) * 255))
        let blue = Int(round(max(0, min(1, color.blueComponent)) * 255))

        return String(format: "#%02X%02X%02X", red, green, blue)
    }
}
