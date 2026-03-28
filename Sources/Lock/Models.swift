import Foundation

struct ProtectedApp: Codable, Hashable, Identifiable {
    let bundleIdentifier: String
    let displayName: String
    let path: String

    var id: String { bundleIdentifier }
}

struct InstalledApp: Hashable, Identifiable {
    let bundleIdentifier: String
    let displayName: String
    let path: String

    var id: String { bundleIdentifier }
}

struct PasswordRecord: Codable {
    let salt: Data
    let digest: Data
}
