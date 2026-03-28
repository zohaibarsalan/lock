import Foundation

struct ActivityLogEntry: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
    let timestamp: Date
}

@MainActor
final class ActivityLogStore: ObservableObject {
    @Published private(set) var entries: [ActivityLogEntry] = []

    func record(_ title: String, detail: String = "") {
        entries.insert(
            ActivityLogEntry(title: title, detail: detail, timestamp: Date()),
            at: 0
        )

        if entries.count > 250 {
            entries.removeLast(entries.count - 250)
        }
    }

    func clear() {
        entries.removeAll()
    }
}
