import SwiftUI

// MARK: - Appearance Mode

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"
    
    var id: String { rawValue }
    
    var icon: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        }
    }
    
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

// MARK: - Appearance Manager

@MainActor
@Observable
final class AppearanceManager {
    static let shared = AppearanceManager()
    
    private let userDefaultsKey = "appearanceMode"
    
    var mode: AppearanceMode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: userDefaultsKey)
        }
    }
    
    var colorScheme: ColorScheme? {
        mode.colorScheme
    }
    
    private init() {
        if let savedValue = UserDefaults.standard.string(forKey: userDefaultsKey),
           let savedMode = AppearanceMode(rawValue: savedValue) {
            self.mode = savedMode
        } else {
            self.mode = .system
        }
    }
}
