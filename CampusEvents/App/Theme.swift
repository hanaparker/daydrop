import SwiftUI
import UIKit

/// School colors. These are close approximations of the published brand colors;
/// swap in the exact values from Columbia's and Barnard's brand guides before launch.
enum Theme {
    static let columbiaBlue = Color(hex: "#B9D9EB")   // Columbia light blue
    static let navy = Color(hex: "#1D4F91")           // Columbia dark blue
    static let barnardBlue = Color(hex: "#00539B")    // Barnard blue

    /// Colors offered when a student first sets up categories.
    static let starterCategories: [(name: String, hex: String)] = [
        ("Sports", "#D50000"),
        ("Clubs", "#0B8043"),
        ("Talks", "#1D4F91"),
        ("Social", "#F4511E"),
        ("Academic", "#8E24AA")
    ]
}

extension TimeZone {
    /// Morningside Heights. All campus events are scheduled in New York time.
    static let campus = TimeZone(identifier: "America/New_York")!
}

extension Calendar {
    static var campus: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .campus
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }
}

enum HexColor {
    /// Red, green and blue as 0...1 values from "#RRGGBB".
    static func components(_ hex: String) -> (r: Double, g: Double, b: Double) {
        let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        return (
            Double((value >> 16) & 0xFF) / 255,
            Double((value >> 8) & 0xFF) / 255,
            Double(value & 0xFF) / 255
        )
    }
}

extension Color {
    init(hex: String) {
        let c = HexColor.components(hex)
        self.init(red: c.r, green: c.g, blue: c.b)
    }

    /// "#RRGGBB" for storing a color the student picked.
    var hexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        func byte(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(r), byte(g), byte(b))
    }
}
