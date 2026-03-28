import Foundation

enum SidebarSection: String, CaseIterable, Hashable, Identifiable {
    case apps
    case settings
    case logs

    var id: String { rawValue }

    var title: String {
        switch self {
        case .apps:
            "App List"
        case .settings:
            "Settings"
        case .logs:
            "Logs"
        }
    }

    var symbolName: String {
        switch self {
        case .apps:
            "square.stack.3d.up.fill"
        case .settings:
            "gearshape.fill"
        case .logs:
            "clock.badge.exclamationmark.fill"
        }
    }

    var description: String {
        switch self {
        case .apps:
            "Choose which apps need your password."
        case .settings:
            "Permissions, startup, and password."
        case .logs:
            "Lock, unlock, and app activity."
        }
    }
}

@MainActor
final class AppNavigation: ObservableObject {
    @Published var selectedSection: SidebarSection = .apps
}
