import SwiftUI

struct ManagerTabView: View {
    let container: AppContainer

    var body: some View {
        TabView {
            ManagerDashboardView(
                checkInRepository: container.checkInRepository,
                csvExporter: container.csvExporter
            )
            .tabItem { Label("Dashboard", systemImage: "chart.bar") }

            ManageStoresView(repository: container.storeRepository)
                .tabItem { Label("Stores", systemImage: "map") }

            ManageEmployeesView(
                userRepository: container.userRepository,
                authRepository: container.authRepository
            )
            .tabItem { Label("Employees", systemImage: "person.3") }
        }
    }
}
