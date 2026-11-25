import AppKit

enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    func title(_ language: AppLanguage) -> String {
        switch self {
        case .system: L10n.text("System", language: language)
        case .light: L10n.text("Light", language: language)
        case .dark: L10n.text("Dark", language: language)
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}
