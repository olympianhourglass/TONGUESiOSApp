import Foundation
import UIKit
import FirebaseAuth
import FirebaseFirestore

// User-submitted feedback. Lives in a top-level `feedback` Firestore
// collection so it's easy to triage from the Firebase console without
// scoping by user. Each doc carries enough auth/version context to
// follow up if needed; nothing here is read by the app itself.
enum FeedbackService {
    private static let db = Firestore.firestore()
    private static let collection = "feedback"

    static func submit(text: String, userName: String? = nil) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let user = Auth.auth().currentUser
        let info = Bundle.main.infoDictionary ?? [:]
        let appVersion = info["CFBundleShortVersionString"] as? String
        let buildNumber = info["CFBundleVersion"] as? String

        var payload: [String: Any] = [
            "text": trimmed,
            "submittedAt": FieldValue.serverTimestamp(),
            "iosVersion": UIDevice.current.systemVersion,
            "deviceModel": UIDevice.current.model
        ]
        if let uid = user?.uid { payload["userId"] = uid }
        if let email = user?.email { payload["userEmail"] = email }
        if let userName, !userName.isEmpty { payload["userName"] = userName }
        if let appVersion { payload["appVersion"] = appVersion }
        if let buildNumber { payload["appBuild"] = buildNumber }
        if let user, user.isAnonymous { payload["isAnonymous"] = true }

        let ref = db.collection(collection).document()
        try await ref.setData(payload)
    }
}
