import Foundation
import LocalAuthentication

@MainActor
final class AdminAuthService: ObservableObject {
    @Published private(set) var isAuthorizing = false

    private var authorizedUntil: Date?
    private let authorizationDuration: TimeInterval = 300
    private let activityLog: ActivityLogStore

    init(activityLog: ActivityLogStore) {
        self.activityLog = activityLog
    }

    func authorize(reason: String, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        if let authorizedUntil, authorizedUntil > Date() {
            completion(true)
            return
        }

        guard !isAuthorizing else {
            completion(false)
            return
        }

        isAuthorizing = true
        let context = LAContext()

        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { [weak self] success, error in
            DispatchQueue.main.async {
                guard let self else {
                    completion(false)
                    return
                }

                self.isAuthorizing = false

                if success {
                    self.authorizedUntil = Date().addingTimeInterval(self.authorizationDuration)
                    self.activityLog.record("Admin Authorized", detail: reason)
                    completion(true)
                } else {
                    self.activityLog.record("Admin Authorization Failed", detail: error?.localizedDescription ?? reason)
                    completion(false)
                }
            }
        }
    }
}
