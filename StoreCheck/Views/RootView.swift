import SwiftUI

struct RootView: View {
    @EnvironmentObject private var container: AppContainer
    @State private var isLoading = true

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading...")
            } else if let user = (container.authService as? AuthService)?.currentUser {
                user.role == .employee ? AnyView(EmployeeTabView()) : AnyView(ManagerTabView())
            } else {
                AnyView(RoleSelectionView())
            }
        }
        .task {
            await (container.authService as? AuthService)?.restoreSession()
            isLoading = false
        }
    }
}
