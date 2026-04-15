import CryptoKit
import Foundation

@MainActor
final class LockStore: ObservableObject {
    @Published private(set) var protectedApps: [ProtectedApp] = []
    @Published private(set) var hasPassword = false

    private let defaultsKey = "protected-apps"
    private let passwordAccount = "locker-password-record"
    private let currentPasswordAlgorithm = "PBKDF2-HMAC-SHA256"
    private let currentPasswordIterations = 120_000
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
        let digest = digest(for: password, salt: salt, algorithm: currentPasswordAlgorithm, iterations: currentPasswordIterations)
        let record = PasswordRecord(
            salt: salt,
            digest: digest,
            algorithm: currentPasswordAlgorithm,
            iterations: currentPasswordIterations
        )
        let encoded = try JSONEncoder().encode(record)
        try keychain.save(data: encoded, account: passwordAccount)
        hasPassword = true
        activityLog.record("Password Updated", detail: "Your app lock password was changed.")
    }

    func verify(password: String) -> Bool {
        guard let record = loadPasswordRecord() else {
            return false
        }

        let candidate = digest(
            for: password,
            salt: record.salt,
            algorithm: record.algorithm,
            iterations: record.iterations
        )
        return constantTimeEqual(candidate, record.digest)
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

    private func digest(for password: String, salt: Data, algorithm: String?, iterations: Int?) -> Data {
        let passwordData = Data(password.utf8)

        if algorithm == currentPasswordAlgorithm {
            return pbkdf2SHA256(
                password: passwordData,
                salt: salt,
                iterations: max(iterations ?? currentPasswordIterations, 1),
                outputByteCount: 32
            )
        }

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

    private func pbkdf2SHA256(password: Data, salt: Data, iterations: Int, outputByteCount: Int) -> Data {
        let key = SymmetricKey(data: password)
        let hmacLength = SHA256.byteCount
        let blockCount = Int(ceil(Double(outputByteCount) / Double(hmacLength)))
        var derived = Data()

        for blockIndex in 1...blockCount {
            var blockSalt = salt
            var counter = UInt32(blockIndex).bigEndian
            withUnsafeBytes(of: &counter) { blockSalt.append(contentsOf: $0) }

            var u = Data(HMAC<SHA256>.authenticationCode(for: blockSalt, using: key))
            var output = u

            if iterations > 1 {
                for _ in 2...iterations {
                    u = Data(HMAC<SHA256>.authenticationCode(for: u, using: key))
                    for index in output.indices {
                        output[index] ^= u[index]
                    }
                }
            }

            derived.append(output)
        }

        return Data(derived.prefix(outputByteCount))
    }

    private func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else {
            return false
        }

        var difference: UInt8 = 0
        for index in lhs.indices {
            difference |= lhs[index] ^ rhs[index]
        }

        return difference == 0
    }
}
