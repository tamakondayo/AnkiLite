import Foundation
import SwiftUI

extension Color {
    /// Creates a color from a hex string ("#rrggbb" or "rrggbb").
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let r, g, b, a: Double
        switch cleaned.count {
        case 6:
            r = Double((value & 0xFF0000) >> 16) / 255
            g = Double((value & 0x00FF00) >> 8) / 255
            b = Double(value & 0x0000FF) / 255
            a = 1
        case 8:
            r = Double((value & 0xFF000000) >> 24) / 255
            g = Double((value & 0x00FF0000) >> 16) / 255
            b = Double((value & 0x0000FF00) >> 8) / 255
            a = Double(value & 0x000000FF) / 255
        default:
            r = 0; g = 0; b = 0; a = 1
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}

extension String {
    /// Whether the string is empty after trimming whitespace.
    var isBlank: Bool {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

extension Sequence {
    /// Groups elements by a key, preserving insertion order of keys.
    func grouped<Key: Hashable>(by key: (Element) -> Key) -> [(key: Key, values: [Element])] {
        var order: [Key] = []
        var buckets: [Key: [Element]] = [:]
        for element in self {
            let k = key(element)
            if buckets[k] == nil { order.append(k) }
            buckets[k, default: []].append(element)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }
}
