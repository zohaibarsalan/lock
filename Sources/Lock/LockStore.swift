import CryptoKit
import Foundation

@MainActor
final class LockStore: ObservableObject {
    @Published private(set) var protectedApps: [ProtectedApp] = []
    @Published private(set) var hasPassword = false

    private let defaultsKey = "protected-apps"
    private let passwordAccount = "locker-password-record"
    private let defaults = UserDefaults.standard
    private let keychain = KeychainManager(service: "com.zohaib.lock.password")
    private let activityLog: ActivityLogStore

    init(activityLog: ActivityLogStore) {
        self.activityLog = activityLog
        loadProtectedApps()
        loadPasswordState()
    }

    func isProtected(_ bundleIdentifier: String) -> Bool {
        protectedApps.contains { $0.bundleIdentifier == bundleIdentifier }
    }

    func toggleProtection(for app: InstalledApp) {
        setProtection(for: app, isProtected: !isProtected(app.bundleIdentifier))
    }

    func setProtection(for app: InstalledApp, isProtected shouldProtect: Bool) {
        if shouldProtect {
            guard !isProtected(app.bundleIdentifier) else {
                return
            }

            protectedApps.append(
                ProtectedApp(
                    bundleIdentifier: app.bundleIdentifier,
                    displayName: app.displayName,
                    path: app.path
                )
            )
            activityLog.record("Protected App Added", detail: app.displayName)
        } else {
            protectedApps.removeAll { $0.bundleIdentifier == app.bundleIdentifier }
            activityLog.record("Protected App Removed", detail: app.displayName)
        }

        protectedApps.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        saveProtectedApps()
    }

    func updatePassword(_ password: String) throws {
        let salt = try randomSalt()
        let digest = digest(for: password, salt: salt)
        let record = PasswordRecord(salt: salt, digest: digest)
        let encoded = try JSONEncoder().encode(record)
        try keychain.save(data: encoded, account: passwordAccount)
        hasPassword = true
        activityLog.record("Password Updated", detail: "Your app lock password was changed.")
    }

    func verify(password: String) -> Bool {
        guard let record = loadPasswordRecord() else {
            return false
        }

        return digest(for: password, salt: record.salt) == record.digest
    }

    private func loadProtectedApps() {
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([ProtectedApp].self, from: data) else {
            protectedApps = []
            return
        }

        protectedApps = decoded.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private func saveProtectedApps() {
        guard let data = try? JSONEncoder().encode(protectedApps) else {
            return
        }

        defaults.set(data, forKey: defaultsKey)
    }

    private func loadPasswordState() {
        hasPassword = loadPasswordRecord() != nil
    }

    private func loadPasswordRecord() -> PasswordRecord? {
        guard let data = try? keychain.load(account: passwordAccount),
              let decoded = try? JSONDecoder().decode(PasswordRecord.self, from: data) else {
            return nil
        }

        return decoded
    }

    private func digest(for password: String, salt: Data) -> Data {
        let passwordData = Data(password.utf8)
        let hash = SHA256.hash(data: salt + passwordData)
        return Data(hash)
    }

    private func randomSalt(length: Int = 32) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: length)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)

        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }

        return Data(bytes)
    }
}
