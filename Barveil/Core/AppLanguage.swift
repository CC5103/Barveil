// User-selectable interface language. System mode follows the macOS locale;
// the explicit choices are stable identifiers that match the string catalog.

import Foundation

enum AppLanguage: String, CaseIterable, Identifiable, Codable, Sendable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"
    case japanese = "ja"

    var id: String { rawValue }

    var localeIdentifier: String? {
        switch self {
        case .system: nil
        case .english: "en"
        case .simplifiedChinese: "zh-Hans"
        case .japanese: "ja"
        }
    }
}
