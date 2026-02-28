import Foundation

enum BiometricType {
    case none
}

struct BiometricAuthService {
    func biometricType() -> BiometricType {
        .none
    }

    func authenticate(reason: String) async -> Bool {
        _ = reason
        return true
    }
}
