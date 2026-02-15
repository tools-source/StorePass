import Foundation

@MainActor
final class LoginViewModel: ObservableObject {
    @Published var lastError: String?
}
