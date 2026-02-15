import SwiftUI

struct ManagerTabView: View {
    let container: AppContainer
    @State private var selectedTab: ManagerTab = .dashboard

    private enum ManagerTab: Hashable {
        case dashboard
        case stores
        case employees
        case settings
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            ManagerDashboardView(
                checkInRepository: container.checkInRepository,
                csvExporter: container.csvExporter,
                isActiveTab: selectedTab == .dashboard
            )
            .tabItem { Label("Dashboard", systemImage: "chart.bar") }
            .tag(ManagerTab.dashboard)

            ManageStoresView(repository: container.storeRepository)
                .tabItem { Label("Stores", systemImage: "map") }
                .tag(ManagerTab.stores)

            ManageEmployeesView(
                employeeRepository: container.employeeManagementRepository,
                authRepository: container.authRepository
            )
            .tabItem { Label("Employees", systemImage: "person.3") }
            .tag(ManagerTab.employees)

            EmployeeSettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(ManagerTab.settings)
        }
    }
}
