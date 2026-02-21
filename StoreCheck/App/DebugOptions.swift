import FirebaseAuth
import FirebaseFirestore
import Foundation

enum DebugOptions {
    #if DEBUG
    static let forceSignOutOnLaunch = false
    #else
    static let forceSignOutOnLaunch = false
    #endif
}

enum FirestorePermissionLogger {
    static func log(
        operation: String,
        path: String,
        error: Error,
        uid: String? = Auth.auth().currentUser?.uid
    ) {
        let nsError = error as NSError
        let safeUID = uid ?? "anonymous"
        let message = nsError.localizedDescription

        if nsError.domain == FirestoreErrorDomain,
           let code = FirestoreErrorCode.Code(rawValue: nsError.code),
           code == .permissionDenied {
            print("[FirestorePermissionDenied] op=\(operation) path=\(path) uid=\(safeUID) code=\(code.rawValue) message=\(message)")
            return
        }

        print("[FirestoreError] op=\(operation) path=\(path) uid=\(safeUID) domain=\(nsError.domain) code=\(nsError.code) message=\(message)")
    }
}
