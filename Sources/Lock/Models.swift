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
    let algorithm: String?
    let iterations: Int?
}

struct RunningAppIdentity: Hashable {
    let processID: pid_t
    let bundleIdentifier: String
    let launchDate: Date?
}
